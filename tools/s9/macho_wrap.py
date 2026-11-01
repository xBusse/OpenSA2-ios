#!/usr/bin/env python3
"""macho_wrap: GNU ld's -wrap made on Mach-O objects, for a linker that has none (Apple's).

Subtitle: tools/s9/ios_game.py links the runtime's wraps of lifted functions (tools/s4/link_s4.py
PRODUCTION_WRAPS, the hooks' and the tweaks' wraps) with Apple's ld, which has no -wrap. GNU ld's
-wrap=X redirects *undefined* references only: an undefined `X` resolves to `__wrap_X`, and an
undefined `__real_X` resolves to `X`; an object's references to a symbol it defines are not touched.
This makes the same redirection in the objects themselves, before the link: every object in which
`X` is undefined gets the reference renamed `__wrap_X`, and every object in which `__real_X` is
undefined gets it renamed `X` (llvm-objcopy --redefine-sym, which renames that object's symbol table
entry). Objects with nothing to rename are linked as they are; the renamed ones are copies under the
output folder, so a compiled object is never changed (the lifted ones are hard links to the compile's).

Mach-O spells a C symbol with a leading underscore (`sub_427ee0` is `_sub_427ee0`); the names given
here are C names.

  apply(objects, wraps, outdir, nm=..., objcopy=...) -> {original path: renamed copy}
  plan(undefined, wraps) -> {mach-o symbol: new mach-o symbol}   (the pure part, tested)
"""
from __future__ import annotations

import concurrent.futures as cf
import shutil
import subprocess
from pathlib import Path

BATCH = 400


def plan(undefined: set[str] | list[str], wraps: set[str] | list[str]) -> dict[str, str]:
    """The renames GNU ld's -wrap makes of one object's undefined Mach-O symbols."""
    wrap = set(wraps)
    out: dict[str, str] = {}
    for sym in undefined:
        if not sym.startswith("_"):
            continue
        name = sym[1:]
        if name in wrap:
            out[sym] = "___wrap_" + name
        elif name.startswith("__real_") and name[len("__real_"):] in wrap:
            out[sym] = "_" + name[len("__real_"):]
    return out


def undefined_symbols(objects: list[Path], nm: str) -> dict[str, set[str]]:
    """{object path: its undefined symbols}, by llvm-nm -u -A -j over batches of objects."""
    out: dict[str, set[str]] = {str(o): set() for o in objects}
    batches = [objects[i:i + BATCH] for i in range(0, len(objects), BATCH)]

    def one(batch: list[Path]) -> list[tuple[str, str]]:
        p = subprocess.run([nm, "-u", "-A", "-j", *map(str, batch)], capture_output=True, text=True)
        if p.returncode:
            raise SystemExit(f"{nm} -u failed: {p.stderr.strip()[:400]}")
        rows = []
        for line in p.stdout.splitlines():
            if ": " not in line:
                continue
            path, sym = line.rsplit(": ", 1)
            rows.append((path, sym.strip()))
        return rows

    with cf.ThreadPoolExecutor(8) as ex:
        for rows in ex.map(one, batches):
            for path, sym in rows:
                if path in out and sym:
                    out[path].add(sym)
    return out


def apply(objects: list[Path], wraps: list[str], outdir: Path, nm: str, objcopy: str, jobs: int = 4) -> dict[str, Path]:
    """Renamed copies of the objects that need them, under `outdir` (emptied first)."""
    objects = [Path(o) for o in objects]
    if outdir.exists():
        shutil.rmtree(outdir)
    outdir.mkdir(parents=True)
    undefined = undefined_symbols(objects, nm)
    todo = []
    for i, o in enumerate(objects):
        renames = plan(undefined[str(o)], wraps)
        if renames:
            todo.append((i, o, renames))

    def rename(job: tuple[int, Path, dict[str, str]]) -> tuple[str, Path]:
        i, o, renames = job
        copy = outdir / f"{i:06d}_{o.name}"
        shutil.copyfile(o, copy)
        args = [objcopy]
        for old, new in sorted(renames.items()):
            args += ["--redefine-sym", f"{old}={new}"]
        p = subprocess.run([*args, str(copy)], capture_output=True, text=True)
        if p.returncode:
            raise SystemExit(f"{objcopy} on {o}: {p.stderr.strip()[:400]}")
        return str(o), copy

    with cf.ThreadPoolExecutor(max(1, jobs)) as ex:
        return dict(ex.map(rename, todo))
