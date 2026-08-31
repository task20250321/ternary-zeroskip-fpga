# PE-Owned Ternary Zero-Skip FPGA Accelerator

FPGA implementation and reproducibility utilities for a PE-owned zero-skipping accelerator targeting ternary-weight linear layers.

The design processes weights in \(\{-1,0,+1\}\), stores five ternary weights in one 8-bit key, decodes the key on chip, and skips zero-valued products. The final architecture assigns output groups statically to processing elements (PEs), eliminating the global partial-product router used in earlier prototypes.

A structurally matched dense PE-owned baseline is included for comparison.

---

## 1. Repository Status

This repository is currently being prepared for public release.

The following flows are included:

- clean Quartus reconstruction of the final zero-skip design;
- clean Quartus reconstruction of the matched dense baseline;
- configurable FPGA builds for user-specified linear-layer shapes;
- Synopsys VCS functional simulation;
- a self-contained synthetic regression case;
- preparation of PE-owned cases from official BitNet packed weights;
- preparation of PE-owned cases from arbitrary ternary NumPy weight matrices;
- physical-to-canonical output verification.

The FPGA board execution flow is **not yet part of the validated release flow**. Programming the generated SOF, loading weights/activations through JTAG/Avalon-MM, starting the accelerator, and reading results back from hardware will be documented after board-level validation.

A final software license has also not yet been added.

---

## 2. Architecture Overview

The target operation is a ternary-weight linear layer

\[
y_o = \sum_{i=0}^{N_{\mathrm{in}}-1} W_{o,i} x_i,
\qquad
W_{o,i} \in \{-1,0,+1\}.
\]

### 2.1 Five-trit packing

Five ternary weights are encoded into one fixed-length 8-bit key:

```text
5 ternary weights
        |
        v
   8-bit key
        |
        v
 on-chip LUT decode
        |
        +--> non-zero count
        +--> signs
        +--> coordinates
```

There are only

\[
3^5 = 243
\]

possible five-trit patterns, so all patterns fit in an 8-bit key space.

The accelerator does not fully reconstruct the original five weights before computation. Instead, the LUT directly produces the information needed for zero-skipping: the number of non-zero weights, their signs, and their local coordinates.

### 2.2 PE-owned output groups

The final architecture removes the global partial-product router.

Each PE owns a set of five-output groups and accumulates only into its private partial-sum storage.

```text
packed weight stream
        |
        v
+-------------------------------+
|       PE-owned accelerator    |
|                               |
| PE0  -> decode -> private psum|
| PE1  -> decode -> private psum|
| ...                           |
| PEn  -> decode -> private psum|
+-------------------------------+
        |
        v
physical output order
        |
        v
offline / host-side permutation
        |
        v
canonical output order
```

The compute datapath is mapping-agnostic. Logical ownership is encoded by the offline arrangement of packed weights. This allows different static mappings to use the same RTL.

The reference flow uses PE-owned mapping and supports both `block_cyclic` and `contiguous` case generation.

---

## 3. Included FPGA Designs

### 3.1 Proposed zero-skip design

Main properties:

- ternary weights in \(\{-1,0,+1\}\);
- five-trit / 8-bit fixed-length packing;
- LUT decode into sign/count/coordinate metadata;
- variable-length emission of only non-zero products;
- static PE ownership of output groups;
- private partial-sum accumulation;
- no global partial-product router;
- no DSP blocks required for ternary multiplication.

### 3.2 Structurally matched dense baseline

The dense baseline preserves the PE-owned organization and private accumulation structure, but does not skip zero-valued positions.

It is intended to isolate the cost and benefit of the zero-skipping mechanism while keeping the high-level datapath structure matched.

---

## 4. Reference FPGA Platform

The reference FPGA implementation uses:

| Item | Reference |
| --- | --- |
| Board | Terasic DE25-Standard |
| FPGA | Altera Agilex 5 A5ED013BB32AE4SR1 |
| Quartus | Quartus Prime Pro 26.1 |
| Reference PE count | 128 |
| Reference weight shape | `[2560, 6912]` |
| Shape convention | `[out_features, in_features]` |
| Packed weight interface | 256 bit |
| Reference top-level clock | 50 MHz |
| DSP usage | 0 |

