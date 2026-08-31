#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
from pathlib import Path

import numpy as np

from pe_owned_case_common import (
    low_switch_lookup,
    pattern_tuple,
    trits5_to_pattern_id,
    write_activation_words,
    write_expected_mem,
)

ACT_WIDTH = 8
SUPPORTED_NUM_PE = (32, 64, 128)
SUPPORTED_MAPPING = ("block_cyclic", "contiguous")



def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def owner_lists(total_groups: int, num_pe: int, mapping: str) -> list[list[int]]:
    owned: list[list[int]] = [[] for _ in range(num_pe)]
    if mapping == "block_cyclic":
        for g in range(total_groups):
            owned[g % num_pe].append(g)
        return owned

    base = total_groups // num_pe
    rem = total_groups % num_pe
    for p in range(num_pe):
        count = base + (1 if p < rem else 0)
        start = p * base + min(p, rem)
        owned[p] = list(range(start, start + count))
    return owned


def main() -> None:
    ap = argparse.ArgumentParser(
        description=(
            "Prepare a PE-owned mapping-ablation case using the existing core RTL. "
            "The weight stream is remapped, while VCS expected outputs are written in "
            "the physical PE/local-row scan order. A permutation file is emitted so "
            "the physical output can be reconstructed into canonical output order."
        )
    )
    ap.add_argument("--project-root", type=Path, default=Path("."))
    ap.add_argument("--source-case", type=Path, required=True)
    ap.add_argument("--case-id", required=True)
    ap.add_argument("--num-pe", type=int, required=True)
    ap.add_argument("--mapping", choices=SUPPORTED_MAPPING, required=True)
    args = ap.parse_args()

    if args.num_pe not in SUPPORTED_NUM_PE:
        raise ValueError(f"--num-pe must be one of {SUPPORTED_NUM_PE}")

    project = args.project_root.resolve()
    source = args.source_case
    if not source.is_absolute():
        source = (project / source).resolve()
    if not source.exists():
        raise FileNotFoundError(source)


    meta_path = source / "case_metadata.json"
    meta = json.loads(meta_path.read_text()) if meta_path.exists() else {}
    weights = np.load(source / "weights_ternary.npy").astype(np.int8)
    activations = np.load(source / "activations.npy").astype(np.int8).reshape(-1)
    out_f, in_f = map(int, weights.shape)
    if activations.size != in_f:
        raise ValueError(f"activation length {activations.size} != in_features {in_f}")

    # Same-RTL mapping ablation.
    #
    # When OUT_FEATURES is not divisible by five, the final partial
    # five-trit group must remain in the physical slot at which the
    # unchanged RTL terminates its final scan.  For contiguous mapping
    # we therefore pin only that partial group to the original final
    # physical group slot.  All other groups remain contiguous.
    total_groups = (out_f + 4) // 5
    keys_per_word = 32
    blocks_per_local_group = args.num_pe // keys_per_word
    local_groups = (total_groups + args.num_pe - 1) // args.num_pe
    words_per_input = (total_groups + keys_per_word - 1) // keys_per_word
    total_words = in_f * words_per_input
    local_rows = local_groups * 5

    # Canonical five-output groups and keys.
    # The last group is zero-padded when OUT_FEATURES is not a multiple
    # of five.  Padding changes neither the mathematical output nor the
    # number of DDR words.
    padded_weights = np.zeros(
        (total_groups * 5, in_f), dtype=np.int8
    )
    padded_weights[:out_f, :] = weights

    by_input = padded_weights.T.reshape(
        in_f, total_groups, 5
    )
    pids = trits5_to_pattern_id(by_input)
    lut = low_switch_lookup()
    canonical_keys = lut[pids]  # [input, global_group]

    owned = owner_lists(
        total_groups, args.num_pe, args.mapping
    )

    partial_group_pinned = False

    if (out_f % 5) != 0 and args.mapping == "contiguous":
        last_g = total_groups - 1

        # Under the original block-cyclic physical scan, this is the
        # final physical group slot.  The unchanged RTL stops part-way
        # through this group.
        final_p = last_g % args.num_pe
        final_q = last_g // args.num_pe

        if final_q >= len(owned[final_p]):
            raise RuntimeError(
                "final physical group slot does not exist"
            )

        if owned[final_p][final_q] != last_g:
            src_p = None
            src_q = None

            for pp, groups in enumerate(owned):
                for qq, gg in enumerate(groups):
                    if gg == last_g:
                        src_p = pp
                        src_q = qq
                        break
                if src_p is not None:
                    break

            if src_p is None or src_q is None:
                raise RuntimeError(
                    "partial global group was not found"
                )

            # Swap exactly two groups.  This preserves the number of
            # groups per PE and therefore preserves the physical stream
            # structure expected by the RTL.
            owned[src_p][src_q], owned[final_p][final_q] = (
                owned[final_p][final_q],
                owned[src_p][src_q],
            )

            partial_group_pinned = True

    counts = np.asarray(
        [len(x) for x in owned], dtype=np.int64
    )
    if int(counts.max()) != local_groups:
        raise RuntimeError("local-group accounting mismatch")

    # Physical stream order is unchanged from the scalable PE-owned dispatcher:
    # word -> local_group, 32-PE block; lane -> PE within that block.
    words = np.zeros((in_f, words_per_input, keys_per_word), dtype=np.uint8)
    physical_key_group = np.full(
        (words_per_input, keys_per_word), -1, dtype=np.int64
    )

    for w in range(words_per_input):
        block = w % blocks_per_local_group
        q = w // blocks_per_local_group
        for lane in range(keys_per_word):
            p = block * keys_per_word + lane
            if p >= args.num_pe or q >= len(owned[p]):
                continue
            g = owned[p][q]
            words[:, w, lane] = canonical_keys[:, g]
            physical_key_group[w, lane] = g

    # Check that each global group occurs exactly once in the physical stream.
    mapped = sorted(int(x) for x in physical_key_group.reshape(-1) if x >= 0)
    if mapped != list(range(total_groups)):
        raise RuntimeError("physical stream is not a permutation of global groups")

    # Decode physical keys and compare against the intended global groups.
    inv = np.full(256, -1, dtype=np.int16)
    for pid, key in enumerate(lut):
        inv[int(key)] = pid
    patterns = np.asarray(
        [pattern_tuple(pid) for pid in range(243)], dtype=np.int8
    )
    for w in range(words_per_input):
        block = w % blocks_per_local_group
        q = w // blocks_per_local_group
        for lane in range(keys_per_word):
            g = int(physical_key_group[w, lane])
            if g < 0:
                if np.any(words[:, w, lane] != 0):
                    raise RuntimeError("inactive lane is not zero padded")
                continue
            decoded = patterns[inv[words[:, w, lane]]]
            if not np.array_equal(decoded, by_input[:, g, :]):
                raise RuntimeError(f"roundtrip mismatch w={w} lane={lane} g={g}")

    expected_canonical = weights.astype(np.int64) @ activations.astype(np.int64)
    acc_width = ACT_WIDTH + math.ceil(math.log2(in_f + 1))
    lo = -(1 << (acc_width - 1))
    hi = (1 << (acc_width - 1)) - 1
    if int(expected_canonical.min()) < lo or int(expected_canonical.max()) > hi:
        raise OverflowError("expected output exceeds accumulator width")

    # Current RTL final scan order is
    # local_group-major -> PE-major -> coordinate.
    #
    # RTL emits exactly OUT_FEATURES rows.  Therefore any padded
    # coordinates must occur only after those first OUT_FEATURES
    # physical rows.
    physical_scan: list[int] = []

    for q in range(local_groups):
        for pidx in range(args.num_pe):
            if q >= len(owned[pidx]):
                continue

            g = owned[pidx][q]

            for r in range(5):
                global_o = 5 * g + r
                physical_scan.append(
                    global_o if global_o < out_f else -1
                )

    if len(physical_scan) < out_f:
        raise RuntimeError(
            "physical scan shorter than OUT_FEATURES"
        )

    if any(x < 0 for x in physical_scan[:out_f]):
        raise RuntimeError(
            "padding appears before RTL final-scan termination"
        )

    if any(x >= 0 for x in physical_scan[out_f:]):
        raise RuntimeError(
            "valid output appears after RTL final-scan termination"
        )

    physical_to_global = [
        int(x) for x in physical_scan[:out_f]
    ]

    if len(physical_to_global) != out_f:
        raise RuntimeError(
            f"physical output count "
            f"{len(physical_to_global)} != OUT_FEATURES {out_f}"
        )

    if sorted(physical_to_global) != list(range(out_f)):
        raise RuntimeError(
            "output permutation is not bijective"
        )

    expected_physical = expected_canonical[np.asarray(physical_to_global)]

    # Static workload by owner PE.
    group_nnz = np.count_nonzero(by_input, axis=(0, 2)).astype(np.int64)
    pe_nnz = np.asarray(
        [sum(int(group_nnz[g]) for g in owned[p]) for p in range(args.num_pe)],
        dtype=np.int64,
    )
    mean_nnz = float(pe_nnz.mean())
    max_mean = float(pe_nnz.max() / mean_nnz) if mean_nnz else 1.0
    min_mean = float(pe_nnz.min() / mean_nnz) if mean_nnz else 1.0

    case_dir = project / "sim/prepared_cases" / args.case_id
    case_dir.mkdir(parents=True, exist_ok=True)

    with (case_dir / "weight_stream.mem").open("w", encoding="ascii") as f:
        for i in range(in_f):
            for w in range(words_per_input):
                b = bytes(int(x) for x in words[i, w])
                f.write(b[::-1].hex().upper() + "\n")

    # System Console/JTAG uses 32-bit Avalon-MM writes.
    # Eight consecutive 32-bit words reconstruct exactly one
    # 256-bit weight word in the FPGA host endpoint.
    with (case_dir / "weight_words32.txt").open("w", encoding="ascii") as f:
        for i in range(in_f):
            for w in range(words_per_input):
                b = bytes(int(x) for x in words[i, w])

                for lane32 in range(8):
                    chunk = b[4*lane32 : 4*(lane32+1)]
                    value = int.from_bytes(
                        chunk,
                        byteorder="little",
                        signed=False,
                    )
                    f.write(f"{value:08X}\n")

    write_activation_words(case_dir / "activation_words32.txt", activations)
    write_expected_mem(
        case_dir / "expected_outputs.mem", expected_physical, acc_width
    )
    write_expected_mem(
        case_dir / "expected_outputs_canonical.mem", expected_canonical, acc_width
    )
    (case_dir / "expected_outputs.txt").write_text(
        "".join(f"{i}\t{int(v)}\n" for i, v in enumerate(expected_physical)),
        encoding="utf-8",
    )
    (case_dir / "expected_outputs_canonical.txt").write_text(
        "".join(f"{i}\t{int(v)}\n" for i, v in enumerate(expected_canonical)),
        encoding="utf-8",
    )
    np.save(case_dir / "weights_ternary.npy", weights)
    np.save(case_dir / "activations.npy", activations)
    np.save(case_dir / "expected_outputs.npy", expected_physical)
    np.save(case_dir / "expected_outputs_canonical.npy", expected_canonical)

    with (case_dir / "output_physical_to_global.csv").open("w", newline="") as f:
        wr = csv.writer(f)
        wr.writerow(["physical_index", "global_output"])
        for i, g in enumerate(physical_to_global):
            wr.writerow([i, g])

    with (case_dir / "pe_ownership_workload.csv").open("w", newline="") as f:
        wr = csv.writer(f)
        wr.writerow(["pe", "owned_groups", "first_group", "last_group",
                     "nonzero_products", "ratio_to_mean"])
        for p in range(args.num_pe):
            gl = owned[p]
            wr.writerow([
                p, len(gl), gl[0] if gl else -1, gl[-1] if gl else -1,
                int(pe_nnz[p]),
                (float(pe_nnz[p]) / mean_nnz) if mean_nnz else 1.0,
            ])

    dense_products = out_f * in_f
    nonzero_products = int(np.count_nonzero(weights))
    dense_ideal = (dense_products + args.num_pe - 1) // args.num_pe
    global_ideal = (nonzero_products + args.num_pe - 1) // args.num_pe
    ownership_ideal = int(pe_nnz.max())

    source_words = int(meta.get("total_weight_words", 0) or 0)
    traffic_ratio = total_words / source_words if source_words else None
    weight_base = int(meta.get("weight_ddr_base", 0x00100000))

    new_meta = {
        **meta,
        "case_id": args.case_id,
        "architecture": "pe_owned_mapping_ablation_same_rtl",
        "source_case": str(source),
        "mapping": args.mapping,
        "same_rtl_partial_group_pinned": bool(partial_group_pinned),
        "num_pe": args.num_pe,
        "num_banks": args.num_pe,
        "physical_pending_banks": args.num_pe,
        "total_key_groups_per_input": total_groups,
        "local_groups_per_pe_max": local_groups,
        "local_rows_per_pe": local_rows,
        "keys_per_ddr_word": 32,
        "words_per_input": words_per_input,
        "total_weight_words": total_words,
        "stream_order": "input-major / local-group-major / 32-PE-block / lane",
        "output_order": "physical local-group-major / PE-major / coordinate",
        "output_reorder_file": "output_physical_to_global.csv",
        "dense_products": dense_products,
        "nonzero_products": nonzero_products,
        "dense_ideal_mac_cycles": dense_ideal,
        "global_ideal_zero_skip_cycles": global_ideal,
        "ownership_ideal_cycles": ownership_ideal,
        "pe_owner_nnz_min": int(pe_nnz.min()),
        "pe_owner_nnz_max": int(pe_nnz.max()),
        "pe_owner_nnz_mean": mean_nnz,
        "pe_owner_max_to_mean": max_mean,
        "pe_owner_min_to_mean": min_mean,
        "weight_traffic_ratio_vs_source": traffic_ratio,
        "packing_roundtrip_pass": True,
        "canonical_reorder_required": args.mapping != "block_cyclic",
    }
    (case_dir / "case_metadata.json").write_text(
        json.dumps(new_meta, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )

    cfg = f"""`ifndef ZEROSKIP_ACTIVE_CASE_SVH
`define ZEROSKIP_ACTIVE_CASE_SVH
`define ZS_NUM_PE             {args.num_pe}
`define ZS_NUM_BANKS          {args.num_pe}
`define ZS_IN_FEATURES        {in_f}
`define ZS_OUT_FEATURES       {out_f}
`define ZS_LUT_IMPL           0
`define ZS_ACC_WIDTH          {acc_width}
`define ZS_WORDS_PER_INPUT    {words_per_input}
`define ZS_TOTAL_WEIGHT_WORDS {total_words}
`define ZS_WEIGHT_DDR_BASE    30'h{weight_base:08X}
`endif
"""
    (case_dir / "zeroskip_active_case.svh").write_text(cfg, encoding="ascii")

    tensor = meta.get("tensor", meta.get("tensor_name", "unknown"))
    theoretical = (
        f"tensor={tensor}\n"
        f"shape=[{out_f}, {in_f}] PE={args.num_pe}\n"
        f"mapping={args.mapping}\n"
        f"dense_products={dense_products}\n"
        f"nonzero_products={nonzero_products}\n"
        f"dense_ideal_mac_cycles={dense_ideal}\n"
        f"global_ideal_zero_skip_cycles={global_ideal}\n"
        f"ownership_ideal_cycles={ownership_ideal}\n"
        f"pe_owner_max_to_mean={max_mean:.9f}\n"
        f"weight_requests={total_words}\n"
        f"weight_traffic_ratio_vs_source={traffic_ratio if traffic_ratio is not None else 'NA'}\n"
    )
    (case_dir / "theoretical_reference.txt").write_text(theoretical, encoding="utf-8")

    manifest = [
        "weight_stream.mem", "weight_words32.txt",
        "activation_words32.txt", "expected_outputs.mem",
        "expected_outputs_canonical.mem", "expected_outputs.txt",
        "expected_outputs_canonical.txt", "case_metadata.json",
        "zeroskip_active_case.svh", "pe_ownership_workload.csv",
        "output_physical_to_global.csv", "theoretical_reference.txt",
    ]
    (case_dir / "SHA256SUMS").write_text(
        "\n".join(f"{sha256(case_dir / f)}  {f}" for f in manifest) + "\n",
        encoding="ascii",
    )

    print(f"PASS: {case_dir}")
    print(f"mapping={args.mapping} shape=[{out_f},{in_f}] PE={args.num_pe}")
    print(f"groups={total_groups} words/input={words_per_input} total_words={total_words}")
    print(f"PE owner nnz min/mean/max={int(pe_nnz.min())}/{mean_nnz:.3f}/{int(pe_nnz.max())}")
    print(f"PE owner max/mean={max_mean:.6f} min/mean={min_mean:.6f}")
    print(f"ownership ideal cycles={ownership_ideal}")
    print("packing_roundtrip=PASS")
    print("output_permutation=PASS")
    if traffic_ratio is not None:
        print(f"weight_traffic_ratio_vs_source={traffic_ratio:.6f}")


if __name__ == "__main__":
    main()
