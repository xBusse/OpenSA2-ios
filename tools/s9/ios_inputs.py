#!/usr/bin/env python3
"""ios_inputs: everything the iOS build needs from a Linux machine, from nothing but the game's exe.

Subtitle: the Linux half of docs/ios.md as one tool, in the order a fresh machine (a cloud VM, a CI
runner, a container) must run it, ending in one archive the Mac half (tools/s9/ios_mac.sh) takes.

Each step is skipped when its output is already there (--force STEP redoes one), so a run that stops
can be started again. `all` runs them in order:

  tools       Ghidra, Temurin 21, Zig 0.15.2 (PyPI's ziglang wheel), Remill 5.0.7 and the SA2 Mod
              Loader source at their pins (tools/pins.json), each download held to the sha256 it had
              when this recipe was proven (DOWNLOADS); meson 1.7.0 into .venv. Needs clang-20 and
              llvm-20 installed (Ubuntu 24.04: apt install clang-20 llvm-20) and git, curl, unzip.
  exe         private/exe/sonic2app.exe (--exe PATH copies it there) held to its pin, and the
              unpacked one: --unpacked PATH takes Steamless's output, renames its .data and .rsrc
              sections to .dataa and .rsrca as the pinned copy has them, and holds the result to the
              pin. Steamless itself is a Windows (.NET) program: run it on Windows, under mono, or on
              a CI Windows runner (tools/s9/ci/ios-build.yml).
  helpers     the PC24 pass's helper modules (pc_round.ll, x87_int.ll), by Zig's clang.
  map         the function map (Documentation/scripts/s1_function_map.py: Ghidra, headless). Its
              receipt is moved under private/generated, so the tree is left as it was.
  lift        tools/s3/whole_image/lift_all.py --tag next --to-next-entry
  compile     tools/s3/whole_image/compile_all.py --tag next
  arms        tools/s3/arms/armlist.py, then lift_arms_image.py, tag next
  extras      tools/s4/lift_extras_listed.py: the extras of Documentation/lifted-extras.json
  stage       stage_merged_build.py (next -> next+allarms), gen_table.py, and mb_edges.py with the
              arms and the extras' named exceptions
  overlay     tools/s7/drm_unwrap.py --readset-only, then text_readset.py: the code-section overlay
  dxvk        DXVK at its pinned commit (a git checkout, submodules too), configured by meson only
              for its compile commands (the app compiles dxbc-spirv itself), with stand-ins for the
              SDL3 library and glslang that configure needs and nothing compiles; DXVK Native's
              headers and SDL3's installed under private/s5-tools/install
  deps        the pinned source tarballs the app builds (SDL3, zlib, zstd; libpng when its host is
              reachable: the Mac fetches it otherwise), each held to its pin
  ios         tools/s9/ios_game.py compile, with clang-20
  variants    the code-patch tweaks for the iOS objects (variants.py build, SA2_NM=llvm-nm-20)
  pack        private/generated/s9/ios/mac-inputs.tar.xz: what tools/s9/ios_mac.sh needs

--prune deletes each stage's raw lifted IR once its objects are built (about 10 GB; the folded IR,
which the iOS compile reads, is kept): a CI runner's disk needs it.

Usage:
  .venv/bin/python tools/s9/ios_inputs.py all --exe ~/sonic2app.exe --unpacked ~/sonic2app.exe.unpacked.exe
  .venv/bin/python tools/s9/ios_inputs.py lift          # one step
  .venv/bin/python tools/s9/ios_inputs.py all --force ios --jobs 4
Outputs stay under private/ (ignored): the game's code, translated, is never committed.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tarfile
import time
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PRIV = ROOT / "private"
GEN = PRIV / "generated"
TOOLS = PRIV / "predecessor-tools"
DL = PRIV / "dl"
PINS = json.loads((ROOT / "tools" / "pins.json").read_text())

# The downloads this recipe was proven with (2026-11-01): url, sha256, what they become.
DOWNLOADS = {
    "ghidra": ("https://github.com/NationalSecurityAgency/ghidra/releases/download/Ghidra_12.1.3_build/"
               "ghidra_12.1.3_PUBLIC_20260817.zip",
               "93a5d11a9ad510622acaaf908c556a7b9b764d338e78a7567f3689bf5081fd54"),
    "jdk": ("https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.12.1%2B1/"
            "OpenJDK21U-jdk_x64_linux_hotspot_21.0.12.1_1.tar.gz",
            "ce79869e1307ed8ee1e2baa86a412b1eb5b75d10a01006d788a6f968bcfaee94"),
    "remill": (PINS["tools"]["remill"]["url"], PINS["tools"]["remill"]["tarball_sha256"]),
    "zig_wheel": ("pypi:ziglang==0.15.2",
                  "806316453d1ede7174ed3fefb8e5348154629089c3bb5fe812dfd0e172fac130"),
}
# Hosts some networks refuse; the same files, held to the same pins.
MIRRORS = {"zlib": "https://github.com/madler/zlib/releases/download/v1.3.2/zlib-1.3.2.tar.gz"}

STEPS = ("tools", "exe", "helpers", "map", "lift", "compile", "arms", "extras", "stage", "overlay",
         "dxvk", "deps", "ios", "variants", "pack")
PY = ROOT / ".venv" / "bin" / "python"


class Refused(SystemExit):
    pass


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def say(msg: str) -> None:
    print(f"[ios_inputs {time.strftime('%H:%M:%S')}] {msg}", flush=True)


def sh(cmd: str, log: Path | None = None, env: dict | None = None) -> None:
    """`cmd` in bash at the checkout's root, with tools/env.sh sourced; a nonzero exit refuses."""
    full = f"set -o pipefail; source tools/env.sh >/dev/null && {cmd}"
    e = dict(os.environ, **(env or {}))
    if log:
        log.parent.mkdir(parents=True, exist_ok=True)
        with log.open("w") as fh:
            p = subprocess.run(["bash", "-c", full], cwd=ROOT, stdout=fh, stderr=subprocess.STDOUT, env=e)
        tail = log.read_text(errors="replace").splitlines()[-15:]
        for line in tail[-4:]:
            print("    " + line, flush=True)
        if p.returncode:
            raise Refused(f"`{cmd}` failed ({p.returncode}); the end of {log.relative_to(ROOT)}:\n" + "\n".join(tail))
    else:
        p = subprocess.run(["bash", "-c", full], cwd=ROOT, env=e)
        if p.returncode:
            raise Refused(f"`{cmd}` failed ({p.returncode})")


