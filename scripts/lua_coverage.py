#!/usr/bin/env python3
"""Which Lua the tests never run: the report for tests/lua_coverage.py.

    python scripts/lua_coverage.py cov.json [more.json ...] [-d frame|halo]
                                   [--lines] [name ...]

Several files are merged (the suite run in parts). Per file of the
glasses' upload (tests/sandbox.py) it counts the lines luac -l gives an
opcode, minus lines that are only `end`, `else` or a closing bracket, and
says how many of them ran. --lines lists the ones that did not; names
narrow the report to files whose name contains one. Needs luac 5.4 (the
devenv shell has it). docs/TESTING.md, "Which Lua the tests reach".
"""
import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tests"))
from sandbox import files  # noqa: E402

CLOSER = re.compile(r"\s*(end|else|\}|\)|end\)|end,|\{)?\s*(--.*)?")


def executable(path: Path) -> set[int]:
    out = subprocess.run(["luac", "-l", "-p", str(path)], capture_output=True,
                         text=True, check=True).stdout
    return {int(m.group(1))
            for m in re.finditer(r"^\s*\d+\s+\[(\d+)\]\s+\w+", out, re.M)}


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("json", nargs="+", help="coverage files, then names")
    ap.add_argument("-d", "--device", default="frame",
                    choices=("frame", "halo"))
    ap.add_argument("--lines", action="store_true")
    args = ap.parse_intermixed_args()
    paths = [a for a in args.json if a.endswith(".json")]
    only = [a for a in args.json if not a.endswith(".json")]

    cov: dict[str, set[int]] = {}
    for p in paths:
        for src, lines in json.load(open(p))[args.device].items():
            cov.setdefault(src, set()).update(lines)

    rows, total, ran = [], 0, 0
    for name, path in sorted(files(args.device).items()):
        if only and not any(o in name for o in only):
            continue
        src = path.read_text().splitlines()
        ex = executable(path)
        hit = cov.get("=" + name, cov.get(name, set()))
        missed = [l for l in sorted(ex - hit) if not CLOSER.fullmatch(src[l - 1])]
        total += len(ex)
        ran += len(ex & hit)
        rows.append((name, len(ex), len(ex & hit), missed, src))

    for name, n, h, missed, src in sorted(rows, key=lambda r: -len(r[3])):
        print(f"{name:28s} {h:4d}/{n:<4d} {100 * h // n if n else 100:3d}%"
              f"  missed {len(missed)}")
        if args.lines:
            last = -2
            for l in missed:
                if l != last + 1:
                    print("    ...")
                print(f"    {l:4d}  {src[l - 1].rstrip()}")
                last = l
    print(f"\nTOTAL {ran}/{total} = {100 * ran // max(total, 1)}%")


if __name__ == "__main__":
    main()
