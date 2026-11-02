#!/usr/bin/env python3
"""ios_app: build the iOS app (SA2 Recompiled for iPhone and iPad, arm64, iOS 15+) on a Mac.

Subtitle: the Android app's build (tools/s8/android_app.py), its phases reused where the work is the
same and given Xcode's toolchain (`xcrun -sdk iphoneos clang`, target arm64-apple-ios15.0), into
private/generated/s9/ios/app/:

  deps        zlib, libpng (NEON off) and zstd's decompressor (android_app's phase), static
  sdl3        the pinned SDL3 tarball with patches/sdl3 applied (tools/s5/sdl3_patches.py), configured by
              CMake for iOS, static (libSDL3.a), SDL_VENDOR_INFO as everywhere: its Metal GPU driver is
              the renderer's device (host/d3d9gpu make_sdl_gpu's Metal path)
  shadercross SPIRV-Cross (static) and SDL_shadercross's library (its one C file, no DXC), at their
              pinned commits: every SPIR-V module the renderer and the touch overlay make is converted
              to MSL for Metal (host/player/sa2_gpu_shader.h)
  dxbc        dxbc-spirv's 50 units (android_app's phase; DXVK's Linux compile commands, their paths
              moved onto this checkout's private/)
  translator  host/d3d9gpu/shader's units (android_app's phase)
  d9g         host/d3d9gpu's device units, with SA2_HAVE_SHADERCROSS
  player      lib/libsa2_player.a: host/player's units (SA2_PLAYER_GPU=1, SA2_IOS, SA2_SDL_LINKED_STATIC,
              SA2_HAVE_SHADERCROSS; player.cpp's main renamed sa2_player_main), its tweaks and the clear
              matrix; lib/libsa2_host.a: the launcher's relay, POSIX layer and session files, and the
              installer (host/install, its main renamed sa2_install_main: the app verifies in-process)
  resources   gen/app: game.env (the game's settings: the --game library's, else release_build's),
              tweaks.json (the Android app's TWEAKS and TWEAK_GROUPS, so a new tweak reaches the app
              with no line of its own), the icon's asset catalog (drawn here: no image is tracked),
              and Licenses/ (LICENSE, NOTICE, THIRD_PARTY_NOTICES.md and licenses/)
  xcode       host/ios configured with CMake's Xcode generator: private/generated/s9/ios/xcode/
              SA2Recomp.xcodeproj, linked with --game (tools/s9/ios_game.py's libsa2game.a)
  ipa         xcodebuild Release with signing off, and the app zipped as an unsigned .ipa
              (private/generated/s9/ios/SA2Recomp.ipa) for AltStore, SideStore or another tool to sign

What it needs on the Mac: Xcode (its command-line tools selected), CMake and Ninja (Homebrew), the
checkout's private/ copied from the Linux build machine (the pinned tarballs under
private/predecessor-tools and private/s5-tools, DXVK's sources, build and Native headers, and the
generated install table's receipt), and Python 3 with the checkout's requirements. SPIRV-Cross and
SDL_shadercross are fetched at their pinned commits when the copy has no source tree for them.

  python3 tools/s9/ios_app.py [--only PHASE ...] [--jobs N] [--game private/generated/s9/ios/game/libsa2game.a]
          [--team TEAMID] [--bundle-id com.example.sa2]

Prints IOS_APP_OK <project or ipa> on success.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import shlex
import shutil
import struct
import subprocess
import sys
import time
import zipfile
import zlib
from pathlib import Path

ROOT = next(p for p in Path(__file__).resolve().parents if (p / "AGENTS.md").is_file())


def _load(name: str, rel: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / rel)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


A = _load("android_app", "tools/s8/android_app.py")       # the Android builder, whose phases are reused
W = A.W
sha256 = A.sha256

IOS_MIN = "15.0"
TRIPLE = f"arm64-apple-ios{IOS_MIN}"
DEFAULT_OUT = "private/generated/s9/ios"
DEFAULT_GAME = "private/generated/s9/ios/game/libsa2game.a"
PHASES = ("deps", "sdl3", "shadercross", "dxbc", "translator", "d9g", "player", "resources", "xcode", "ipa")
IOS = ROOT / "host/ios"
H, P, LAUNCH, INSTALL = A.H, A.P, A.LAUNCH, A.INSTALL
PLAYER_DEFINES = ("-DSA2_PLAYER_GPU=1", "-DSA2_IOS=1", "-DSA2_SDL_LINKED_STATIC=1", "-DSA2_HAVE_SHADERCROSS=1")
Refused = A.Refused


def rebase(text: str) -> str:
    """A path the Linux build machine wrote (DXVK's compile commands), moved onto this checkout: the
    part from /private/ on is this checkout's private/."""
    at = text.find("/private/")
    if at < 0:
        return text
    lead = ""
    for prefix in ("-I", "-isystem", "-iquote"):
        if text.startswith(prefix):
            lead = prefix
            break
    return lead + str(ROOT / text[at + 1:])


def xcrun(*args: str) -> str:
    p = subprocess.run(["xcrun", *args], capture_output=True, text=True)
    if p.returncode:
        raise Refused(f"xcrun {' '.join(args)}: {p.stderr.strip()[:300]} (install Xcode and select it: xcode-select -s)")
    return p.stdout.strip()


class IosBuilder(A.Builder):
    """The Android builder with Xcode's toolchain (its own __init__ looks for the Android SDK)."""

    def __init__(self, out: Path, jobs: int, tools: dict, game: Path | None, team: str, bundle_id: str):
        self.out = out
        self.b = out / "app"
        self.jobs = jobs
        self.tools = tools
        self.abi = "arm64"
        self.game = game
        self.team = team
        self.bundle_id = bundle_id
        self.run = subprocess.run
        self.debuggable = True
        self.apk_path = None
        self.sdk = xcrun("--sdk", "iphoneos", "--show-sdk-path")
        clang = xcrun("--sdk", "iphoneos", "--find", "clang")
        clangxx = xcrun("--sdk", "iphoneos", "--find", "clang++")
        base = ["-target", TRIPLE, "-isysroot", self.sdk]
        self.cc = [clang, *base]
        self.cxx = [clangxx, *base]
        self.ar = xcrun("--sdk", "iphoneos", "--find", "ar")
        self.strip = xcrun("--sdk", "iphoneos", "--find", "strip")
        self.triple = TRIPLE
        self.cmake = shutil.which("cmake") or "cmake"
        self.ninja = shutil.which("ninja") or "ninja"
        self.record = {"schema": "sa2-recomp-s9-ios-app/v1", "triple": TRIPLE, "sdk": self.sdk,
                       "xcode": subprocess.run(["xcodebuild", "-version"], capture_output=True, text=True).stdout.strip(),
                       "inputs": {}, "phases": {}, "outputs": {}}
        self._hashes = {}
        for d in ("src", "obj", "lib", "gen", "deps/include"):
            (self.b / d).mkdir(parents=True, exist_ok=True)

    def archive(self, lib: Path, objects) -> None:
        if lib.exists():
            lib.unlink()
        self.sh([self.ar, "rcs", str(lib), *map(str, objects)])

    def wrappers(self) -> Path:
        """gen/acc and gen/acxx: Xcode's clang for the target, as one program (the translator's
        identity runs and hashes its compiler), answering -dumpfullversion with clang's version."""
        d = self.b / "gen"
        ver = re.search(r"clang version (\S+)", self.sh([self.cc[0], "--version"])).group(1)
        answer = f'if [ "$#" = 1 ] && [ "$1" = -dumpfullversion ]; then echo {ver}; exit 0; fi\n'
        for name, prog in (("acc", self.cc), ("acxx", self.cxx)):
            w = d / name
            text = f'#!/bin/sh\n{answer}exec {shlex.join(prog)} "$@"\n'
            if not w.is_file() or w.read_text() != text:
                w.write_text(text)
            w.chmod(0o755)
        return d

    def dxvk_flags(self, source: str, record: Path) -> list[str]:
        """DXVK's Linux flags for `source` (android_app's), x86's dropped, its paths on this checkout.
        The record android_app writes is moved too: the translator's identity pass reads its flags
        from it (extract_dxvk_shader.py identity --unit RECORD:SOURCE), not from what this returns."""
        flags = [rebase(f) for f in super().dxvk_flags(source, record)]
        doc = json.loads(record.read_text())
        doc["flags"] = flags
        record.write_text(json.dumps(doc, indent=1) + "\n")
        return flags

    def dxbc(self) -> dict:
        # The compile commands name the Linux machine's paths: android_app's phase reads them through
        # a copy whose "directory" and "file" are moved onto this checkout.
        cc_json = ROOT / A.CC_JSON_REL
        if not cc_json.is_file():
            raise Refused(f"no DXVK compile_commands.json at {cc_json}: copy private/ from the Linux build machine")
        moved = self.b / "gen/compile_commands.ios.json"
        entries = json.loads(cc_json.read_text())
        for e in entries:
            e["directory"] = rebase(e["directory"])
            if e["file"].startswith("/"):
                e["file"] = rebase(e["file"])
        moved.write_text(json.dumps(entries))
        saved = A.CC_JSON_REL
        A.CC_JSON_REL = str(moved.relative_to(ROOT))
        try:
            return super().dxbc()
        finally:
            A.CC_JSON_REL = saved

    # ------------------------------------------------------------------ SDL3, static, for iOS
    def sdl3(self) -> dict:
        sdl = self.tools["sdl3"]
        tarball = A.pinned_archive(self.tools, "sdl3", ROOT)
        patches = [ROOT / p["path"] for p in sdl.get("patches", [])]
        for p, pin in zip(patches, sdl.get("patches", [])):
            if sha256(p) != pin["sha256"]:
                raise Refused(f"{p} does not hash to its pin (tools/pins.json sdl3.patches)")
        install = self.b / "sdl3"
        build = self.b / "build/sdl3"
        configure = [self.cmake, "-G", "Ninja", f"-DCMAKE_MAKE_PROGRAM={self.ninja}", "-DCMAKE_SYSTEM_NAME=iOS",
                     "-DCMAKE_OSX_ARCHITECTURES=arm64", f"-DCMAKE_OSX_DEPLOYMENT_TARGET={IOS_MIN}",
                     "-DCMAKE_OSX_SYSROOT=iphoneos", "-DCMAKE_BUILD_TYPE=Release", f"-DCMAKE_INSTALL_PREFIX={install}",
                     "-DSDL_SHARED=OFF", "-DSDL_STATIC=ON", "-DSDL_TESTS=OFF", "-DSDL_EXAMPLES=OFF",
                     "-DSDL_TEST_LIBRARY=OFF", "-DSDL_OPENGLES=OFF", "-DSDL_VULKAN=OFF",
                     f"-DSDL_VENDOR_INFO={sdl['vendor_info']}"]
        stamp_text = json.dumps({"tarball": sdl["sha256"], "patches": [p["sha256"] for p in sdl.get("patches", [])],
                                 "configure": configure[1:]}, sort_keys=True)
        stamp = install / ".sa2-build"
        self.record["inputs"]["sdl3"] = {"path": str(tarball.relative_to(ROOT)), "sha256": sdl["sha256"],
                                         "vendor_info": sdl["vendor_info"]}
        lib = install / "lib/libSDL3.a"
        if stamp.is_file() and stamp.read_text() == stamp_text and lib.is_file():
            return {"rebuilt": False}
        t0 = time.monotonic()
        tree = self.sdl_tree()
        for d in (tree, build, install):
            if d.exists():
                shutil.rmtree(d)
        import tarfile  # noqa: PLC0415
        with tarfile.open(tarball) as t:
            t.extractall(self.b / "src", filter="data")
        py = sys.executable
        self.sh([py, ROOT / "tools/s5/sdl3_patches.py", "source", "--root", ROOT, "--tree", tree])
        self.sh([py, ROOT / "tools/s5/sdl3_patches.py", "apply", "--root", ROOT, "--tree", tree],
                log=self.b / "gen/sdl3-patch.log")
        build.mkdir(parents=True)
        self.sh([*configure, "-S", tree, "-B", build], log=self.b / "gen/sdl3-configure.log")
        self.sh([self.cmake, "--build", build, "-j", str(self.jobs)], log=self.b / "gen/sdl3-build.log")
        self.sh([self.cmake, "--install", build], log=self.b / "gen/sdl3-install.log")
        config = next(build.glob("include-config-*/build_config/SDL_build_config.h")).read_text()
        if not re.search(r"^#define SDL_GPU_METAL 1", config, re.M):
            raise Refused("SDL3 was configured without its Metal GPU driver (gen/sdl3-configure.log)")
        stamp.write_text(stamp_text)
        return {"rebuilt": True, "seconds": round(time.monotonic() - t0, 2)}

    def sdl_include(self) -> list[str]:
        sdl = self.b / "sdl3"
        if not (sdl / "include/SDL3/SDL.h").is_file():
            raise Refused(f"no SDL3 headers under {sdl} (the sdl3 phase)")
        # SDL's own copy of the Vulkan headers: the renderer's Vulkan half compiles (it is not used on iOS).
        return [f"-I{sdl / 'include'}", f"-I{self.sdl_tree() / 'src/video/khronos'}"]

    # ------------------------------------------------------------------ SPIRV-Cross and SDL_shadercross
    def pinned_source(self, name: str) -> Path:
        """The pinned source tree of `name` (tools/pins.json): the Linux machine's copy under private/
        when it is there, else a fetch of the pinned commit into gen/src."""
        pin = self.tools[name]
        tree = ROOT / pin["path"]
        if tree.is_dir() and any(tree.iterdir()):
            # The copy is used when it is the pinned commit, or no git checkout at all (a copied tree).
            head = subprocess.run(["git", "-C", str(tree), "rev-parse", "HEAD"], capture_output=True, text=True)
            if head.returncode != 0 or head.stdout.strip() == pin["commit"]:
                return tree
        tree = self.b / "src" / name
        if not (tree / ".sa2-commit").is_file() or (tree / ".sa2-commit").read_text().strip() != pin["commit"]:
            if tree.exists():
                shutil.rmtree(tree)
            tree.mkdir(parents=True)
            self.sh(["git", "-C", tree, "init", "-q"])
            self.sh(["git", "-C", tree, "fetch", "-q", "--depth", "1", pin["url"], pin["commit"]])
            self.sh(["git", "-C", tree, "checkout", "-q", "FETCH_HEAD"])
            (tree / ".sa2-commit").write_text(pin["commit"] + "\n")
        return tree

    def shadercross(self) -> dict:
        t0 = time.monotonic()
        spvc = self.pinned_source("spirv-cross")
        sx = self.pinned_source("sdl-shadercross")
        install = self.b / "shadercross"
        build = self.b / "build/spirv-cross"
        stamp = install / ".sa2-build"
        stamp_text = json.dumps({"spirv-cross": self.tools["spirv-cross"]["commit"],
                                 "sdl-shadercross": self.tools["sdl-shadercross"]["commit"]})
        self.record["inputs"]["spirv-cross"] = self.tools["spirv-cross"]["commit"]
        self.record["inputs"]["sdl-shadercross"] = self.tools["sdl-shadercross"]["commit"]
        if stamp.is_file() and stamp.read_text() == stamp_text and (install / "lib/libSDL3_shadercross.a").is_file():
            return {"rebuilt": False}
        for d in (install, build):
            if d.exists():
                shutil.rmtree(d)
        self.sh([self.cmake, "-G", "Ninja", f"-DCMAKE_MAKE_PROGRAM={self.ninja}", "-DCMAKE_SYSTEM_NAME=iOS",
                 "-DCMAKE_OSX_ARCHITECTURES=arm64", f"-DCMAKE_OSX_DEPLOYMENT_TARGET={IOS_MIN}",
                 "-DCMAKE_OSX_SYSROOT=iphoneos", "-DCMAKE_BUILD_TYPE=Release", f"-DCMAKE_INSTALL_PREFIX={install}",
                 "-DSPIRV_CROSS_SHARED=OFF", "-DSPIRV_CROSS_STATIC=ON", "-DSPIRV_CROSS_CLI=OFF",
                 "-DSPIRV_CROSS_ENABLE_TESTS=OFF", "-DSPIRV_CROSS_ENABLE_C_API=ON", "-DSPIRV_CROSS_SKIP_INSTALL=OFF",
                 "-S", spvc, "-B", build], log=self.b / "gen/spirv-cross-configure.log")
        self.sh([self.cmake, "--build", build, "-j", str(self.jobs)], log=self.b / "gen/spirv-cross-build.log")
        self.sh([self.cmake, "--install", build], log=self.b / "gen/spirv-cross-install.log")
        # SDL_shadercross: its one source, SPIR-V input only (no DXC), against the static SPIRV-Cross.
        o = self.b / "obj/shadercross"
        o.mkdir(parents=True, exist_ok=True)
        inc = install / "include"
        flags = ["-O2", "-DNDEBUG", f"-I{sx / 'include'}", f"-I{inc}", f"-I{inc / 'spirv_cross'}", *self.sdl_include()]
        self.compile_one(self.cc, flags, sx / "src/SDL_shadercross.c", o / "SDL_shadercross.o")
        self.archive(install / "lib/libSDL3_shadercross.a", [o / "SDL_shadercross.o"])
        hdr = install / "include/SDL3_shadercross"
        hdr.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(sx / "include/SDL3_shadercross/SDL_shadercross.h", hdr / "SDL_shadercross.h")
        for name in ("core", "glsl", "msl", "hlsl", "cpp", "reflect", "util", "c"):
            if not (install / f"lib/libspirv-cross-{name}.a").is_file():
                raise Refused(f"SPIRV-Cross installed no libspirv-cross-{name}.a (gen/spirv-cross-build.log)")
        stamp.write_text(stamp_text)
        return {"rebuilt": True, "seconds": round(time.monotonic() - t0, 2)}

    def shadercross_include(self) -> list[str]:
        return [f"-I{self.b / 'shadercross/include'}"]

    # ------------------------------------------------------------------ the renderer and the player
    def d9g_flags(self) -> list[str]:
        return [*super().d9g_flags(), "-DSA2_HAVE_SHADERCROSS=1", *self.shadercross_include()]

    def expectations(self) -> Path:
        """gen/expected-gpu/sa2_host_expectations.h: SDL's version and revision from its headers. The
        library is linked into the app, which signing rewrites, so its hash is not pinned
        (SA2_SDL_LINKED_STATIC, host/player/player.cpp validate_host_files)."""
        sdl = self.tools["sdl3"]
        inc = self.b / "sdl3/include/SDL3"
        version_src = (inc / "SDL_version.h").read_text()
        parts = [int(re.findall(r"^#define SDL_" + n + r"_VERSION\s+(\d+)\s*$", version_src, re.M)[0])
                 for n in ("MAJOR", "MINOR", "MICRO")]
        if ".".join(map(str, parts)) != sdl["version"]:
            raise Refused(f"SDL header version {parts} is not tools.sdl3.version {sdl['version']}")
        rev_src = (inc / "SDL_revision.h").read_text()
        revisions = re.findall(r'^#define SDL_REVISION "([^"\n]*)"\s*$', rev_src, re.M)
        vendors = re.findall(r'^#define SDL_VENDOR_INFO "([^"\n]*)"\s*$', rev_src, re.M)
        if len(revisions) != 1 or vendors != [sdl["vendor_info"]]:
            raise Refused(f"the SDL revision header reads {revisions} with vendor {vendors}")
        d = self.b / "gen/expected-gpu"
        d.mkdir(parents=True, exist_ok=True)
        text = ("#pragma once\nnamespace sa2_host_expected {\n"
                f"inline constexpr char sdl_sha256[] = \"{'0' * 64}\";   // not pinned: SA2_SDL_LINKED_STATIC\n"
                f"inline constexpr int sdl_version = {parts[0] * 1000000 + parts[1] * 1000 + parts[2]};\n"
                f"inline constexpr char sdl_revision[] = \"{revisions[0]} ({vendors[0]})\";\n}}\n")
        header = d / "sa2_host_expectations.h"
        if not header.is_file() or header.read_text() != text:
            header.write_text(text)
        return d

    def player(self) -> dict:
        exp = self.expectations()
        gen = self.b / "gen"
        sdl_inc = self.sdl_include()
        dep_inc = f"-I{self.b / 'deps/include'}"
        o = self.b / "obj/player"
        o.mkdir(parents=True, exist_ok=True)
        pflags = [*A.WARN, f"-I{exp}", *PLAYER_DEFINES, f"-I{ROOT / 'host'}", f"-I{P}", *sdl_inc, dep_inc,
                  *self.shadercross_include(), f"-I{A.S5_INSTALL / 'include/dxvk'}"]
        units = []
        for t in self.player_units():
            extra = ["-DSDL_MAIN_HANDLED", "-Dmain=sa2_player_main"] if t == "player" else []
            units.append((self.cxx, [*pflags, *extra], A.portable_source(f"host/player/{t}.cpp", gen), o / f"{t}.o"))
        units += [(self.cxx, pflags, s, o / f"tweak_{s.stem}.o") for s in sorted((P / "tweaks").glob("*.cpp"))]
        units.append((self.cxx, [*self.d9g_flags(), f"-I{H / 'test'}", "-DSA2_CLEAR_MATRIX_STATIC"],
                      H / "test/clear_matrix.cpp", o / "clear_matrix.o"))
        stats = self.compile_many("player", units)
        self.archive(self.b / "lib/libsa2_player.a", [u[3] for u in units])
        # The session's half: the launcher's relay, POSIX layer and session files, and the installer.
        table = self.install_table()
        oh = self.b / "obj/host"
        oh.mkdir(parents=True, exist_ok=True)
        hflags = [*A.WARN, f"-I{LAUNCH}", f"-I{INSTALL}", f"-I{P}", f"-I{ROOT / 'host'}"]
        hunits = [(self.cxx, hflags, LAUNCH / f"{s}.cpp", oh / f"{s}.o")
                  for s in ("sa2_relay", "sa2_launch_posix", "sa2_session_files")]
        isrcs = [s for s in sorted(INSTALL.glob("*.cpp"))
                 if not re.match(r"test_|.*_test\.cpp$|.*_probe\.cpp$", s.name) and s.name != "sa2_platform_win32.cpp"]
        for s in isrcs:
            extra = ["-Dmain=sa2_install_main"] if s.name == "sa2_install_cli.cpp" else []
            hunits.append((self.cxx, [*hflags, *extra], s, oh / f"install_{s.stem}.o"))
        hunits.append((self.cxx, hflags, table, oh / "sa2_install_table.o"))
        hstats = self.compile_many("host", hunits)
        self.archive(self.b / "lib/libsa2_host.a", [u[3] for u in hunits])
        return {"player": stats, "host": hstats}

    # ------------------------------------------------------------------ the app's resources
    def resources(self) -> dict:
        g = self.b / "gen/app"
        g.mkdir(parents=True, exist_ok=True)
        env = None
        if self.game and (self.game.parent / "game.env").is_file():
            env = (self.game.parent / "game.env").read_text()
        (g / "game.env").write_text(env if env is not None else self.game_env())
        tweaks = tweaks_json((ROOT / "host/android/java/com/sa2recomp/app/GameSettings.java").read_text())
        (g / "tweaks.json").write_text(json.dumps(tweaks, indent=1) + "\n")
        assets = g / "Assets.xcassets"
        icon_dir = assets / "AppIcon.appiconset"
        icon_dir.mkdir(parents=True, exist_ok=True)
        (assets / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}) + "\n")
        (icon_dir / "Contents.json").write_text(json.dumps({
            "images": [{"filename": "icon-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}],
            "info": {"author": "xcode", "version": 1}}, indent=1) + "\n")
        (icon_dir / "icon-1024.png").write_bytes(icon_png(1024))
        # The notices a binary distribution carries (THIRD_PARTY_NOTICES.md), in the app.
        lic = g / "Licenses"
        if lic.exists():
            shutil.rmtree(lic)
        lic.mkdir()
        for f in (ROOT / "LICENSE", ROOT / "NOTICE", ROOT / "THIRD_PARTY_NOTICES.md", *sorted((ROOT / "licenses").iterdir())):
            shutil.copyfile(f, lic / f.name)
        return {"game_env_from": "the game's link" if env is not None else "release_build", "tweaks": len(tweaks["order"])}

    # ------------------------------------------------------------------ the Xcode project and the .ipa
    def xcode_dir(self) -> Path:
        return self.out / "xcode"

    def xcode(self) -> dict:
        game = self.game if self.game and self.game.is_file() else None
        args = [self.cmake, "-G", "Xcode", "-S", IOS, "-B", self.xcode_dir(), "-DCMAKE_SYSTEM_NAME=iOS",
                f"-DCMAKE_OSX_DEPLOYMENT_TARGET={IOS_MIN}", "-DCMAKE_OSX_ARCHITECTURES=arm64",
                f"-DSA2_IOS_BUILD={self.b}", f"-DSA2_IOS_GAME={game or ''}", f"-DSA2_IOS_BUNDLE_ID={self.bundle_id}"]
        if self.team:
            args.append(f"-DSA2_IOS_TEAM={self.team}")
        self.sh(args, log=self.b / "gen/xcode-configure.log")
        project = self.xcode_dir() / "SA2Recomp.xcodeproj"
        if not project.is_dir():
            raise Refused(f"CMake wrote no {project} (gen/xcode-configure.log)")
        return {"project": str(project), "game_linked": game is not None}

    @staticmethod
    def path_leaks(app: Path) -> list[str]:
        """Each file of `app` that holds this checkout's path or the user's home folder, with the
        first such string."""
        needles = sorted({str(ROOT), os.path.expanduser("~")}, key=len, reverse=True)
        needles = [n.encode() for n in needles if len(n) > 1]
        found = []
        for f in sorted(app.rglob("*")):
            if not f.is_file() or f.is_symlink():
                continue
            data = f.read_bytes()
            for n in needles:
                at = data.find(n)
                if at >= 0:
                    end = at
                    while end < len(data) and end - at < 160 and 32 <= data[end] < 127:
                        end += 1
                    found.append(f"{f.relative_to(app)}: {data[at:end].decode(errors='replace')}")
                    break
        return found

    def ipa(self) -> dict:
        project = self.xcode_dir() / "SA2Recomp.xcodeproj"
        derived = self.out / "derived"
        self.sh(["xcodebuild", "-project", project, "-scheme", "SA2Recomp", "-configuration", "Release",
                 "-sdk", "iphoneos", "-derivedDataPath", derived, "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO",
                 "CODE_SIGN_IDENTITY=", "build"], log=self.b / "gen/xcodebuild.log")
        # A CMake-generated project sets CONFIGURATION_BUILD_DIR to <project dir>/Release-iphoneos,
        # so the app lands there rather than under the derived data's Build/Products.
        apps = sorted([*self.xcode_dir().glob("Release-iphoneos/*.app"),
                       *derived.glob("Build/Products/Release-iphoneos/*.app")])
        if not apps:
            raise Refused("xcodebuild made no .app (gen/xcodebuild.log)")
        # The debug map (the linker's N_OSO entries: every object file's path on this machine) goes,
        # for dsymutil has read it already: the dSYM beside the app keeps the debug info, and the
        # app keeps its symbols. Then no path of this checkout or this user may be left in the app.
        exe = apps[0] / apps[0].stem
        self.sh(["xcrun", "strip", "-S", exe])
        leaks = self.path_leaks(apps[0])
        if leaks:
            raise Refused("the app still holds paths of this machine: " + "; ".join(leaks[:8]) +
                          " (host/ios/CMakeLists.txt maps the checkout to '.' for the compilers)")
        out = self.out / "SA2Recomp.ipa"
        tmp = out.with_suffix(".ipa.tmp")
        with zipfile.ZipFile(tmp, "w", compression=zipfile.ZIP_DEFLATED) as z:
            for f in sorted(apps[0].rglob("*")):
                arc = Path("Payload") / apps[0].name / f.relative_to(apps[0])
                if f.is_symlink():
                    info = zipfile.ZipInfo(str(arc))
                    info.create_system = 3
                    info.external_attr = (0o120777 << 16)
                    z.writestr(info, os.readlink(f))
                elif f.is_file():
                    z.write(f, str(arc))
        os.replace(tmp, out)
        return {"ipa": str(out), "bytes": out.stat().st_size, "sha256": sha256(out)}


# ---------------------------------------------------------------- tweaks.json

def java_string(s: str) -> str:
    return re.sub(r'\\(.)', lambda m: {"n": "\n", "t": "\t"}.get(m.group(1), m.group(1)), s)


def tweaks_json(java: str) -> dict:
    """The Android app's TWEAKS (name, label, description, in order) and TWEAK_GROUPS (headings and
    names), as GameSettings.tweakGroups shows them: a name in no group goes under Other, one in two
    groups under the first, a name that is no tweak's is left out, an empty group is not shown."""
    body = java[java.index("static final Tweak[] TWEAKS"):]
    body = body[:body.index("};")]
    s = r'"((?:[^"\\]|\\.)*)"'
    order = [{"name": java_string(m.group(1)), "label": java_string(m.group(2)), "description": java_string(m.group(3))}
             for m in re.finditer(r'new Tweak\(\s*' + s + r'\s*,\s*' + s + r'\s*,\s*' + s + r'\s*\)', body)]
    if not order:
        raise Refused("GameSettings.java's TWEAKS reads as empty")
    gbody = java[java.index("static final String[][] TWEAK_GROUPS"):]
    gbody = gbody[gbody.index("{") + 1:]
    depth, end = 1, 0
    for i, ch in enumerate(gbody):
        depth += ch == "{"
        depth -= ch == "}"
        if depth == 0:
            end = i
            break
    by_name = {t["name"]: t for t in order}
    placed: set[str] = set()
    groups = []
    for block in re.findall(r"\{([^{}]*)\}", gbody[:end]):
        names = [java_string(m) for m in re.findall(s, block)]
        if not names:
            continue
        heading, members = names[0], []
        for n in names[1:]:
            if n in by_name and n not in placed:
                placed.add(n)
                members.append(by_name[n])
        groups.append({"heading": heading, "tweaks": members})
    rest = [t for t in order if t["name"] not in placed]
    if rest:
        other = next((g for g in groups if g["heading"] == "Other"), None)
        if other is None:
            other = {"heading": "Other", "tweaks": []}
            groups.append(other)
        other["tweaks"].extend(rest)
    return {"order": order, "groups": [g for g in groups if g["tweaks"]]}


# ---------------------------------------------------------------- the icon (no image is tracked)

def _flatten(cmds: list, steps: int = 24) -> list[tuple[float, float]]:
    pts: list[tuple[float, float]] = []
    cur = (0.0, 0.0)
    for c in cmds:
        if c[0] in "ML":
            cur = (c[1], c[2])
            pts.append(cur)
        elif c[0] == "C":
            p0, p1, p2, p3 = cur, (c[1], c[2]), (c[3], c[4]), (c[5], c[6])
            for i in range(1, steps + 1):
                t = i / steps
                u = 1 - t
                pts.append((u ** 3 * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t ** 3 * p3[0],
                            u ** 3 * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t ** 3 * p3[1]))
            cur = p3
    return pts


# The Android launcher icon's foreground (host/android/res/drawable/ic_launcher_fg.xml): a gold ring and a
# white "2" on a 108-unit square, here on the setup screen's blue.
TWO = [("M", 42, 46), ("C", 42, 38, 48, 34, 55, 34), ("C", 62, 34, 67, 38, 67, 45), ("C", 67, 51, 63, 55, 57, 60),
       ("L", 50, 66), ("L", 68, 66), ("L", 68, 74), ("L", 40, 74), ("L", 40, 67), ("L", 52, 56),
       ("C", 57, 51, 59, 49, 59, 45), ("C", 59, 42, 57, 41, 55, 41), ("C", 52, 41, 50, 43, 50, 46), ("L", 42, 46)]


def icon_png(size: int) -> bytes:
    """An RGB PNG: blue, the gold ring (radius 27, stroke 6) and the white 2, 4x4 supersampled."""
    blue, gold, white = (0x1C, 0x3F, 0x94), (0xFF, 0xC2, 0x1A), (0xFF, 0xFF, 0xFF)
    k = size / 90.0                       # the 108-unit art a little larger than Android's safe zone
    off = size / 2 - 54 * k
    poly = [(off + x * k, off + y * k) for x, y in _flatten(TWO)]
    cx = cy = off + 54 * k
    r_in, r_out = 24 * k, 30 * k
    ss = 4
    rows = bytearray()
    for y in range(size):
        acc_ring = [0.0] * size
        acc_two = [0.0] * size
        for sy in range(ss):
            yy = y + (sy + 0.5) / ss
            # The ring: the spans between the inner and outer circles on this sub-row.
            dy = yy - cy
            spans = []
            if abs(dy) < r_out:
                xo = (r_out * r_out - dy * dy) ** 0.5
                if abs(dy) < r_in:
                    xi = (r_in * r_in - dy * dy) ** 0.5
                    spans = [(cx - xo, cx - xi), (cx + xi, cx + xo)]
                else:
                    spans = [(cx - xo, cx + xo)]
            for a, b in spans:
                _cover(acc_ring, a, b, 1.0 / ss)
            # The 2: even-odd spans of the polygon on this sub-row.
            xs = []
            n = len(poly)
            for i in range(n):
                (x0, y0), (x1, y1) = poly[i], poly[(i + 1) % n]
                if (y0 <= yy < y1) or (y1 <= yy < y0):
                    xs.append(x0 + (yy - y0) * (x1 - x0) / (y1 - y0))
            xs.sort()
            for i in range(0, len(xs) - 1, 2):
                _cover(acc_two, xs[i], xs[i + 1], 1.0 / ss)
        rows.append(0)
        for x in range(size):
            r, g, b = blue
            a = min(1.0, acc_ring[x])
            r, g, b = (r + (gold[0] - r) * a, g + (gold[1] - g) * a, b + (gold[2] - b) * a)
            a = min(1.0, acc_two[x])
            r, g, b = (r + (white[0] - r) * a, g + (white[1] - g) * a, b + (white[2] - b) * a)
            rows += bytes((int(r + 0.5), int(g + 0.5), int(b + 0.5)))

    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(bytes(rows), 9)) + chunk(b"IEND", b""))


