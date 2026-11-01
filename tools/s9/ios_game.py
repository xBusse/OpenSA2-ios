#!/usr/bin/env python3
"""ios_game: build the game for the iOS app (arm64-apple-ios15.0) as one prelinked library.

Subtitle: the Android game (tools/s8/android_game.py) built for iOS. iOS lets an app start no other
program, so the game is not an executable here but a library the app links (host/ios/native/
sa2_ios_game.h says what stands in for the game's process): the lifted image, the runtime, the hooks
(the launch observer and the presentation recorder), the overlay table and the driver
(harness/crt_probe.c, its main renamed sa2_game_main) prelinked into one relocatable object whose
only global symbols are host/ios/native/sa2_ios_game.exports, so nothing of the game's can meet a
symbol of the player's, SDL's or the app's, and archived as libsa2game.a.

Three differences from the Android build, each forced by the platform:

* **The lifted modules' compiler.** The lifted IR is LLVM 20 text, which Xcode's clang does not read,
  so the modules are compiled by an LLVM 20 clang (Homebrew's llvm@20, `--clang`; any LLVM 20 build
  does) for the triple arm64-apple-ios15.0, which reserves x18 as Darwin's platform register, as the
  Android triple does for bionic. That step needs no SDK and runs on Linux too. The f80 pass is the
  Android build's (tools/s7/f80_legalize.py, or tools/s8/f80_double.py with `--f80 double`, the
  default here as in the desktop development builds).
* **--wrap.** Apple's linker has no -wrap, which the runtime's wraps of lifted functions use
  (tools/s4/link_s4.py PRODUCTION_WRAPS, the hooks' and the tweaks' wraps). Its effect is made on
  the objects instead (macho_wrap.py): in every object where `X` is undefined, the reference is
  renamed `__wrap_X`, and in every object where `__real_X` is undefined, that reference is renamed
  `X`, exactly the references GNU ld's -wrap redirects (an object's references to a symbol it
  defines itself are left alone by both). The renamed objects are copies; the compiled ones are
  never changed.
* **The game's end.** The game's C and C++ (the runtime, the hooks, the driver) are compiled with
  exit, _exit and atexit renamed to host/ios/native/sa2_ios_game.c's (GAME_DEFINES), so the game's
  end ends its thread, not the app.

The runtime and the driver are compiled by Xcode's clang for the iOS SDK (`xcrun -sdk iphoneos`),
with arm64_link.py's -ffp-contract=off and -funsigned-char (char is unsigned on Linux's and
Android's arm64, where the runtime was validated; Darwin's is signed). The prelink is `ld -r` with
-exported_symbols_list; libsa2game.a holds that one object.

Subcommands:
  compile   the lifted image for arm64-apple-ios15.0 into --objects (default
            private/generated/s9/ios/objects-<f80 mode>), cross_build's populations, legalised, with
            build.jsonl and summary.json as android_game's compile writes them. Needs only --clang.
  link      (macOS, Xcode) compile the C, rename for the wraps, prelink and archive
            private/generated/s9/ios/game/libsa2game.a, with game.env beside it and link.rec (JSON:
            every source and object by sha256, the flags, the wraps, the renamed objects).

Usage (the inputs are the Linux build's: copy the checkout's private/ to the Mac first):
  .venv/bin/python tools/s9/ios_game.py compile --clang /opt/homebrew/opt/llvm@20/bin/clang --jobs 8
  .venv/bin/python tools/s9/ios_game.py link --llvm /opt/homebrew/opt/llvm@20/bin
Outputs live under private/generated/s9/ios/ (never tracked: the library is the lifted game).
"""
from __future__ import annotations

import argparse
import concurrent.futures as cf
import hashlib
import json
import multiprocessing
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path


def _root() -> Path:
    for p in Path(__file__).resolve().parents:
        if (p / "AGENTS.md").is_file() and (p / "tools" / "pins.json").is_file():
            return p
    raise SystemExit(f"no repository above {__file__}")


ROOT = _root()
SELF = "tools/s9/ios_game.py"
for d in ("tools/s4", "tools/s3/whole_image", "tools/s7", "tools/spike", "tools/s8", "tools/s9"):
    sys.path.insert(0, str(ROOT / d))