The reference shape corresponds to a representative BitNet `down_proj` linear layer.

Model weights are **not embedded into the FPGA bitstream** for the implementation-resource evaluation.

---

## 5. Reference FPGA Results

The checked-in reference results correspond to the PE128 `[2560,6912]` configuration.

| Metric | Zero-skip PE-owned | Dense PE-owned |
| --- | ---: | ---: |
| ALMs | 35,597 | 29,333 |
| ALM utilization | 76.1% | 62.7% |
| Registers | 32,250 | 30,762 |
| Block-memory bits | 217,408 | 217,408 |
| RAM blocks | 159 / 358 | 159 / 358 |
| DSP blocks | 0 | 0 |
| Fmax | 107.16 MHz | 98.67 MHz |
| Setup slack | +10.668 ns | +9.865 ns |

Machine-readable reference values are stored under:

```text
results/reference/
```

---

## 6. Repository Layout

```text
configs/
    Fixed reference FPGA configuration.

constraints/
    Timing and DE25 board constraints.

ip/
    Quartus IP parameterization sources.
    Generated IP products are intentionally not tracked.

rtl/core/
    Final PE-owned zero-skip accelerator.

rtl/baseline/
    Structurally matched dense PE-owned baseline.

rtl/lut/
    Five-trit decode logic.

rtl/memory/
    FIFOs, activation storage, weight streaming, and support memories.

top/
    FPGA top-level wrappers.

scripts/quartus/
    Clean Quartus project-generation and compilation scripts.

sim/filelists/
    VCS file lists.

sim/tb/
    VCS testbenches.

sim/reference_cases/
    Small synthetic regression case tracked by Git.

sim/prepared_cases/
    Generated model/test cases. Not tracked by Git.

tools/model/
    BitNet / generic ternary model preparation.

tools/vcs/
    PE-owned case generation and output verification.

results/reference/
    Reference FPGA implementation results.
```

---

## 7. Requirements

### FPGA synthesis

Required:

- Quartus Prime Pro 26.1;
- Agilex 5 device support;
- Bash.

Python and Synopsys VCS are not required if the goal is only to synthesize a user-specified layer shape.

### Functional simulation

Required:

- Synopsys VCS;
- Bash.

For host-side result verification and model-case generation:

- Python 3.8 or later;
- NumPy.

For official BitNet packed checkpoints:

- `safetensors`.

---

# 8. Quartus FPGA Build

All Quartus-generated products are written under:

```text
build/quartus/
```

The build tree is disposable and excluded from Git.

Set the Quartus installation path if the executables are not already in `PATH`:

```bash
export QUARTUS_ROOTDIR=/path/to/quartus
```

For the reference development environment this pointed to Quartus Prime Pro 26.1, but no absolute installation path is hard-coded in the repository.

---

## 8.1 Reproduce the reference zero-skip build

```bash
./scripts/quartus/build_zeroskip.sh
```

With no shape or configuration argument, the script uses the fixed PE128 reference configuration:

```text
weight.shape = [2560, 6912]
PE = 128
```

The generated SOF is:

```text
build/quartus/zeroskip/output_files/zeroskip_top.sof
```

---

## 8.2 Reproduce the reference dense build

```bash
./scripts/quartus/build_dense.sh
```

The generated SOF is:

```text
build/quartus/dense/output_files/zeroskip_top.sof
```

---

# 9. Build a User-Specified Linear-Layer Shape

The FPGA design can be compiled for a different linear-layer shape without requiring model weights or Python.

The dimension convention follows the usual PyTorch linear-weight layout:

```text
weight.shape = [out_features, in_features]
```

For example, a `[640,2560]` layer can be synthesized as:

```bash
./scripts/quartus/build_zeroskip.sh \
  --out-features 640 \
  --in-features 2560
```

The matched dense design uses the same interface:

```bash
./scripts/quartus/build_dense.sh \
  --out-features 640 \
  --in-features 2560
```

PE128 is the default. Supported build-time PE counts are:

