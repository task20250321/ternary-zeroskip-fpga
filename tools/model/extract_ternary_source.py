#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Dict, Optional, Tuple

import numpy as np

PROJECTIONS = (
    "q_proj", "k_proj", "v_proj", "o_proj",
    "gate_proj", "up_proj", "down_proj",
)

def projection_type(name: str) -> Optional[str]:
    for p in PROJECTIONS:
        if f".{p}." in name or name.endswith(f".{p}.weight"):
            return p
    return None

def load_config(model_root: Path) -> dict:
    path = model_root / "config.json"
    if not path.is_file():
        raise FileNotFoundError(f"config.json not found: {path}")
    return json.loads(path.read_text(encoding="utf-8"))

def logical_shape(name: str, config: dict) -> Optional[Tuple[int, int]]:
    h = int(config.get("hidden_size", 0) or 0)
    m = int(config.get("intermediate_size", 0) or 0)
    nh = int(config.get("num_attention_heads", 0) or 0)
    nkv = int(config.get("num_key_value_heads", 0) or 0)
    if h <= 0:
        return None
    hd = h // nh if nh else 0
    kv = nkv * hd if nkv and hd else 0
    return {
        "q_proj": (h, h),
        "k_proj": (kv, h),
        "v_proj": (kv, h),
        "o_proj": (h, h),
        "gate_proj": (m, h),
        "up_proj": (m, h),
        "down_proj": (h, m),
    }.get(projection_type(name))

def safe_open_module():
    try:
        from safetensors import safe_open
    except ImportError as exc:
        raise SystemExit(
            "BitNet packed2 mode requires safetensors. "
            "Install with: python3 -m pip install safetensors"
        ) from exc
    return safe_open

def discover(model_root: Path) -> Dict[str, Path]:
    safe_open = safe_open_module()
    for name in (
        "model.safetensors.index.json",
        "pytorch_model.safetensors.index.json",
    ):
        p = model_root / name
        if p.is_file():
            wm = json.loads(p.read_text(encoding="utf-8"))["weight_map"]
            return {str(k): model_root / str(v) for k, v in wm.items()}

    out: Dict[str, Path] = {}
    for shard in sorted(model_root.glob("*.safetensors")):
        with safe_open(shard, framework="np") as h:
            for k in h.keys():
                if k in out:
                    raise RuntimeError(f"duplicate tensor key: {k}")
                out[k] = shard
    if not out:
        raise FileNotFoundError(f"no safetensors found under {model_root}")
    return out

def list_tensors(model_root: Path) -> None:
    safe_open = safe_open_module()
    cfg = load_config(model_root)
    wm = discover(model_root)
    for name in sorted(wm):
        shp = logical_shape(name, cfg)
        if shp is None or not name.endswith(".weight"):
            continue
        with safe_open(wm[name], framework="np") as h:
            sl = h.get_slice(name)
            print(
                f"{name}\tlogical={shp}\t"
                f"stored={tuple(sl.get_shape())}\t"
                f"dtype={sl.get_dtype()}"
            )

def repack_codes(codes: np.ndarray, packed_rows: int) -> np.ndarray:
    rows, cols = codes.shape
    packed = np.zeros((packed_rows, cols), dtype=np.uint8)
    for slot in range(4):
        start = slot * packed_rows
        if start >= rows:
            break
        end = min(start + packed_rows, rows)
        packed[: end - start] |= (
            codes[start:end].astype(np.uint8)
            << np.uint8(2 * slot)
        )
    return packed

def load_bitnet_packed2(
    model_root: Path,
    tensor_name: str,
) -> tuple[np.ndarray, dict]:
    safe_open = safe_open_module()
    cfg = load_config(model_root)
    wm = discover(model_root)
    if tensor_name not in wm:
        raise KeyError(f"tensor not found: {tensor_name}")

    expected = logical_shape(tensor_name, cfg)
    if expected is None:
        raise ValueError(
            f"cannot infer logical [out,in] shape: {tensor_name}"
        )

    shard = wm[tensor_name]
    with safe_open(shard, framework="np") as h:
        packed = np.asarray(h.get_tensor(tensor_name))

    if packed.ndim != 2 or packed.dtype != np.uint8:
        raise TypeError(
            f"{tensor_name}: expected official uint8 packed2 tensor; "
            f"got shape={packed.shape}, dtype={packed.dtype}"
        )

    pr, pc = map(int, packed.shape)
    decoded_full = np.empty((pr * 4, pc), dtype=np.uint8)
    for slot in range(4):
        decoded_full[slot * pr : (slot + 1) * pr] = (
            packed >> np.uint8(2 * slot)
        ) & np.uint8(0x03)

    bad = int(np.count_nonzero(decoded_full == 3))
    if bad:
        raise ValueError(
            f"{tensor_name}: found {bad} invalid packed2 code(s) 0b11"
        )

    out_f, in_f = expected
    transposed = False

    if pc == in_f and out_f <= decoded_full.shape[0] and decoded_full.shape[0] - out_f < 4:
        codes = decoded_full[:out_f, :]
    elif pc == out_f and in_f <= decoded_full.shape[0] and decoded_full.shape[0] - in_f < 4:
        codes = decoded_full[:in_f, :].T
        transposed = True
    else:
        raise ValueError(
            f"stored packed shape {packed.shape} does not match "
            f"logical shape {expected}"
        )

    physical_codes = codes.T if transposed else codes
    if not np.array_equal(repack_codes(physical_codes, pr), packed):
        raise RuntimeError("official packed2 round-trip check failed")

    table = np.asarray([-1, 0, 1], dtype=np.int8)
    weights = np.ascontiguousarray(table[codes])

    return weights, {
        "source_type": "bitnet_official_packed2",
        "tensor": tensor_name,
        "tensor_name": tensor_name,
        "source_shard": shard.name,
        "logical_shape": [out_f, in_f],
        "packed_shape": list(map(int, packed.shape)),
        "transposed_after_unpack": transposed,
        "packed2_roundtrip_verified": True,
    }