IOS_MIN = "15.0"
TRIPLE = f"arm64-apple-ios{IOS_MIN}"
GEN = ROOT / "private" / "generated"
S9 = GEN / "s9" / "ios"
OUT = S9 / "game"
WORK = S9 / "work"
F80_SHIMS = {"exact": ROOT / "tools" / "s7" / "f80_shims.c",
             "double": ROOT / "tools" / "s8" / "f80_shims_double.c"}
FP_FLAGS = ("-ffp-contract=off",)
# The game's own sources end its thread, not the app (host/ios/native/sa2_ios_game.h).
GAME_DEFINES = ("-Dexit=sa2_ios_game_exit", "-D_exit=sa2_ios_game__exit", "-Datexit=sa2_ios_game_atexit")
MAIN_DEFINES = ("-Dmain=sa2_game_main",)
IOS_NATIVE = ROOT / "host" / "ios" / "native"
EXPORTS = IOS_NATIVE / "sa2_ios_game.exports"
LIBRARY = "libsa2game.a"
LINK_REC = "link.rec"
# Flags of the lifted modules' own command that name an ELF or a PIC model Mach-O has no use for.
ELF_ONLY = re.compile(r"^-f(no-)?(pic|PIC|pie|PIE|plt)$|^-mcmodel=|^-static$|^-fuse-ld=|^-Wl,")


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def rel(path: Path) -> str:
    path = Path(path)
    return str(path.relative_to(ROOT)) if path.is_relative_to(ROOT) else str(path)


def objects_dir(f80: str) -> Path:
    return S9 / f"objects-{f80}"


# ------------------------------------------------------------------ compile (the lifted image)

_CLANG: str | None = None


def ios_compile_command(pop: str, triple: str, ir: Path, obj: Path) -> list[str]:
    """The population's own command (cross_build), its compiler replaced by the LLVM 20 clang and its
    target by arm64-apple-ios; the flags that name an ELF dropped."""
    import cross_build as XB  # noqa: PLC0415
    cmd = XB._original_compile_command(pop, "aarch64-linux-musl", ir, obj)
    at = cmd.index("-target")
    rest = [f for f in cmd[at + 2:] if not ELF_ONLY.match(f)]
    return [_CLANG or "clang", "-target", triple, *rest]


def _worker_init(f80: str, clang: str) -> None:
    global _CLANG
    _CLANG = clang
    import cross_build as XB  # noqa: PLC0415
    import f80_double as D  # noqa: PLC0415
    import f80_legalize as F  # noqa: PLC0415
    if not hasattr(XB, "_original_compile_command"):
        XB._original_compile_command = XB.compile_command
        XB.compile_command = ios_compile_command
    if not hasattr(F, "_legalize_exact"):
        F._legalize_exact = F.legalize
    F.legalize = D.legalize if f80 == "double" else F._legalize_exact


def clang_major(clang: str) -> int:
    out = subprocess.run([clang, "--version"], capture_output=True, text=True).stdout
    m = re.search(r"clang version (\d+)\.", out)
    if not m:
        raise SystemExit(f"{clang} --version names no clang version: {out[:200]!r}")
    return int(m.group(1))


