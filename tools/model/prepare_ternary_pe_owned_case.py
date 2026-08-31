#!/usr/bin/env python3
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

def run(cmd: list[str]) -> None:
    print("+", " ".join(cmd))
    subprocess.run(cmd, check=True)

def main() -> None:
    ap = argparse.ArgumentParser(
        description=(
            "Prepare a final PE-owned ternary case from an official "
            "BitNet packed2 tensor or canonical ternary .npy matrix."
        )
    )
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--model-root", type=Path)
    src.add_argument("--weights-npy", type=Path)
    ap.add_argument("--tensor-name")
    ap.add_argument("--case-id", required=True)
    ap.add_argument("--num-pe", type=int, choices=(32, 64, 128), default=128)
    ap.add_argument(
        "--mapping",
        choices=("block_cyclic", "contiguous"),
        default="contiguous",
    )
    ap.add_argument(
        "--activation-mode",
        choices=("random", "ones", "ramp"),
        default="ramp",
    )
    ap.add_argument("--seed", type=int, default=20260831)
    ap.add_argument("--project-root", type=Path, default=Path("."))
    args = ap.parse_args()

    project = args.project_root.resolve()
    extractor = project / "tools/model/extract_ternary_source.py"
    mapper = project / "tools/vcs/prepare_pe_owned_mapping_ablation.py"
    source_dir = project / "build/model_sources" / f"{args.case_id}_canonical"
    source_dir.mkdir(parents=True, exist_ok=True)

    extract_cmd = [
        sys.executable,
        str(extractor),
        "--out-dir",
        str(source_dir),
        "--activation-mode",
        args.activation_mode,
        "--seed",
        str(args.seed),
    ]

    if args.model_root is not None:
        if not args.tensor_name:
            ap.error("--tensor-name is required with --model-root")
        extract_cmd += [
            "--model-root",
            str(args.model_root),
            "--tensor-name",
            args.tensor_name,
        ]
    else:
        extract_cmd += [
            "--weights-npy",
            str(args.weights_npy),
        ]

    run(extract_cmd)

    run([
        sys.executable,
        str(mapper),
        "--project-root",
        str(project),
        "--source-case",
        str(source_dir),
        "--case-id",
        args.case_id,
        "--num-pe",
        str(args.num_pe),
        "--mapping",
        args.mapping,
    ])

    final_case = project / "sim/prepared_cases" / args.case_id
    print()
    print("PASS: final PE-owned case")
    print(final_case)
    print()
    print("VCS:")
    print(
        "./sim/scripts/run_pe_owned_case_vcs.sh "
        f"sim/prepared_cases/{args.case_id}"
    )

if __name__ == "__main__":
    main()