```text
32
64
128
```

For example:

```bash
./scripts/quartus/build_zeroskip.sh \
  --out-features 2560 \
  --in-features 2560 \
  --num-pe 64
```

The build script derives:

\[
G =
\left\lceil
\frac{N_{\mathrm{out}}}{5}
\right\rceil
\]

five-trit groups per input,

\[
W_{\mathrm{input}}
=
\left\lceil
\frac{G}{32}
\right\rceil
\]

256-bit weight words per input, and

\[
W_{\mathrm{total}}
=
N_{\mathrm{in}} W_{\mathrm{input}}
\]

total packed weight words.

The accumulator width is also derived from the selected input dimension.

Examples for BitNet linear-layer shapes:

| Weight shape `[out,in]` | Groups/input | 256-bit words/input | Total weight words |
| --- | ---: | ---: | ---: |
| `[640,2560]` | 128 | 4 | 10,240 |
| `[2560,2560]` | 512 | 16 | 40,960 |
| `[6912,2560]` | 1,383 | 44 | 112,640 |
| `[2560,6912]` | 512 | 16 | 110,592 |

When `out_features` is not divisible by five, the final five-trit group is zero-padded.

---

# 10. Build from an Existing Case Configuration

A case generated by the model/VCS preparation flow contains:

```text
zeroskip_active_case.svh
```

The exact same compile-time configuration can be passed to Quartus:

```bash
./scripts/quartus/build_zeroskip.sh \
  --config sim/prepared_cases/<case-id>/zeroskip_active_case.svh
```

This is useful when the same layer configuration has already been verified in VCS.

---

# 11. VCS Functional Simulation

A small synthetic reference case is tracked in Git so that the final PE-owned RTL can be checked without downloading BitNet.

Reference case:

```text
sim/reference_cases/corner128x128_contiguous_pe32
```

The case uses:

- 128 valid input elements;
- 128 valid output elements with padded physical output slots;
- input values `0,1,...,127`;
- ternary weights in \(\{-1,0,+1\}\);
- simple all-zero, all-+1, all--1, and alternating patterns;
- contiguous offline ownership.

Run the proposed zero-skip design:

```bash
./sim/scripts/run_pe_owned_case_vcs.sh \
  sim/reference_cases/corner128x128_contiguous_pe32
```

A successful run reports:

```text
mismatches=0
```

The testbench also dumps the physical output-bank contents in decimal form for manual inspection.

---

## 11.1 Canonical output verification

PE-owned execution emits results in physical ownership order.

Reorder the output to canonical logical-output order and compare it with the software reference:

```bash
python3 \
  tools/vcs/verify_pe_owned_mapping_output.py \
  sim/reference_cases/corner128x128_contiguous_pe32
```

Expected:

```text
PASS: canonical reorder matches software reference
```

---

## 11.2 Dense baseline simulation

```bash
./sim/scripts/run_dense_owned_case_vcs.sh \
  sim/reference_cases/corner128x128_contiguous_pe32
```

A successful simulation prints a `PASS dense-owned` message after checking the generated outputs.

---

# 12. Prepare an Official BitNet Layer

The model-preparation flow separates:

1. canonical ternary-weight extraction; and
2. hardware-specific PE-owned weight permutation.

This prevents model decoding logic from being coupled to the final hardware mapping.

List supported linear tensors in an official packed BitNet checkpoint:

```bash
python3 \
  tools/model/extract_ternary_source.py \
  --model-root /path/to/bitnet-b1.58-2B-4T \
  --list
```

Example: prepare layer 0 `k_proj` for PE128:

```bash
python3 \
  tools/model/prepare_ternary_pe_owned_case.py \
  --project-root . \
  --model-root /path/to/bitnet-b1.58-2B-4T \
  --tensor-name model.layers.0.self_attn.k_proj.weight \
  --case-id bitnet_l00_k_proj_pe128 \
  --num-pe 128 \
  --mapping block_cyclic \
  --activation-mode ramp
```

The generated hardware case is placed under:

```text
sim/prepared_cases/bitnet_l00_k_proj_pe128/
```

