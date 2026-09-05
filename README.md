# Fine-Grained Zero Skipping for Ternary LLM Linear Layers with Packed Sparse Metadata

FPGA RTL and reproducibility utilities for the architecture described in:

**Yu Inoue, Takao Marukame, Tetsuya Asai, and Kota Ando,  
“Fine-Grained Zero Skipping for Ternary LLM Linear Layers with Packed Sparse Metadata.”**

This repository implements a fine-grained zero-skipping accelerator for ternary-weight linear layers. Five ternary weights in `{-1, 0, +1}` are stored as one fixed-length 8-bit key. At runtime, the key is decoded directly into the **signs, number, and coordinates of only the nonzero weights**, so zero-valued positions do not become product-issue events.

The final FPGA architecture statically assigns five-output groups to processing elements (PEs) and accumulates their contributions in PE-local partial-sum memories. This removes the inter-PE sparse-product router required by the earlier prototypes while preserving the same packed-key zero-skipping mechanism. A structurally matched dense PE-owned baseline is included for comparison.

## Key Idea

### Fixed-length five-trit packing

Five ternary weights have 243 possible patterns:

$$
3^5 = 243.
$$

An 8-bit key is therefore the minimum lossless fixed-length representation because

$$
2^7 < 3^5 \leq 2^8,
$$

which corresponds to

$$
\frac{8}{5} = 1.6 \text{ bits/weight}.
$$

The key is not expanded into five dense ternary symbols before computation. Instead, the on-chip LUT directly generates:

- the number of nonzero weights;
- the signs of the nonzero weights;
- the coordinates of the nonzero weights within the five-weight group.

For example:

```text
(0, -1, +1, 0, +1)
        |
        v
     8-bit key
        |
        v
  sparse metadata
        |
        +-- count = 3
        +-- signs = {-1, +1, +1}
        +-- coordinates = {1, 2, 4}
```

The expanded sparse metadata is transient and remains on chip.

### Final PE-local architecture

The final organization uses static five-output-group ownership.

```text
canonical ternary weight matrix
        |
        v
group every five output weights
        |
        v
offline PE assignment
        |
        v
8-bit-key packing and physical permutation
        |
        v
DDR4 / 256-bit packed-weight stream
        |
        v
PE-local key FIFO
        |
        v
5-trit sparse-metadata LUT
        |
        v
issue only nonzero products
        |
        v
PE-local partial-sum memory
        |
        v
physical output order
        |
        v
host-side canonical reorder
```

Each partial-sum location belongs to exactly one PE. Runtime inter-PE destination routing, multi-PE arbitration, and same-address merging are therefore unnecessary.

## Architecture Evolution

The study evaluates three hardware organizations that implement the same fine-grained zero-skipping mechanism.

### 1. Global-router architecture

The initial architecture assigns activations to PEs and dynamically routes asynchronously generated sparse products to shared banked partial-sum memories.

### 2. Clustered output-partition architecture

The PE array is divided into fixed-size clusters. Each cluster owns a distinct output range and contains a bounded local router and local partial-sum banks.

The evaluated K4/B8 configuration uses:

- 4 PEs per cluster;
- 8 partial-sum banks per cluster.

### 3. Final PE-local architecture

Five-output groups are assigned directly to individual PEs. Packed weights are permuted offline so that each PE receives only the keys for its assigned groups. Partial sums are accumulated in private PE-local memories.

The final organization removes inter-PE sparse-product routing entirely.

## Structurally Matched Dense Baseline

The dense baseline uses the same:

- static output assignment;
- PE count;
- activation distribution;
- packed-weight delivery;
- PE-local partial-sum memories.

Its functional difference is that all five coordinates represented by a key are processed, including zero-valued positions.

This baseline isolates the cost and benefit of fine-grained zero skipping from the independent benefit of PE-local accumulation.

## Paper Results

### Representative `2560 x 6912` linear layer

| PE count | Dense layer cycles | Zero-skip layer cycles | Speedup | Dense ALMs | Zero-skip ALMs | ALM overhead | Layer-energy reduction |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 32 | 555,613 | 343,571 | 1.617x | 9,345 | 10,551 | 12.9% | 38.1% |
| 64 | 279,094 | 174,700 | 1.598x | 16,618 | 19,079 | 14.8% | 37.1% |
| 128 | 140,836 | 113,189 | 1.244x | 29,333 | 35,597 | 21.4% | 19.2% |

