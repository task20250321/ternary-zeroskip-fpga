# Copyright 2026 Yu Inoue
# SPDX-License-Identifier: Apache-2.0
#!/usr/bin/env python3
from __future__ import annotations
import argparse
from pathlib import Path

def load(path: Path) -> list[int]:
    vals: list[int] = []
    for lineno,line in enumerate(path.read_text().splitlines(),1):
        s=line.strip()
        if not s:
            continue
        parts=s.split()
        if len(parts)==1:
            vals.append(int(parts[0],0))
        elif len(parts)>=2:
            idx=int(parts[0],0)
            if idx != len(vals):
                raise ValueError(f"{path}:{lineno}: index {idx} expected {len(vals)}")
            vals.append(int(parts[1],0))
    return vals

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("--expected",type=Path,required=True)
    ap.add_argument("--vcs",type=Path)
    ap.add_argument("--fpga",type=Path)
    args=ap.parse_args()

    ref=load(args.expected)
    sources=[]
    if args.vcs: sources.append(("VCS",load(args.vcs)))
    if args.fpga: sources.append(("FPGA",load(args.fpga)))
    if not sources:
        raise SystemExit("specify --vcs and/or --fpga")

    bad=False
    for name,vals in sources:
        if len(vals)!=len(ref):
            print(f"FAIL {name}: length {len(vals)} != {len(ref)}")
            bad=True
            continue
        mism=[(i,a,b) for i,(a,b) in enumerate(zip(ref,vals)) if a!=b]
        if mism:
            print(f"FAIL {name}: mismatches={len(mism)}")
            for i,a,b in mism[:20]:
                print(f"  index={i} expected={a} actual={b}")
            bad=True
        else:
            print(f"PASS {name}: {len(vals)} outputs exactly match NumPy matmul")

    if args.vcs and args.fpga:
        v=load(args.vcs); f=load(args.fpga)
        if v==f:
            print(f"PASS VCS==FPGA: {len(v)} outputs")
        else:
            print("FAIL VCS!=FPGA")
            bad=True

    if bad:
        raise SystemExit(1)

if __name__=="__main__":
    main()