def compile_image(args: argparse.Namespace) -> int:
    major = clang_major(args.clang)
    if major != 20:
        raise SystemExit(f"{args.clang} is clang {major}: the lifted IR is LLVM 20 text (brew install llvm@20)")
    _worker_init(args.f80, args.clang)
    import cross_build as XB  # noqa: PLC0415
    outdir = Path(args.objects or objects_dir(args.f80)).resolve()
    pops = XB.populations()
    chosen = [p for p in args.populations.split(",") if p]
    for p in chosen:
        if p not in pops:
            raise SystemExit(f"unknown population {p}; known: {sorted(pops)}")
        (outdir / p).mkdir(parents=True, exist_ok=True)
    (outdir / "tmp").mkdir(parents=True, exist_ok=True)
    jobs = []
    for p in chosen:
        mods = pops[p][: args.limit] if args.limit else pops[p]
        jobs += [(p, va, str(src), str(outdir), TRIPLE, True, False) for va, src in mods]
    print(f"target={TRIPLE} f80={args.f80} clang={args.clang} out={outdir} modules={len(jobs)} jobs={args.jobs}",
          flush=True)
    log = outdir / "build.jsonl"
    t0 = time.time()
    n = ok = 0
    ctx = multiprocessing.get_context("fork")
    with log.open("w") as fh, cf.ProcessPoolExecutor(args.jobs, mp_context=ctx, initializer=_worker_init,
                                                     initargs=(args.f80, args.clang)) as ex:
        for rec in ex.map(XB.one, jobs, chunksize=4):
            fh.write(json.dumps(rec, sort_keys=True) + "\n")
            n += 1
            ok += bool(rec.get("compiled"))
            if n % 1000 == 0:
                print(f"  {n}/{len(jobs)} compiled={ok} {time.time() - t0:.0f}s", flush=True)
    shutil.rmtree(outdir / "tmp", ignore_errors=True)
    recs = [json.loads(line) for line in log.read_text().splitlines()]
    summary = {
        "schema": "sa2-s9-ios-cross-build/v1", "generated_by": SELF, "target": TRIPLE, "f80_mode": args.f80,
        "clang": subprocess.run([args.clang, "--version"], capture_output=True, text=True).stdout.splitlines()[0],
        "out": rel(outdir), "jobs": args.jobs, "wall_seconds": round(time.time() - t0, 1),
        "commands": {p: ios_compile_command(p, TRIPLE, Path("{ir}"), Path("{object}")) for p in chosen},
        "modules": len(recs), "compiled": sum(bool(r.get("compiled")) for r in recs),
        "errors": {}, "refused": {}}
    for r in recs:
        if "refused" in r:
            k = r["refused"][:160]
            summary["refused"][k] = summary["refused"].get(k, 0) + 1
        elif not r.get("compiled"):
            k = (r.get("error_head") or "?").splitlines()[0][:200]
            summary["errors"][k] = summary["errors"].get(k, 0) + 1
    (outdir / "summary.json").write_text(json.dumps(summary, indent=1) + "\n")
    print(json.dumps({k: summary[k] for k in ("target", "modules", "compiled", "wall_seconds", "errors", "refused")},
                     indent=1))
    return 0 if summary["compiled"] == summary["modules"] else 1


# ------------------------------------------------------------------ link (macOS)

def xcrun(*args: str) -> str:
    p = subprocess.run(["xcrun", *args], capture_output=True, text=True)
    if p.returncode:
        raise SystemExit(f"xcrun {' '.join(args)}: {p.stderr.strip()[:400]} (is Xcode installed and selected?)")
    return p.stdout.strip()


def compile_job(job: tuple) -> dict:
    name, cmd, obj = job
    t0 = time.time()
    if obj.exists():
        obj.unlink()
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=7200)
    rec = {"rc": p.returncode, "seconds": round(time.time() - t0, 2)}
    if p.returncode:
        rec["stderr_tail"] = p.stderr[-3000:]
    else:
        rec["object_sha256"] = sha256(obj)
    return {name: rec}