Post-fit Fmax values:

| PE count | Dense Fmax | Zero-skip Fmax |
| ---: | ---: | ---: |
| 32 | 156.81 MHz | 146.16 MHz |
| 64 | 133.39 MHz | 135.03 MHz |
| 128 | 98.67 MHz | 107.16 MHz |

### PE128 model-wide evaluation

The PE128 RTL was evaluated on all 210 BitNet b1.58 2B4T linear-weight tensors.

| Metric | Result |
| --- | ---: |
| Evaluated tensors | 210 |
| RTL outputs matching software reference | 210 / 210 |
| Weight-stream bound | 205 / 210 (97.6%) |
| Compute bound | 5 / 210 (2.4%) |
| Mean lower-bound efficiency | 99.959% |
| Median lower-bound efficiency | 99.978% |
| Worst lower-bound efficiency | 99.748% |
| Mean PE utilization | 71.65% |
| Mean PE workload max/mean | 1.142 |
| Worst PE workload max/mean | 1.569 |

At PE128, the 256-bit/cycle packed-weight stream is the dominant performance limit for most tensors.

## Target Workload

The evaluation uses the ternary linear weights of **BitNet b1.58 2B4T**.

The model contains 30 transformer layers and seven evaluated linear projections per layer:

- `q_proj`
- `k_proj`
- `v_proj`
- `o_proj`
- `gate_proj`
- `up_proj`
- `down_proj`

This gives 210 linear-weight tensors.

The logical weight shapes are:

```text
[out_features, in_features]

[640,  2560]
[2560, 2560]
[6912, 2560]
[2560, 6912]
```

## FPGA Platform

| Item | Configuration |
| --- | --- |
| Board | Terasic DE25-Standard |
| FPGA | Altera Agilex 5 E-Series A5ED013BB32AE4SR1 |
| Quartus | Quartus Prime Pro 26.1 |
| Packed-weight interface | 256 bit/cycle |
| Evaluation clock | 50 MHz |
| DSP blocks for ternary products | 0 |

## Repository Layout

```text
configs/
    Fixed FPGA reference configurations.

constraints/
    Timing and board pin constraints.

ip/
    Quartus IP parameterization sources.

rtl/core/
    Final PE-local zero-skip accelerator.

rtl/baseline/
    Structurally matched dense PE-owned baseline.

rtl/lut/
    Five-trit sparse-metadata decode logic.

rtl/memory/
    Activation, weight-streaming, FIFO, and partial-sum support logic.

top/
    FPGA top-level modules.

scripts/quartus/
    Reproducible Quartus project creation and compilation.

sim/filelists/
    Synopsys VCS file lists.

sim/tb/
    VCS testbenches.

sim/reference_cases/
    Small self-contained regression cases.

sim/prepared_cases/
    Generated model-layer cases. Excluded from Git.

tools/model/
    BitNet and generic ternary-weight preparation.

tools/vcs/
    PE-owned mapping, packing, and output verification.

results/reference/
    Reference implementation results.
```

## Requirements

### Quartus FPGA build

- Quartus Prime Pro 26.1
- Agilex 5 device support
- Bash

### VCS simulation

- Synopsys VCS
- Bash

### Model preparation and result verification

- Python 3.8 or later
- NumPy
- `safetensors` for official BitNet packed checkpoints

## Quartus Build

All generated Quartus files are written under:

```text
build/quartus/
```

The directory is excluded from Git.

If the Quartus executables are not already in `PATH`, set:

```bash
export QUARTUS_ROOTDIR=/path/to/quartus
```

### Reference zero-skip build

```bash
./scripts/quartus/build_zeroskip.sh
```

The no-argument build uses the fixed PE128 reference configuration for:

```text
weight.shape = [2560, 6912]
```

Generated SOF:

```text
build/quartus/zeroskip/output_files/zeroskip_top.sof
```

### Reference dense build

```bash
./scripts/quartus/build_dense.sh
```

Generated SOF:

