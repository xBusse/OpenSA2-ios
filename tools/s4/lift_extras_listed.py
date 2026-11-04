#!/usr/bin/env python3
"""The lifted extras, rebuilt from the tracked list: Documentation/lifted-extras.json.

Subtitle: tools/s4/lift_extra.py's state file (private/generated/s4/link/extra_functions.<tag>.json
and its registry C), made on a machine that has never run the stage plays the list was grown from.

`lift_extra.py` grows the extras from runs (`--from-census`, `--from-list`, `--seed-arms`, ...), and
`tools/s4/track_extra_functions.py` records each registered row in the tracked list. A new build
machine (a cloud VM, a CI runner) has the list and not the runs. This lifts and compiles every row
the list holds as compiled and not rejected, with lift_extra's own `lift_one` and `fold_and_compile`
and the row's own range and anchor, then applies lift_extra's rejection loop (a module that declares
a `sub_` no module defines is rejected, until nothing changes) and writes its registry and state, so
everything downstream (rebuild_image.py, stage_merged_build.py, mb_edges.py --allow-from, the links)
reads them as lift_extra wrote them.

It refuses unless every listed row lifts, compiles and registers: a row that does not is a change in
the lift or the pass since the list was recorded, which the list's own tools must look at.

Usage:
  source tools/env.sh
  .venv/bin/python tools/s4/lift_extras_listed.py [--jobs 2]
"""
from __future__ import annotations

import argparse
import json
import multiprocessing
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
for d in ("tools/s4", "tools/s3/whole_image"):
    sys.path.insert(0, str(ROOT / d))
import common as C  # noqa: E402
import lift_extra as LE  # noqa: E402

LIST = ROOT / "Documentation" / "lifted-extras.json"
_IMAGE: bytes | None = None


def _one(r: dict) -> dict:
    va, end = int(r["va"], 16), int(r["end"], 16)
    anchor = int(r["anchor"], 16) if r.get("anchor") else None
    rec = LE.lift_one(va, end, _IMAGE, LE.OUT / "ll", anchor)
    rec["why"] = r["why"]
    rec["owner"] = r["owner"]
    if r.get("anchor"):
        rec.setdefault("anchor", r["anchor"])
    if rec.get("lifted"):
        rec.update(LE.fold_and_compile(va, LE.OUT / "ll", LE.OUT / "fold", LE.OUT / "obj"))
    return rec


def main() -> int:
    global _IMAGE
    ap = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    ap.add_argument("--jobs", type=int, default=2)
    args = ap.parse_args()
    doc = json.loads(LIST.read_text())
    tag, lift_tag, arms_tag = doc["tag"], doc["lift_tag"], doc["arms_tag"]
    want = [r for r in doc["rows"] if r.get("compiled") and not r.get("rejected")]
    for d in (LE.OUT / "ll", LE.OUT / "fold", LE.OUT / "obj"):
        d.mkdir(parents=True, exist_ok=True)
    LE.LINKDIR.mkdir(parents=True, exist_ok=True)
    _IMAGE = C.memory_image()
    rows, t0 = [], time.time()
    with multiprocessing.get_context("fork").Pool(args.jobs) as pool:
        for k, rec in enumerate(pool.imap(_one, want, chunksize=4), 1):
            rows.append(rec)
            if not rec.get("compiled"):
                print(f"{rec['va']}: lifted={rec.get('lifted')} compiled={rec.get('compiled')} "
                      f"{rec.get('error_head', '')[:160]}", flush=True)
            if k % 500 == 0:
                print(f"  {k}/{len(want)} {time.time() - t0:.0f}s", flush=True)
    rows.sort(key=lambda r: int(r["va"], 16))
    # lift_extra.py's rejection loop, unchanged in meaning.
    defined = {f"sub_{va:x}" for va, _e, _n in LE.module_ranges(lift_tag, arms_tag)}
    rejected = []
    while True:
        avail = defined | {f"sub_{int(r['va'], 16):x}" for r in rows if r.get("compiled") and not r.get("rejected")}
        changed = False
        for r in rows:
            if not r.get("compiled") or r.get("rejected"):
                continue
            missing = [d for d in r.get("declares_sub", []) if d not in avail]
            if missing:
                r["rejected"] = True
                r["rejected_why"] = "declares " + ", ".join(missing[:4]) + ", which no module in this build defines"
                rejected.append(r["va"])
                changed = True
        if not changed:
            break
    good = [r for r in rows if r.get("compiled") and not r.get("rejected")]
    registry = LE.LINKDIR / f"extra_functions.{tag}.c"
    LE.emit_registry(good, registry, tag)
    state = {"rows": rows, "tag": tag, "lift_tag": lift_tag, "arms_tag": arms_tag,
             "rejected": len(rejected), "rejected_head": rejected[:20], "registered": len(good),
             "attempted": len(rows), "objects": [r["object"] for r in good], "registry_c": str(registry),
             "rebuilt_from": str(LIST.relative_to(ROOT))}
    (LE.LINKDIR / f"extra_functions.{tag}.json").write_text(json.dumps(state, indent=1) + "\n")
    print(json.dumps({"listed": len(want), "registered": len(good), "rejected": len(rejected),
                      "seconds": round(time.time() - t0)}))
    if len(good) != len(want):
        print(f"LIFT_EXTRAS_LISTED_REFUSED {len(want) - len(good)} listed row(s) did not register "
              f"(first rejected {rejected[:5]})", file=sys.stderr)
        return 1
    print("LIFT_EXTRAS_LISTED_OK", registry)
    return 0


if __name__ == "__main__":
    sys.exit(main())
