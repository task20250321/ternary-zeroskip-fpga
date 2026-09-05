# Copyright 2026 Yu Inoue
# SPDX-License-Identifier: Apache-2.0
#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
from pathlib import Path
import numpy as np


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("case", type=Path)
    args = ap.parse_args()
    case = args.case.resolve()

    out_path = case / "vcs_results/vcs_outputs.txt"
    perm_path = case / "output_physical_to_global.csv"
    ref_path = case / "expected_outputs_canonical.npy"
    if not out_path.exists():
        raise FileNotFoundError(out_path)

    physical = []
    for line in out_path.read_text().splitlines():
        if not line.strip():
            continue
        a, b = line.split()[:2]
        physical.append((int(a), int(b)))

    with perm_path.open() as f:
        rows = list(csv.DictReader(f))
    perm = np.asarray([int(r["global_output"]) for r in rows], dtype=np.int64)
    if ref_path.exists():
        ref = np.load(ref_path).astype(np.int64).reshape(-1)
    else:
        ref_txt_path = ref_path.with_suffix(".txt")

        if not ref_txt_path.exists():
            raise FileNotFoundError(
                f"missing canonical reference: "
                f"{ref_path} or {ref_txt_path}"
            )

        values = []

        for line in ref_txt_path.read_text().splitlines():
            line = line.strip()

            if not line:
                continue

            # Supports both:
            #   value
            # and:
            #   index<TAB>value
            token = line.split()[-1]

            try:
                values.append(int(token, 0))
            except ValueError:
                # Allows an optional text header.
                continue

        ref = np.asarray(values, dtype=np.int64).reshape(-1)

    if len(physical) != len(perm):
        raise RuntimeError(f"outputs={len(physical)} permutation={len(perm)}")

    canonical = np.empty_like(ref)
    seen = np.zeros(len(ref), dtype=np.bool_)
    for phys_idx, value in physical:
        if phys_idx < 0 or phys_idx >= len(perm):
            raise RuntimeError(f"bad physical index {phys_idx}")
        g = int(perm[phys_idx])
        if seen[g]:
            raise RuntimeError(f"duplicate global output {g}")
        canonical[g] = int(value)
        seen[g] = True

    if not np.all(seen):
        missing = np.flatnonzero(~seen)[:20]
        raise RuntimeError(f"missing global outputs: {missing.tolist()}")

    bad = np.flatnonzero(canonical != ref)
    if len(bad):
        print(f"FAIL mismatches={len(bad)}")
        for i in bad[:20]:
            print(f"output[{i}] expected={int(ref[i])} got={int(canonical[i])}")
        raise SystemExit(1)

    np.savetxt(case / "vcs_results/vcs_outputs_canonical.txt", canonical, fmt="%d")
    print(f"PASS: canonical reorder matches software reference ({len(ref)} outputs)")


if __name__ == "__main__":
    main()