```text
build/quartus/dense/output_files/zeroskip_top.sof
```

## Build a User-Specified Linear-Layer Shape

The Quartus build can generate a design for a user-specified linear-layer shape without requiring model weights.

The shape convention is:

```text
weight.shape = [out_features, in_features]
```

Example:

```bash
./scripts/quartus/build_zeroskip.sh \
  --out-features 640 \
  --in-features 2560
```

The dense baseline uses the same interface:

```bash
./scripts/quartus/build_dense.sh \
  --out-features 640 \
  --in-features 2560
```

PE128 is the default. Supported PE counts are:

```text
32
64
128
```

Example:

```bash
./scripts/quartus/build_zeroskip.sh \
  --out-features 2560 \
  --in-features 2560 \
  --num-pe 64
```

For output dimension $N_{\mathrm{out}}$, the number of five-output groups is

$$
G = \left\lceil \frac{N_{\mathrm{out}}}{5} \right\rceil.
$$

With a 256-bit word containing 32 keys, the number of weight words per input is

$$
W = \left\lceil \frac{G}{32} \right\rceil.
$$

For input dimension $N_{\mathrm{in}}$, the total number of packed weight words is

$$
N_{\mathrm{weight}} = N_{\mathrm{in}} W.
$$

Representative values:

| Weight shape `[out,in]` | Groups/input | 256-bit words/input | Total weight words |
| --- | ---: | ---: | ---: |
| `[640,2560]` | 128 | 4 | 10,240 |
| `[2560,2560]` | 512 | 16 | 40,960 |
| `[6912,2560]` | 1,383 | 44 | 112,640 |
| `[2560,6912]` | 512 | 16 | 110,592 |

If `out_features` is not divisible by five, the final group is zero-padded.

## Build from a Prepared Case

A generated model-layer case contains:

```text
zeroskip_active_case.svh
```

The same compile-time configuration can be passed directly to Quartus:

```bash
./scripts/quartus/build_zeroskip.sh \
  --config sim/prepared_cases/<case-id>/zeroskip_active_case.svh
```

This allows a VCS-verified layer configuration to be synthesized without changing the RTL.

## VCS Functional Regression

A self-contained synthetic regression case is included:

```text
sim/reference_cases/corner128x128_contiguous_pe32
```

The test uses signed 8-bit activations and ternary weights with all-zero, all-`+1`, all-`-1`, and alternating patterns.

Run the final zero-skip RTL:

```bash
./sim/scripts/run_pe_owned_case_vcs.sh \
  sim/reference_cases/corner128x128_contiguous_pe32
```

A successful run reports:

```text
mismatches=0
```

### Canonical output verification

PE-owned execution emits results in physical ownership order. Reorder them to canonical logical-output order and compare against the software reference:

```bash
python3 \
  tools/vcs/verify_pe_owned_mapping_output.py \
  sim/reference_cases/corner128x128_contiguous_pe32
```

Expected result:

```text
PASS: canonical reorder matches software reference
```

### Dense baseline regression

```bash
./sim/scripts/run_dense_owned_case_vcs.sh \
  sim/reference_cases/corner128x128_contiguous_pe32
```

A successful simulation reports `PASS dense-owned`.

## Prepare an Official BitNet Layer

The model-preparation flow separates canonical ternary-weight extraction from the hardware-specific PE-owned layout.

List supported tensors in an official packed BitNet checkpoint:

```bash
python3 \
  tools/model/extract_ternary_source.py \
  --model-root /path/to/bitnet-b1.58-2B-4T \
  --list
```

Example for layer 0 `k_proj`:

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

Generated case:

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

Run VCS:

```bash
./sim/scripts/run_pe_owned_case_vcs.sh \
  sim/prepared_cases/bitnet_l00_k_proj_pe128
```

Verify canonical output order:

```bash
python3 \
  tools/vcs/verify_pe_owned_mapping_output.py \
  sim/prepared_cases/bitnet_l00_k_proj_pe128
```

The BitNet packed-weight path performs a packed2 round-trip check before generating the hardware case.

Model checkpoints are not included in this repository.

## Use an Arbitrary Ternary Weight Matrix

A NumPy matrix can be used directly if it satisfies:

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

