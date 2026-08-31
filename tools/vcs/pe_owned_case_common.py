#!/usr/bin/env python3
from __future__ import annotations
from pathlib import Path
import numpy as np

def trits5_to_pattern_id(values: np.ndarray) -> np.ndarray:
    values = np.asarray(values)
    if not np.all(np.isin(values, [-1, 0, 1])):
        raise ValueError("weights must be ternary {-1,0,+1}")
    trits = np.zeros_like(values, dtype=np.uint16)
    trits[values == -1] = 1
    trits[values == 1] = 2
    return np.sum(
        trits * np.asarray([1, 3, 9, 27, 81], dtype=np.uint16),
        axis=-1,
        dtype=np.uint16,
    )

def pattern_tuple(pid: int) -> tuple[int, ...]:
    if not 0 <= pid < 243:
        raise ValueError(pid)
    lut = (0, -1, 1)
    out = []
    v = pid
    for _ in range(5):
        out.append(lut[v % 3])
        v //= 3
    return tuple(out)

def low_switch_lookup() -> np.ndarray:
    ids = list(range(243))
    ids.sort(key=lambda p: (sum(x != 0 for x in pattern_tuple(p)), p))
    keys = sorted(range(256), key=lambda k: (k.bit_count(), k))[:243]
    lut = np.empty(243, dtype=np.uint8)
    for p, k in zip(ids, keys):
        lut[p] = k
    if int(lut[0]) != 0x00 or int(lut[242]) != 0xF5 or int(lut[121]) != 0xE6:
        raise RuntimeError("low-switch lookup invariant failed")
    return lut

def write_activation_words(path: Path, activations: np.ndarray) -> None:
    activations = np.asarray(activations, dtype=np.int8).reshape(-1)
    lines = []
    for base in range(0, len(activations), 4):
        chunk = bytes(
            int(np.uint8(activations[i])) if i < len(activations) else 0
            for i in range(base, base + 4)
        )
        lines.append(f"{int.from_bytes(chunk, 'little'):08X}")
    path.write_text("\n".join(lines) + "\n", encoding="ascii")

def write_expected_mem(path: Path, values: np.ndarray, width: int) -> None:
    values = np.asarray(values, dtype=np.int64).reshape(-1)
    digits = (width + 3) // 4
    mask = (1 << width) - 1
    path.write_text(
        "".join(f"{int(v) & mask:0{digits}X}\n" for v in values),
        encoding="ascii",
    )