def _cover(acc: list[float], a: float, b: float, weight: float) -> None:
    """Adds `weight` times the horizontal coverage of [a, b) to each pixel of `acc`."""
    if b <= a:
        return
    n = len(acc)
    lo, hi = max(0, int(a)), min(n - 1, int(b))
    for x in range(lo, hi + 1):
        c = min(b, x + 1) - max(a, x)
        if c > 0:
            acc[x] += c * weight


# ---------------------------------------------------------------- main

def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--out", default=str(ROOT / DEFAULT_OUT))
    ap.add_argument("--jobs", type=int, default=max(1, (os.cpu_count() or 4) // 2))
    ap.add_argument("--game", default=str(ROOT / DEFAULT_GAME), help="the game library (tools/s9/ios_game.py link)")
    ap.add_argument("--only", action="append", choices=PHASES)
    ap.add_argument("--team", default="", help="the Apple development team that signs the app (the xcode phase)")
    ap.add_argument("--bundle-id", default="com.sa2recomp.ios")
    a = ap.parse_args(argv)
    if sys.platform != "darwin":
        raise Refused("the iOS app is built on macOS with Xcode (tools/s9/ios_game.py compile runs anywhere)")
    out = Path(a.out).resolve()
    b = IosBuilder(out, a.jobs, W.pins(), Path(a.game).resolve(), a.team, a.bundle_id)
    phases = a.only or [p for p in PHASES if p != "ipa"]
    for phase in phases:
        t0 = time.monotonic()
        print(f"== {phase}", flush=True)
        result = getattr(b, phase)()
        if isinstance(result, dict):
            result.setdefault("seconds", round(time.monotonic() - t0, 2))
        b.record["phases"][phase] = result
        print(f"   {json.dumps(result)}", flush=True)
    (b.b / "ios_app.runrec").write_text(json.dumps(b.record, indent=1) + "\n")
    if "ipa" in phases:
        print("IOS_APP_OK", b.record["phases"]["ipa"]["ipa"])
    elif "xcode" in phases:
        print("IOS_APP_OK", b.record["phases"]["xcode"]["project"])
    else:
        print("IOS_APP_PHASES_OK", " ".join(phases))
    return 0


if __name__ == "__main__":
    sys.exit(main())
