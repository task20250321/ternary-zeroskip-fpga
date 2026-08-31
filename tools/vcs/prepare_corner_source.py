#!/usr/bin/env python3

from pathlib import Path
import json
import numpy as np


ROOT = Path("sim/prepared_cases")

SOURCE_ID = "corner128_source_for_contiguous"
SOURCE = ROOT / SOURCE_ID

VALID_IN = 128
VALID_OUT = 128

# Deliberate TB-only padding.
#
# 320 outputs = 64 five-trit groups.
# PE32 contiguous ownership then gives exactly two adjacent
# groups to every PE:
#
#   PE0  -> G0,G1
#   PE1  -> G2,G3
#   ...
#   PE31 -> G62,G63
#
PHYSICAL_OUT = 320

SOURCE.mkdir(parents=True, exist_ok=True)

# ------------------------------------------------------------
# Activation:
#
# x = [0, 1, 2, ... 127]
# ------------------------------------------------------------
x = np.arange(VALID_IN, dtype=np.int8)

# ------------------------------------------------------------
# Ternary weights.
#
# Only outputs 0..127 are valid.
# Outputs 128..319 are zero-padding.
# ------------------------------------------------------------
w = np.zeros(
    (PHYSICAL_OUT, VALID_IN),
    dtype=np.int8,
)

for o in range(VALID_OUT):
    mode = o % 9

    if mode == 0:
        # all zero
        w[o, :] = 0

    elif mode == 1:
        # all +1
        w[o, :] = 1

    elif mode == 2:
        # all -1
        w[o, :] = -1

    elif mode == 3:
        # 0, +1, 0, +1, ...
        w[o, 0::2] = 0
        w[o, 1::2] = 1

    elif mode == 4:
        # +1, 0, +1, 0, ...
        w[o, 0::2] = 1
        w[o, 1::2] = 0

    elif mode == 5:
        # 0, -1, 0, -1, ...
        w[o, 0::2] = 0
        w[o, 1::2] = -1

    elif mode == 6:
        # -1, 0, -1, 0, ...
        w[o, 0::2] = -1
        w[o, 1::2] = 0

    elif mode == 7:
        # +1, -1, +1, -1, ...
        w[o, 0::2] = 1
        w[o, 1::2] = -1

    elif mode == 8:
        # -1, +1, -1, +1, ...
        w[o, 0::2] = -1
        w[o, 1::2] = 1


# ------------------------------------------------------------
# Software matrix multiplication.
# ------------------------------------------------------------
expected = (
    w.astype(np.int64)
    @ x.astype(np.int64)
)

closed_form = np.asarray(
    [
        0,
        8128,
        -8128,
        4096,
        4032,
        -4096,
        -4032,
        -64,
        64,
    ],
    dtype=np.int64,
)

# Independent human-readable closed-form check.
for o in range(VALID_OUT):
    e = int(closed_form[o % len(closed_form)])
    a = int(expected[o])

    if a != e:
        raise RuntimeError(
            f"closed-form mismatch output={o}: "
            f"matmul={a} expected={e}"
        )

# Padded outputs must remain exactly zero.
if np.any(expected[VALID_OUT:] != 0):
    raise RuntimeError(
        "padded outputs are not zero"
    )

np.save(
    SOURCE / "weights_ternary.npy",
    w,
)

np.save(
    SOURCE / "activations.npy",
    x,
)

meta = {
    "case_id": SOURCE_ID,
    "tensor": "synthetic_corner_128x128",
    "tensor_name": "synthetic_corner_128x128",
    "test_kind": "arithmetic_correctness",
    "valid_in_features": VALID_IN,
    "valid_out_features": VALID_OUT,
    "physical_out_features": PHYSICAL_OUT,
    "padding_outputs": PHYSICAL_OUT - VALID_OUT,
    "activation_pattern": "0_to_127",
    "requested_mapping": "contiguous",
    "weight_pattern_period": 9,
    "weight_ddr_base": 0x00100000,
}

(
    SOURCE / "case_metadata.json"
).write_text(
    json.dumps(
        meta,
        indent=2,
        ensure_ascii=False,
    )
    + "\n",
    encoding="utf-8",
)

# Human-readable canonical expectation for valid outputs only.
with (
    SOURCE / "expected_valid_outputs_human.tsv"
).open("w") as f:
    f.write(
        "output\tmode\texpected\n"
    )

    names = [
        "all_zero",
        "all_plus_one",
        "all_minus_one",
        "zero_plus_alternating",
        "plus_zero_alternating",
        "zero_minus_alternating",
        "minus_zero_alternating",
        "plus_minus_alternating",
        "minus_plus_alternating",
    ]

    for o in range(VALID_OUT):
        mode = o % 9
        f.write(
            f"{o}\t"
            f"{names[mode]}\t"
            f"{int(expected[o])}\n"
        )

print("PASS: synthetic corner source generated")
print(f"source={SOURCE}")
print(f"valid_shape=[{VALID_OUT},{VALID_IN}]")
print(f"physical_shape=[{PHYSICAL_OUT},{VALID_IN}]")
print("activation=0,1,2,...,127")
print("valid expected pattern:")
print(
    "  0, 8128, -8128, 4096, 4032, "
    "-4096, -4032, -64, 64, ..."
)