Typical generated files include:

```text
weights_ternary.npy
activations.npy
weight_stream.mem
activation_words32.txt
expected_outputs.txt
expected_outputs_canonical.txt
output_physical_to_global.csv
zeroskip_active_case.svh
case_metadata.json
```

Run it with:

```bash
./sim/scripts/run_pe_owned_case_vcs.sh \
  sim/prepared_cases/bitnet_l00_k_proj_pe128
```

Then verify canonical output order:

```bash
python3 \
  tools/vcs/verify_pe_owned_mapping_output.py \
  sim/prepared_cases/bitnet_l00_k_proj_pe128
```

The official packed2 decoding path performs a packed-weight round-trip check before generating the hardware case.

Model checkpoints are not included in this repository.

---

# 13. Use an Arbitrary Ternary Weight Matrix

A user-provided NumPy matrix can also be used.

Requirements:

```text
shape  = [out_features, in_features]
values = {-1, 0, +1}
```

Example:

```bash
python3 \
  tools/model/prepare_ternary_pe_owned_case.py \
  --project-root . \
  --weights-npy /path/to/weights.npy \
  --case-id custom_ternary_pe128 \
  --num-pe 128 \
  --mapping block_cyclic \
  --activation-mode ramp
```

The public preparation flow intentionally rejects non-ternary matrices rather than silently quantizing floating-point weights.

---

# 14. Weight Mapping

The final PE-owned compute core does not need to know the logical output mapping.

The mapping is encoded offline by permuting packed keys into PE lanes.

Supported preparation modes include:

```text
block_cyclic
contiguous
```

The generated file

```text
output_physical_to_global.csv
```

records the inverse mapping needed to recover canonical logical-output order.

The same RTL can therefore execute differently mapped cases without changing the compute datapath.

For the reference BitNet PE128 evaluation, block-cyclic ownership is the default/recommended mapping because it avoids severe load imbalance in some layers.

---

# 15. Generated Files and Git Policy

The following are intentionally excluded from Git:

- Quartus build databases;
- Quartus generated IP products;
- SOF files;
- VCS executables and build directories;
- waveform files;
- generated model cases;
- downloaded model checkpoints;
- local power-analysis artifacts.

The repository retains only the source files, parameterization files, small regression data, and reference result summaries required for reproduction.

---

# 16. FPGA Board Execution

The repository contains the RTL infrastructure required for DDR4/JTAG integration, but the complete end-to-end board execution procedure is not yet part of the validated release flow.

Planned validated flow:

```text
generate model case
      |
      v
build case-specific SOF
      |
      v
program FPGA
      |
      v
load packed weights to DDR4
      |
      v
load activations
      |
      v
start accelerator
      |
      v
read physical outputs
      |
      v
canonical reorder
      |
      v
compare with software reference
```

This section will be updated after FPGA board validation.

---

# 17. Power Evaluation

Power-analysis artifacts used during development are not part of the minimal functional reproduction flow.

Reported FPGA power values were obtained with Quartus Power Analyzer. Power-estimation confidence and activity-source conditions must be considered when interpreting absolute values.

The public release will document the retained power-reproduction procedure separately if those artifacts are included.

---

# 18. Reproducibility Scope

The repository is intended to distinguish three levels of reproduction:

### Level 1 — Functional RTL regression

Does not require BitNet.

```text
synthetic case -> VCS -> bit-exact output verification
```

### Level 2 — Model-layer functional reproduction

Requires an external BitNet checkpoint or user-provided ternary weights.

```text
model weight -> packing/mapping -> VCS -> software comparison
```

### Level 3 — FPGA implementation reproduction

Does not require model weights for resource/timing reproduction.

```text
shape/config -> Quartus -> post-fit resources/Fmax -> SOF
```

Board-level execution will be added after validation.

---

# 19. Citation

Citation information will be added after the associated paper is finalized.

---

# 20. License

A software license has not yet been finalized.

Until a license is added, do not assume that redistribution, modification, or reuse is permitted solely because the source repository is accessible.

The license will be selected after the applicable university/laboratory intellectual-property requirements are confirmed.
