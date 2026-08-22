# PE-Owned Ternary Zero-Skip FPGA Accelerator

This repository contains the FPGA implementation of a PE-owned
zero-skipping accelerator for ternary-weight linear layers and its
structurally matched dense baseline.

The reference implementation targets an Altera Agilex 5 FPGA and was
evaluated using Quartus Prime Pro 26.1.

## Designs

Two PE128 FPGA designs are provided.

### Proposed Zero-Skip Design

The proposed accelerator combines:

- fixed-length five-trit / 8-bit weight packing,
- on-chip LUT decoding,
- zero-skipping of zero-valued ternary weights,
- static PE ownership of output groups,
- private partial-sum accumulation per PE, and
- offline weight permutation.

The final compute core does not require a global product router or
inter-PE accumulation arbitration.

### Dense PE-Owned Baseline

The dense baseline uses the same PE ownership and private accumulation
organization but processes all ternary weight positions without
zero-skipping.

It is intended as a structurally matched baseline for evaluating the
cost and benefit of zero-skipping.

## Reference FPGA Configuration

- Board: Terasic DE25-Standard
- FPGA: Altera Agilex 5 A5ED013BB32AE4SR1
- Quartus Prime Pro: 26.1
- Processing elements: 128
- Input features: 6912
- Output features: 2560
- Packed weight interface: 256 bits
- Reference clock: 50 MHz

The reference shape corresponds to a representative ternary
`down_proj` linear layer.

## Repository Structure

- `rtl/core/` - proposed PE-owned zero-skip RTL
- `rtl/baseline/` - dense PE-owned baseline
- `rtl/lut/` - ternary decoding LUT
- `rtl/memory/` - FIFOs, activation storage, and weight streaming
- `top/` - FPGA top-level files
- `configs/` - fixed PE128 reference configuration
- `constraints/` - FPGA timing and pin constraints
- `ip/` - Quartus IP parameterization sources
- `scripts/quartus/` - clean FPGA reproduction scripts
- `results/reference/` - reference FPGA results

Generated Quartus databases and generated IP products are not tracked.

## FPGA Reproduction

### Requirements

The FPGA build requires:

- Quartus Prime Pro 26.1
- Agilex 5 device support

Python and Synopsys VCS are not required for reproducing the FPGA
synthesis, placement, routing, resource utilization, and Fmax results.

If Quartus executables are not on PATH, specify the installation:

    export QUARTUS_ROOTDIR=/path/to/intelFPGA_pro/26.1/quartus

All repository paths used by the FPGA build are relative to the
repository root.

### Proposed PE128 Zero-Skip Design

Run:

    ./scripts/quartus/build_zeroskip.sh

Reference post-fit result:

| Metric | Result |
| --- | ---: |
| ALMs | 35,597 / 46,800 (76%) |
| Registers | 32,250 |
| Block memory bits | 217,408 |
| RAM blocks | 159 / 358 (44%) |
| DSP blocks | 0 |
| Fmax | 107.16 MHz |
| Setup slack | 10.668 ns |

### Dense PE128 Baseline

Run:

    ./scripts/quartus/build_dense.sh

Reference post-fit result:

| Metric | Result |
| --- | ---: |
| ALMs | 29,333 / 46,800 (63%) |
| Registers | 30,762 |
| Block memory bits | 217,408 |
| RAM blocks | 159 / 358 (44%) |
| DSP blocks | 0 |
| Fmax | 98.67 MHz |
| Setup slack | 9.865 ns |

## Reproducibility

Each FPGA build:

1. creates a new Quartus project using Tcl,
2. installs the fixed PE128 configuration,
3. regenerates the required IP,
4. runs a full Quartus compilation, and
5. reports post-fit resource utilization and Fmax.

All generated files are placed under:

    build/quartus/

The build directory is disposable and is excluded from Git.

## Functional Evaluation

Python-based model preparation and cycle-accurate RTL simulation are
separate workflows from the FPGA implementation flow.

They are not required to reproduce the FPGA implementation results
listed above.

## Model Weights

Model weights are not included in this repository.

The FPGA resource and timing reproduction flow does not require model
weight files.

## Power

Power results used in the associated evaluation were obtained with
Quartus Power Analyzer using workload-derived VCD activity.

Absolute power estimates were reported by Quartus with low confidence,
so they should primarily be interpreted as matched relative
comparisons between architectures.

## License

A license will be added according to the applicable
university/laboratory intellectual-property policy.

## Citation

Citation information will be added with the associated publication.