Non-ternary matrices are rejected rather than silently quantized.

## Output-Group Mapping

Let

$$
G = \left\lceil \frac{N_{\mathrm{out}}}{5} \right\rceil
$$

be the number of five-output groups and $P$ the PE count.

The default mapping evaluated in the paper is block-cyclic:

$$
p = g \bmod P,
$$

where $g$ is the global five-output-group index.

For local group index $q$,

$$
g = Pq + p.
$$

For intra-group coordinate $r \in \{0,1,2,3,4\}$, the global output is

$$
o = 5(Pq+p)+r.
$$

The hardware datapath does not depend on the logical output mapping. Different mappings require only a different offline packed-weight permutation and inverse output permutation.

The preparation tools support:

```text
block_cyclic
contiguous
```

The inverse mapping is stored in:

```text
output_physical_to_global.csv
```

Across the 210 evaluated BitNet tensors, block-cyclic assignment provides better average PE workload balance than contiguous assignment.

## Performance Limits

For the implemented 256-bit/cycle packed-weight interface, one word carries 32 five-trit keys and therefore represents 160 ternary positions.

For zero ratio $z$, the approximate rate of useful nonzero work supplied by a $B$-bit/cycle packed stream is

$$
R_{\mathrm{weight,nz}}
\approx
\frac{5B}{8}(1-z).
$$

The PE array can issue at most $P$ nonzero products per cycle. At PE128, useful nonzero-work delivery from the 256-bit/cycle interface becomes the dominant limitation for most BitNet tensors.

For exact analysis under the implemented interface:

$$
C_{\mathrm{weight}} =
N_{\mathrm{in}}
\left\lceil
\frac{\left\lceil N_{\mathrm{out}}/5 \right\rceil}{32}
\right\rceil,
$$

$$
C_{\mathrm{compute}} =
\max_p N_{\mathrm{nz},p},
$$

and

$$
C_{\mathrm{LB}} =
\max(C_{\mathrm{weight}}, C_{\mathrm{compute}}).
$$

## FPGA Implementation and Validation

RTL was synthesized, placed, and routed with Quartus Prime Pro 26.1 for the Agilex 5 E-Series A5ED013BB32AE4SR1 device.

The final bitstream was programmed onto the target FPGA board and on-board accelerator operation was confirmed in the associated study.

Unless otherwise stated, cycle and energy evaluations use a 50 MHz operating clock. Fmax values are taken from timing analysis.

Logic resources are reported as Adaptive Logic Modules (ALMs), memories as M20K blocks, and ternary products require no DSP multiplier blocks.

## Power and Energy

Post-fit activity was analyzed with Quartus Power Analyzer.

For power $P_{\mathrm{pow}}$, clock frequency $f$, and measured layer cycles $C_{\mathrm{layer}}$,

$$
E_{\mathrm{layer}} =
P_{\mathrm{pow}}
\frac{C_{\mathrm{layer}}}{f}.
$$

Quartus reported `Power Estimation Confidence = Low` because simulation-derived activity did not cover the complete fitted design. Absolute power values are therefore post-fit estimates.

Matched dense and zero-skip energy comparisons use the same device, workload, clock frequency, and power-analysis procedure.

## Generated Files and Git Policy

The following generated or external artifacts are excluded from Git:

- Quartus build databases;
- generated Quartus IP products;
- SOF files;
- VCS executables and build directories;
- waveform files;
- generated model-layer cases;
- downloaded model checkpoints;
- local power-analysis artifacts.

The repository retains source RTL, parameterization files, build scripts, testbenches, small regression data, model-preparation utilities, and reference result summaries.

## Data Availability

The primary evaluation data consist of derived cycle reports, FPGA implementation reports, power reports, and summary tables generated from the publicly available BitNet b1.58 2B4T model weights.

## Citation

```bibtex
@article{inoue2026ternaryzeroskip,
  author = {Yu Inoue and Takao Marukame and Tetsuya Asai and Kota Ando},
  title  = {Fine-Grained Zero Skipping for Ternary LLM Linear Layers with Packed Sparse Metadata},
  year   = {2026}
}
```

## License

Licensed under the [Apache License 2.0](LICENSE).