def fetch(name: str, url: str, want: str | None, dest: Path) -> Path:
    if dest.is_file() and (not want or sha256(dest) == want):
        return dest
    dest.parent.mkdir(parents=True, exist_ok=True)
    say(f"downloading {name}")
    tmp = dest.with_suffix(dest.suffix + ".part")
    p = subprocess.run(["curl", "-fsSL", "--retry", "3", "-o", str(tmp), url])
    if p.returncode:
        tmp.unlink(missing_ok=True)
        raise Refused(f"cannot download {name} from {url}")
    if want and sha256(tmp) != want:
        got = sha256(tmp)
        tmp.unlink()
        raise Refused(f"{name}: {url} has sha256 {got}, not the {want} this recipe was proven with")
    tmp.replace(dest)
    return dest


def logs() -> Path:
    return PRIV / "logs" / "ios_inputs"


# ------------------------------------------------------------------ steps

def step_tools(a) -> None:
    for tool in ("clang-20", "llvm-nm-20", "git", "curl", "unzip"):
        if not shutil.which(tool):
            raise Refused(f"{tool} is not installed (Ubuntu 24.04: sudo apt-get install -y clang-20 llvm-20 git curl unzip)")
    g = TOOLS / "ghidra" / "ghidra_12.1.3_PUBLIC"
    if not (g / "support" / "analyzeHeadless").is_file():
        z = fetch("Ghidra", *DOWNLOADS["ghidra"], DL / "ghidra.zip")
        (TOOLS / "ghidra").mkdir(parents=True, exist_ok=True)
        sh(f"unzip -q -o {z} -d {TOOLS / 'ghidra'}")   # unzip keeps the launch scripts' modes
    j = TOOLS / "temurin21" / "jdk-21.0.12.1+1"
    if not (j / "bin" / "java").is_file():
        t = fetch("Temurin 21", *DOWNLOADS["jdk"], DL / "jdk.tgz")
        (TOOLS / "temurin21").mkdir(parents=True, exist_ok=True)
        sh(f"tar xzf {t} -C {TOOLS / 'temurin21'}")
    zdir = TOOLS / "zig" / "zig-x86_64-linux-0.15.2"
    if not (zdir / "zig").is_file():
        wheel_dir = DL / "zigwheel"
        wheel_dir.mkdir(parents=True, exist_ok=True)
        wheels = list(wheel_dir.glob("ziglang-0.15.2-*manylinux*x86_64*.whl"))
        if not wheels:
            say("downloading Zig 0.15.2 (PyPI's ziglang wheel)")
            sh(f"{PY} -m pip download ziglang==0.15.2 --no-deps --only-binary=:all: "
               f"--platform manylinux_2_12_x86_64 -d {wheel_dir} -q")
            wheels = list(wheel_dir.glob("ziglang-0.15.2-*.whl"))
        if not wheels or sha256(wheels[0]) != DOWNLOADS["zig_wheel"][1]:
            raise Refused(f"the ziglang 0.15.2 wheel is not the {DOWNLOADS['zig_wheel'][1]} this recipe was proven with")
        tmp = DL / "zigx"
        shutil.rmtree(tmp, ignore_errors=True)
        with zipfile.ZipFile(wheels[0]) as zf:
            zf.extractall(tmp)
        zdir.mkdir(parents=True, exist_ok=True)
        shutil.copytree(tmp / "ziglang", zdir, dirs_exist_ok=True)
        (zdir / "zig").chmod(0o755)
        shutil.rmtree(tmp)
    r = PRIV / "lifters" / "remill"
    if not list(r.rglob("remill-lift-14")):
        z = fetch("Remill 5.0.7", *DOWNLOADS["remill"], DL / "remill.zip")
        with zipfile.ZipFile(z) as zf:
            inner = [n for n in zf.namelist() if n.startswith("ubuntu-20.04_llvm14_tgz_package/") and n.endswith(".tar.gz")]
            if len(inner) != 1:
                raise Refused(f"{z} holds no one ubuntu-20.04 LLVM 14 package: {inner}")
            zf.extract(inner[0], DL)
        r.mkdir(parents=True, exist_ok=True)
        sh(f"tar xzf {DL / inner[0]} -C {r}")
    ml = TOOLS / "sa2-mod-loader"
    commit = PINS["tools"]["sa2-mod-loader"]["commit"]
    head = subprocess.run(["git", "-C", str(ml), "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
    if head != commit:
        shutil.rmtree(ml, ignore_errors=True)
        ml.mkdir(parents=True)
        sh(f"git -C {ml} init -q && git -C {ml} remote add origin https://github.com/X-Hax/sa2-mod-loader.git && "
           f"git -C {ml} fetch -q --depth 1 origin {commit} && git -C {ml} checkout -q FETCH_HEAD")
    sh(f"{PY} -m pip install -q meson==1.7.0")
    say("tools in place")


def unpacked_from(src: Path, dest: Path) -> None:
    """Steamless's output, its two renamed sections given the names the pinned copy has."""
    data = bytearray(src.read_bytes())
    head = bytes(data[:4096])
    for old, new in ((b".data\x00\x00\x00", b".dataa\x00\x00"), (b".rsrc\x00\x00\x00", b".rsrca\x00\x00")):
        at = head.find(old)
        if at >= 0:
            data[at:at + 8] = new
    want = PINS["executables"]["sonic2app-unpacked.exe"]["sha256"]
    got = hashlib.sha256(data).hexdigest()
    if got != want:
        raise Refused(f"{src} with its sections renamed has sha256 {got}, not the pinned {want}: run "
                      "Steamless 3.1.0.5 with its default options on the pinned sonic2app.exe")
    dest.write_bytes(bytes(data))
    dest.chmod(0o444)


def step_exe(a) -> None:
    ex = PRIV / "exe"
    ex.mkdir(parents=True, exist_ok=True)
    shipped, unpacked = ex / "sonic2app.exe", ex / "sonic2app-unpacked.exe"
    if a.exe and (not shipped.is_file() or sha256(Path(a.exe)) != sha256(shipped)):
        if shipped.exists():
            shipped.chmod(0o644)
        shutil.copyfile(a.exe, shipped)
        shipped.chmod(0o444)
    if not shipped.is_file():
        raise Refused("no private/exe/sonic2app.exe: pass --exe PATH (your Steam copy's sonic2app.exe)")
    if sha256(shipped) != PINS["executables"]["sonic2app.exe"]["sha256"]:
        raise Refused("private/exe/sonic2app.exe is not the pinned 2012 Steam executable")
    if a.unpacked:
        if unpacked.exists():
            unpacked.chmod(0o644)
        unpacked_from(Path(a.unpacked), unpacked)
    if not unpacked.is_file():
        raise Refused("no private/exe/sonic2app-unpacked.exe: run Steamless 3.1.0.5 on sonic2app.exe "
                      "(Windows, mono, or the CI's Windows job) and pass its output as --unpacked PATH")
    if sha256(unpacked) != PINS["executables"]["sonic2app-unpacked.exe"]["sha256"]:
        raise Refused("private/exe/sonic2app-unpacked.exe is not the pinned unpacked executable")
    say("both executables match their pins")


def step_helpers(a) -> None:
    pc = GEN / "spike" / "pc24pass" / "pc_round.ll"
    x87 = GEN / "s2" / "corpus_run" / "helper" / "x87_int.ll"
    if pc.is_file() and x87.is_file() and not a.forcing("helpers"):
        return
    (GEN / "spike" / "pc24pass" / "scratch").mkdir(parents=True, exist_ok=True)
    x87.parent.mkdir(parents=True, exist_ok=True)
    sh(f'"$SA2_ZIG" cc -target x86_64-linux-musl -O1 -g0 -S -emit-llvm -fno-discard-value-names '
       f"tools/spike/pc24pass/pc_round.c -o {pc} && (cd {x87.parent} && \"$SA2_ZIG\" cc -target x86_64-linux-musl "
       f"-O1 -g0 -S -emit-llvm -fno-discard-value-names {ROOT}/tools/s2/patch/x87_int.c -o x87_int.ll)")


def step_map(a) -> None:
    fmap = GEN / "function-map.json"
    if fmap.is_file() and not a.forcing("map"):
        return
    receipt = ROOT / "Documentation" / "receipts" / "s1-function-map-v1.json"
    tracked = subprocess.run(["git", "ls-files", "--error-unmatch", str(receipt)], cwd=ROOT,
                             capture_output=True).returncode == 0
    say("the function map: Ghidra's analysis takes about 15 minutes")
    sh(".venv/bin/python Documentation/scripts/s1_function_map.py", logs() / "map.log",
       env={"MAXMEM": os.environ.get("MAXMEM", "1536M")})
    if receipt.is_file() and not tracked:
        shutil.move(str(receipt), GEN / receipt.name)


def prune(*dirs: Path) -> None:
    for d in dirs:
        if d.is_dir():
            for f in d.glob("*.ll"):
                f.unlink()


def step_lift(a) -> None:
    log = GEN / "s3" / "whole_image" / "lift" / "next.jsonl"
    if log.is_file() and not a.forcing("lift"):
        return
    sh(f".venv/bin/python tools/s3/whole_image/lift_all.py --jobs {a.jobs} --tag next --to-next-entry",
       logs() / "lift.log")


def step_compile(a) -> None:
    log = GEN / "s3" / "whole_image" / "build" / "next.jsonl"
    if log.is_file() and not a.forcing("compile"):
        return
    sh(f".venv/bin/python tools/s3/whole_image/compile_all.py --jobs {a.jobs} --tag next", logs() / "compile.log")
    if a.prune:
        prune(GEN / "s3" / "whole_image" / "lift" / "next")


def step_arms(a) -> None:
    log = GEN / "s3" / "arms" / "arms.next.jsonl"
    if log.is_file() and not a.forcing("arms"):
        return
    sh(f".venv/bin/python tools/s3/arms/armlist.py --tag next --jobs {a.jobs}", logs() / "armlist.log")
    sh(f".venv/bin/python tools/s3/arms/lift_arms_image.py --tag next --jobs {a.jobs} "
       f"--armlist private/generated/s3/arms/armlist.next.json", logs() / "arms.log")
    if a.prune:
        prune(GEN / "s3" / "arms" / "lift" / "next")


def step_extras(a) -> None:
    state = GEN / "s4" / "link" / "extra_functions.next+allarms.json"
    if state.is_file() and not a.forcing("extras"):
        return
    sh(f".venv/bin/python tools/s4/lift_extras_listed.py --jobs {a.jobs}", logs() / "extras.log")
    if a.prune:
        prune(GEN / "s4" / "lift" / "ll")


def step_stage(a) -> None:
    edges = GEN / "s4" / "link" / "mb_edges.next+allarms.c"
    if edges.is_file() and not a.forcing("stage"):
        return
    sh(".venv/bin/python tools/s3/arms/stage_merged_build.py --tag next --merged-tag next+allarms",
       logs() / "stage.log")
    sh(".venv/bin/python tools/s3/whole_image/gen_table.py --tag next+allarms "
       "--out private/generated/s3/link/next+allarms/function_table_whole.c", logs() / "table.log")
    sh(".venv/bin/python tools/s4/mb_edges.py --tag next+allarms --lift-tag next --arms-tag next "
       "--allow-from private/generated/s4/link/extra_functions.next+allarms.json", logs() / "edges.log")


def step_overlay(a) -> None:
    table = GEN / "s7" / "exe-overlay" / "sa2_exe_overlay_table.c"
    if table.is_file() and not a.forcing("overlay"):
        return
    sh(".venv/bin/python tools/s7/drm_unwrap.py --readset-only", logs() / "readset.log")
    table.parent.mkdir(parents=True, exist_ok=True)
    sh(f".venv/bin/python tools/s7/text_readset.py --out {table}", logs() / "overlay.log")


def step_dxvk(a) -> None:
    s5 = PRIV / "s5-tools"
    pin = PINS["tools"]["dxvk"]
    src = ROOT / pin["path"]
    head = subprocess.run(["git", "-C", str(src), "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
    if head != pin["commit"]:
        shutil.rmtree(src, ignore_errors=True)
        src.parent.mkdir(parents=True, exist_ok=True)
        sh(f"git clone -q --branch {pin['tag']} --recurse-submodules {pin['url']} {src}")
    sdl_tgz = fetch("SDL3", PINS["tools"]["sdl3"]["url"], PINS["tools"]["sdl3"]["sha256"], ROOT / PINS["tools"]["sdl3"]["path"])
    inst = s5 / "install"
    cc_json = s5 / "build" / "dxvk" / "compile_commands.json"
    if cc_json.is_file() and (inst / "include" / "dxvk" / "d3d9.h").is_file() and not a.forcing("dxvk"):
        return
    # SDL3's headers and a pkg-config file for them: DXVK's configure asks for the dependency, and
    # nothing here links it.
    hdr = s5 / "build" / "sdl3-hdr"
    shutil.rmtree(hdr, ignore_errors=True)
    hdr.mkdir(parents=True)
    with tarfile.open(sdl_tgz) as tf:
        tf.extractall(hdr, filter="data")
    (inst / "include").mkdir(parents=True, exist_ok=True)
    shutil.copytree(hdr / f"SDL3-{PINS['tools']['sdl3']['version']}" / "include" / "SDL3", inst / "include" / "SDL3",
                    dirs_exist_ok=True)
    pc = inst / "lib" / "pkgconfig"
    pc.mkdir(parents=True, exist_ok=True)
    (pc / "sdl3.pc").write_text(f"prefix={inst}\nincludedir=${{prefix}}/include\nlibdir=${{prefix}}/lib\n"
                                f"Name: sdl3\nDescription: SDL3 headers (DXVK's configure only)\n"
                                f"Version: {PINS['tools']['sdl3']['version']}\nCflags: -I${{includedir}}\n"
                                f"Libs: -L${{libdir}} -lSDL3\n")
    fake = s5 / "fakebin"
    fake.mkdir(parents=True, exist_ok=True)
    (fake / "glslang").write_text('#!/bin/sh\necho "Glslang Version: 11:16.6.0"\nexit 0\n')
    (fake / "glslang").chmod(0o755)
    build = s5 / "build" / "dxvk"
    shutil.rmtree(build, ignore_errors=True)
    sh(f"PATH={fake}:$PATH PKG_CONFIG_PATH={pc} .venv/bin/meson setup {build} {src} --buildtype release "
       f"--prefix {inst} -Denable_d3d9=true -Denable_d3d8=false -Denable_d3d10=false -Denable_d3d11=false "
       f"-Denable_dxgi=false -Dnative_sdl3=enabled -Dnative_sdl2=disabled -Dnative_glfw=disabled",
       logs() / "dxvk-configure.log")
    n = sum("/subprojects/dxbc-spirv/" in e["file"] for e in json.loads(cc_json.read_text()))
    if n != 50:
        raise Refused(f"DXVK's configure named {n} dxbc-spirv units, not the 50 the app compiles")
    # DXVK Native's headers, as its meson install lays them out (include/native/meson.build).
    nat = src / "include" / "native"
    out = inst / "include" / "dxvk"
    (out / "wsi").mkdir(parents=True, exist_ok=True)
    for sub in ("directx", "windows"):
        for f in (nat / sub).rglob("*"):
            if f.is_file() and ".git" not in f.parts:
                t = out / f.relative_to(nat / sub)
                t.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(f, t)
    for h in ("native_wsi.h", "native_sdl3.h", "native_sdl2.h", "native_glfw.h"):
        shutil.copyfile(nat / "wsi" / h, out / "wsi" / h)
    say("DXVK configured, its headers installed")


def step_deps(a) -> None:
    for name in ("sdl3", "zlib", "zstd", "libpng"):
        pin = PINS["tools"][name]
        dest = ROOT / pin["path"]
        try:
            fetch(name, pin["url"], pin["sha256"], dest)
        except Refused as e:
            if name in MIRRORS:
                fetch(name, MIRRORS[name], pin["sha256"], dest)
            elif name == "libpng":
                say(f"libpng could not be fetched here ({e}); tools/s9/ios_mac.sh fetches it on the Mac")
            else:
                raise


def step_ios(a) -> None:
    summary = GEN / "s9" / "ios" / "objects-double" / "summary.json"
    if summary.is_file() and not a.forcing("ios"):
        if json.loads(summary.read_text()).get("legalized"):
            return
    say("compiling 24,036 modules for arm64-apple-ios: the longest step")
    sh(f".venv/bin/python tools/s9/ios_game.py compile --clang {shutil.which('clang-20')} --jobs {a.jobs}",
       logs() / "ios-compile.log")


def step_variants(a) -> None:
    rec = GEN / "s9" / "ios" / "variants" / "variants.rec"
    if rec.is_file() and not a.forcing("variants"):
        return
    sh(".venv/bin/python tools/s8/variants/variants.py build --objects private/generated/s9/ios/objects-double "
       "--out private/generated/s9/ios/variants", logs() / "variants.log",
       env={"SA2_NM": shutil.which("llvm-nm-20") or "llvm-nm"})


# What the Mac's link and app build read, relative to the checkout.
PACK = ["private/exe", "private/lifters/remill/usr/local/include",
        "private/generated/function-map.json",
        "private/generated/s3/whole_image/build/next.jsonl", "private/generated/s3/whole_image/build/next+allarms.jsonl",
        "private/generated/s3/whole_image/build/next+allarms", "private/generated/s3/whole_image/lift/next.jsonl",
        "private/generated/s3/arms/arms.next.jsonl", "private/generated/s3/arms/armlist.next.json",
        "private/generated/s3/arms/stage.next+allarms.json", "private/generated/s3/link",
        "private/generated/s4/link", "private/generated/s7", "private/generated/s9/ios/objects-double",
        "private/generated/s9/ios/variants",
        "private/s5-tools/build/dxvk", "private/s5-tools/install",
        "private/s5-tools/dl", "private/predecessor-tools/win-deps"]


def step_pack(a) -> None:
    out = Path(a.out).resolve() if a.out else GEN / "s9" / "ios" / "mac-inputs.tar.xz"
    missing = [p for p in PACK if not (ROOT / p).exists() and p != "private/predecessor-tools/win-deps"]
    if missing:
        raise Refused(f"not built yet: {missing}")
    say(f"packing {out.relative_to(ROOT) if out.is_relative_to(ROOT) else out}")
    out.parent.mkdir(parents=True, exist_ok=True)
    tmp = out.with_suffix(".part")
    items = " ".join(p for p in PACK if (ROOT / p).exists())
    sh(f"tar --exclude=.git --exclude='*.part' -cf - {items} | xz -T0 -6 > {tmp}")
    tmp.replace(out)
    say(f"{out.name}: {out.stat().st_size / 1e6:.0f} MB; the Mac half: bash tools/s9/ios_mac.sh {out}")


RUN = {"tools": step_tools, "exe": step_exe, "helpers": step_helpers, "map": step_map, "lift": step_lift,
       "compile": step_compile, "arms": step_arms, "extras": step_extras, "stage": step_stage,
       "overlay": step_overlay, "dxvk": step_dxvk, "deps": step_deps, "ios": step_ios,
       "variants": step_variants, "pack": step_pack}


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("step", choices=("all",) + STEPS)
    ap.add_argument("--exe", help="your Steam copy's sonic2app.exe (copied to private/exe)")
    ap.add_argument("--unpacked", help="Steamless's output for it (renamed and held to the pin)")
    ap.add_argument("--jobs", type=int, default=max(1, os.cpu_count() or 2))
    ap.add_argument("--force", action="append", default=[], choices=STEPS, help="redo this step")
    ap.add_argument("--prune", action="store_true", help="delete raw lifted IR once its objects are built")
    ap.add_argument("--out", help="the pack's archive (default private/generated/s9/ios/mac-inputs.tar.xz)")
    a = ap.parse_args(argv)
    a.forcing = lambda s: s in a.force
    if not PY.is_file():
        raise Refused("no .venv: python3.13 -m venv .venv && .venv/bin/python -m pip install -r requirements.txt")
    steps = STEPS if a.step == "all" else (a.step,)
    t0 = time.time()
    for s in steps:
        say(f"== {s}")
        RUN[s](a)
    say(f"IOS_INPUTS_OK {', '.join(steps)} in {(time.time() - t0) / 60:.0f} min")
    return 0


if __name__ == "__main__":
    sys.exit(main())