def link_game(args: argparse.Namespace) -> int:
    if sys.platform != "darwin":
        raise SystemExit("link runs on macOS with Xcode (the runtime is compiled for the iOS SDK); compile runs anywhere")
    import android_game as AG  # noqa: PLC0415  the Android build's plan and lifted inputs, never retyped
    import common as C  # noqa: PLC0415
    import link_s4 as L4  # noqa: PLC0415
    import macho_wrap as MW  # noqa: PLC0415
    src = ROOT
    objects = Path(args.objects or objects_dir(args.f80)).resolve()
    summary = json.loads((objects / "summary.json").read_text())
    if summary.get("target") != TRIPLE or summary.get("f80_mode") != args.f80:
        raise SystemExit(f"{objects} holds {summary.get('target')} objects in the f80 mode {summary.get('f80_mode')}; "
                         f"this link asks for {TRIPLE}, --f80 {args.f80}")
    out = Path(args.out).resolve() if args.out else OUT
    work = Path(os.path.abspath(args.work)) if args.work else WORK
    out.mkdir(parents=True, exist_ok=True)
    work.mkdir(parents=True, exist_ok=True)
    plan = AG.plan_for("game", src, work)
    lifted = AG.lifted_inputs(objects, work / "linkdir")
    sdk = xcrun("--sdk", "iphoneos", "--show-sdk-path")
    sdk_version = xcrun("--sdk", "iphoneos", "--show-sdk-version")
    cc = xcrun("--sdk", "iphoneos", "--find", "clang")
    cxx = xcrun("--sdk", "iphoneos", "--find", "clang++")
    llvm = Path(args.llvm)
    llvm_clang = llvm / "clang"
    if clang_major(str(llvm_clang)) != 20:
        raise SystemExit(f"{llvm_clang} is not clang 20 (the lifted extras' registration needs it, as on Android)")
    target = ["-target", TRIPLE, "-isysroot", sdk]
    # -fno-common: a tentative definition (`uint64_t x;`) stays a common symbol through `ld -r`,
    # which -exported_symbols_list does not hide, so the game would export its globals.
    common = [L4.OPT, "-w", *FP_FLAGS, "-funsigned-char", "-fno-common", "-I", str(src / "runtime"), "-I", str(C.REMILL_INC)]
    cflags = [cc, *target, *common, *GAME_DEFINES, "-c"]
    cxxflags = [cxx, *target, *common, *GAME_DEFINES, "-std=c++17", "-c"]
    table = GEN / "s3" / "link" / AG.TAG / "function_table_whole.c"
    sources = [(s, src / "runtime" / s, cflags) for s in L4.RUNTIME_C]
    sources += [(s, src / "runtime" / s, cxxflags) for s in L4.RUNTIME_CXX]
    sources.append(("function_table_whole.c", table, cflags))
    if plan["overlay"] is not None:
        sources.append((L4.exe_overlay_object(sha256(plan["overlay"])), plan["overlay"], cflags))
    # The extras' registration by the LLVM 20 clang, as Android compiles it by zig's (one function of
    # thousands of calls, which an older clang takes many minutes over); it includes only stdint.h.
    zflags = [str(llvm_clang), *target, *common, "-c"]
    sources += [(f"extra{k}_{x.stem}.c", x, zflags if x.name.startswith("extra_functions.") else cflags)
                for k, x in enumerate(plan["extra"])]
    sources.append(("main.c", plan["main"], [*cflags, *MAIN_DEFINES]))
    # The game's thread and its end, without the renames (it defines the renamed functions).
    sources.append(("sa2_ios_game.c", IOS_NATIVE / "sa2_ios_game.c", [cc, *target, *common, "-c"]))
    sources.append(("f80_shims.c", F80_SHIMS[args.f80], [cc, *target, "-O2", "-w", *FP_FLAGS, "-c"]))
    objdir = work / "obj"
    objdir.mkdir(parents=True, exist_ok=True)
    jobs, log = [], {}
    for name, path, flags in sources:
        if not Path(path).is_file():
            raise SystemExit(f"{path} is not there ({name})")
        obj = objdir / (Path(name).stem + ".o")
        jobs.append((name, [str(f) for f in flags] + [str(path), "-o", str(obj)], obj))
        log[name] = {"source": rel(path), "source_sha256": sha256(path)}
    t0 = time.time()
    with cf.ThreadPoolExecutor(max(1, args.jobs)) as ex:
        for done in ex.map(compile_job, jobs):
            for k, v in done.items():
                log[k].update(v)
    bad = {k: v for k, v in log.items() if v.get("rc")}
    if bad:
        raise SystemExit("compile failed: " + "; ".join(f"{k}: {v.get('stderr_tail', '')[-800:]}" for k, v in bad.items()))
    compile_seconds = round(time.time() - t0, 1)

    # --wrap on Mach-O (the module's header): the references renamed in copies.
    wrapped = list(L4.PRODUCTION_WRAPS) + list(plan["wraps"])
    inputs = ([o for _, _, o in jobs] + [Path(x) for x in lifted["extras"]]
              + [work / "linkdir" / n for n in lifted["whole"]])
    t1 = time.time()
    wrapdir = work / "wrapped"
    renamed = MW.apply(inputs, wrapped, wrapdir, nm=str(llvm / "llvm-nm"), objcopy=str(llvm / "llvm-objcopy"),
                       jobs=args.jobs)
    final = [renamed.get(str(o), o) for o in inputs]
    wrap_seconds = round(time.time() - t1, 1)

    # The prelink: one object, only the game's interface global.
    filelist = work / "objects.txt"
    filelist.write_text("\n".join(str(o) for o in final) + "\n")
    prelinked = work / "sa2game.o"
    if prelinked.exists():
        prelinked.unlink()
    t2 = time.time()
    # -d: any common symbol left (an object compiled elsewhere) is defined here, so the export
    # list hides it too.
    ld = [xcrun("--sdk", "iphoneos", "--find", "ld"), "-r", "-d", "-arch", "arm64",
          "-platform_version", "ios", IOS_MIN, sdk_version,
          "-exported_symbols_list", str(EXPORTS), "-filelist", str(filelist), "-o", str(prelinked)]
    p = subprocess.run(ld, capture_output=True, text=True, timeout=7200)
    if p.returncode:
        raise SystemExit(f"ld -r failed ({p.returncode}):\n{p.stderr[-4000:]}")
    library = out / LIBRARY
    if library.exists():
        library.unlink()
    q = subprocess.run([xcrun("--sdk", "iphoneos", "--find", "libtool"), "-static", "-o", str(library), str(prelinked)],
                       capture_output=True, text=True)
    if q.returncode:
        raise SystemExit(f"libtool failed: {q.stderr[-2000:]}")
    exported = subprocess.run([str(llvm / "llvm-nm"), "-g", "--defined-only", "-j", str(prelinked)],
                              capture_output=True, text=True).stdout.split()
    expected = [l.strip() for l in EXPORTS.read_text().splitlines() if l.strip()]
    if sorted(exported) != sorted(expected):
        extra, missing = sorted(set(exported) - set(expected)), sorted(set(expected) - set(exported))
        raise SystemExit(f"the prelinked game's exports are not {EXPORTS.name}'s: {len(extra)} more "
                         f"(first {extra[:12]}), {len(missing)} missing {missing}")
    (out / "game.env").write_text("\n".join(plan["env_lines"]) + "\n")
    rec = {"schema": "sa2-s9-ios-link/v1", "generated_by": SELF, "triple": TRIPLE, "sdk": sdk_version,
           "f80_mode": args.f80, "hooks": plan["hooks"], "wraps": plan["wraps"], "wrapped": wrapped,
           "game_defines": list(GAME_DEFINES), "main": rel(plan["main"]),
           "exe_overlay": ({"table": rel(plan["overlay"]), "sha256": sha256(plan["overlay"])} if plan["overlay"] else None),
           "flags_c": cflags[1:], "flags_cxx": cxxflags[1:], "flags_llvm20": zflags[1:], "compile": log,
           "compile_seconds": compile_seconds, "wrap_seconds": wrap_seconds,
           "renamed_objects": len(renamed), "lifted": {"objects": rel(objects), "records": lifted["records"],
                                                        "whole_image": len(lifted["whole"]), "extras": len(lifted["extras"])},
           "prelink": {"command": ld[1:], "seconds": round(time.time() - t2, 1), "exported": sorted(exported)},
           "library": rel(library), "library_sha256": sha256(library), "library_bytes": library.stat().st_size,
           "game_env": plan["env_lines"]}
    (out / LINK_REC).write_text(json.dumps(rec, indent=1, sort_keys=True) + "\n")
    print(json.dumps({k: rec[k] for k in ("library", "library_bytes", "compile_seconds", "wrap_seconds",
                                          "renamed_objects")}, indent=1))
    print("IOS_GAME_OK", library)
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("compile", help="the lifted image for arm64-apple-ios (anywhere with an LLVM 20 clang)")
    c.add_argument("--clang", required=True, help="an LLVM 20 clang (Homebrew: /opt/homebrew/opt/llvm@20/bin/clang)")
    c.add_argument("--f80", choices=("double", "exact"), default="double")
    c.add_argument("--objects", default=None)
    c.add_argument("--populations", default="map,arms,extra")
    c.add_argument("--limit", type=int, default=0, help="the first N modules of each population (a smoke test)")
    c.add_argument("--jobs", type=int, default=max(1, (os.cpu_count() or 4) // 2))
    l = sub.add_parser("link", help="(macOS) the runtime, the wraps, the prelink and libsa2game.a")
    l.add_argument("--llvm", required=True, help="the LLVM 20 bin folder: clang, llvm-nm, llvm-objcopy")
    l.add_argument("--f80", choices=("double", "exact"), default="double")
    l.add_argument("--objects", default=None)
    l.add_argument("--out", default=None)
    l.add_argument("--work", default=None)
    l.add_argument("--jobs", type=int, default=max(1, (os.cpu_count() or 4) // 2))
    a = ap.parse_args(argv)
    return compile_image(a) if a.cmd == "compile" else link_game(a)


if __name__ == "__main__":
    sys.exit(main())