def make_activations(n: int, mode: str, seed: int) -> np.ndarray:
    if mode == "ones":
        return np.ones(n, dtype=np.int8)
    if mode == "ramp":
        return ((np.arange(n, dtype=np.int32) % 31) - 15).astype(np.int8)
    if mode == "random":
        rng = np.random.default_rng(seed)
        return rng.integers(
            -128, 128, size=n, dtype=np.int16
        ).astype(np.int8)
    raise ValueError(mode)

def main() -> None:
    ap = argparse.ArgumentParser(
        description=(
            "Create canonical ternary [out,in] source data. "
            "No hardware-specific weight ordering is generated here."
        )
    )
    src = ap.add_mutually_exclusive_group()
    src.add_argument("--model-root", type=Path)
    src.add_argument("--weights-npy", type=Path)
    ap.add_argument("--tensor-name")
    ap.add_argument("--out-dir", type=Path)
    ap.add_argument(
        "--activation-mode",
        choices=("random", "ones", "ramp"),
        default="ramp",
    )
    ap.add_argument("--seed", type=int, default=20260831)
    ap.add_argument(
        "--weight-ddr-base",
        type=lambda x: int(x, 0),
        default=0x00100000,
    )
    ap.add_argument("--list", action="store_true")
    args = ap.parse_args()

    if args.list:
        if args.model_root is None:
            ap.error("--list requires --model-root")
        list_tensors(args.model_root)
        return

    if args.out_dir is None:
        ap.error("--out-dir is required")

    if args.model_root is not None:
        if not args.tensor_name:
            ap.error("--tensor-name is required with --model-root")
        weights, meta = load_bitnet_packed2(
            args.model_root, args.tensor_name
        )
    elif args.weights_npy is not None:
        weights = np.load(args.weights_npy)
        if weights.ndim != 2:
            raise ValueError(
                f"--weights-npy must be [out,in], got {weights.shape}"
            )
        weights = weights.astype(np.int8, copy=False)
        meta = {
            "source_type": "ternary_npy",
            "tensor": args.weights_npy.name,
            "tensor_name": args.weights_npy.name,
        }
    else:
        ap.error(
            "use --model-root + --tensor-name, or --weights-npy"
        )

    if not np.all(np.isin(weights, [-1, 0, 1])):
        vals = np.unique(weights)
        raise ValueError(
            "weights are not exactly ternary {-1,0,+1}; "
            f"unique sample={vals[:16].tolist()}"
        )

    out_f, in_f = map(int, weights.shape)
    activations = make_activations(
        in_f, args.activation_mode, args.seed
    )

    args.out_dir.mkdir(parents=True, exist_ok=True)
    np.save(
        args.out_dir / "weights_ternary.npy",
        np.ascontiguousarray(weights, dtype=np.int8),
    )
    np.save(args.out_dir / "activations.npy", activations)

    groups = (out_f + 4) // 5
    words_per_input = (groups + 31) // 32
    metadata = {
        **meta,
        "source_case_kind": "canonical_ternary_source",
        "out_features": out_f,
        "in_features": in_f,
        "activation_mode": args.activation_mode,
        "activation_seed": args.seed,
        "weight_ddr_base": args.weight_ddr_base,
        "total_weight_words": in_f * words_per_input,
        "canonical_groups_per_input": groups,
        "canonical_words_per_input": words_per_input,
        "nonzero_products": int(np.count_nonzero(weights)),
        "dense_products": int(weights.size),
    }
    (args.out_dir / "case_metadata.json").write_text(
        json.dumps(metadata, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )

    print(f"PASS: {args.out_dir.resolve()}")
    print(f"shape=[{out_f},{in_f}]")
    print(
        f"nnz={metadata['nonzero_products']}/"
        f"{metadata['dense_products']}"
    )
    print(
        "Canonical source only; do not use this directory "
        "directly as the RTL weight stream."
    )

if __name__ == "__main__":
    main()
