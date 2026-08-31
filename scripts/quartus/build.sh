#!/usr/bin/env bash
set -euo pipefail

ARCH="${1:?usage: build.sh <zeroskip|dense> [options]}"
shift

case "$ARCH" in
    zeroskip|dense)
        ;;
    *)
        echo "ERROR: architecture must be zeroskip or dense" >&2
        exit 1
        ;;
esac

ROOT="$(
    cd "$(dirname "${BASH_SOURCE[0]}")/../.." &&
    pwd
)"

BUILD="${ROOT}/build/quartus/${ARCH}"

NUM_PE=128
IN_FEATURES=""
OUT_FEATURES=""
CONFIG_ARG=""

usage()
{
    cat <<'EOF'
Usage:
  build.sh <zeroskip|dense>
  build.sh <zeroskip|dense> --out-features N --in-features N [--num-pe N]
  build.sh <zeroskip|dense> --config PATH

Default:
  With no shape/config option, use configs/pe128_down_proj.svh
  (PE128, weight shape [2560, 6912] = [out_features, in_features]).

Options:
  --out-features N   Linear-layer output dimension.
  --in-features N    Linear-layer input dimension.
  --num-pe N         PE count. Supported values: 32, 64, 128.
                     Default: 128.
  --config PATH      Use an existing zeroskip_active_case.svh.
  -h, --help         Show this help.

The shape convention is PyTorch weight.shape = [out_features, in_features].
EOF
}

while [[ $# -gt 0 ]]
do
    case "$1" in
        --out-features)
            OUT_FEATURES="${2:?missing value for --out-features}"
            shift 2
            ;;
        --in-features)
            IN_FEATURES="${2:?missing value for --in-features}"
            shift 2
            ;;
        --num-pe)
            NUM_PE="${2:?missing value for --num-pe}"
            shift 2
            ;;
        --config)
            CONFIG_ARG="${2:?missing value for --config}"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

case "$NUM_PE" in
    32|64|128)
        ;;
    *)
        echo "ERROR: --num-pe must be one of 32, 64, 128" >&2
        exit 1
        ;;
esac

if [[ -n "$CONFIG_ARG" ]] &&
   [[ -n "$IN_FEATURES" || -n "$OUT_FEATURES" ]]
then
    echo "ERROR: --config cannot be combined with shape options" >&2
    exit 1
fi

if [[ -z "$CONFIG_ARG" ]] &&
   { [[ -n "$IN_FEATURES" ]] || [[ -n "$OUT_FEATURES" ]]; }
then
    if [[ -z "$IN_FEATURES" || -z "$OUT_FEATURES" ]]; then
        echo "ERROR: specify both --in-features and --out-features" >&2
        exit 1
    fi
fi

is_positive_integer()
{
    [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

ceil_log2()
{
    local n="$1"
    local x=1
    local bits=0

    while (( x < n ))
    do
        x=$((x * 2))
        bits=$((bits + 1))
    done

    printf '%d\n' "$bits"
}

resolve_tool()
{
    local tool="$1"

    if [[ -n "${QUARTUS_ROOTDIR:-}" ]] &&
       [[ -x "${QUARTUS_ROOTDIR}/bin/${tool}" ]]
    then
        printf '%s\n' "${QUARTUS_ROOTDIR}/bin/${tool}"
        return
    fi

    command -v "$tool"
}

QUARTUS_SH="$(resolve_tool quartus_sh)"
IPGEN="$(resolve_tool quartus_ipgenerate)"

REQUIRED_FILES=(
    "${ROOT}/ip/ddr4_emif/ddr4_emif.ip"
    "${ROOT}/ip/jtag_host/zeroskip_jtag_host.qsys"
    "${ROOT}/ip/jtag_host/ip/zeroskip_jtag_host/zeroskip_jtag_host_clock_in.ip"
    "${ROOT}/ip/jtag_host/ip/zeroskip_jtag_host/zeroskip_jtag_host_master_0.ip"
    "${ROOT}/ip/jtag_host/ip/zeroskip_jtag_host/zeroskip_jtag_host_reset_in.ip"
)

for f in "${REQUIRED_FILES[@]}"
do
    if [[ ! -f "$f" ]]; then
        echo "ERROR: required source file is missing:" >&2
        echo "  $f" >&2
        exit 1
    fi
done

rm -rf "${BUILD}"

mkdir -p \
    "${BUILD}/include" \
    "${BUILD}/ip/ddr4_emif" \
    "${BUILD}/ip/jtag_host/ip/zeroskip_jtag_host"

ACTIVE_CONFIG="${BUILD}/include/zeroskip_active_case.svh"
CONFIG_MODE=""

if [[ -n "$CONFIG_ARG" ]]
then
    if [[ "$CONFIG_ARG" = /* ]]; then
        CONFIG_SRC="$CONFIG_ARG"
    else
        CONFIG_SRC="${ROOT}/${CONFIG_ARG}"
    fi

    if [[ ! -f "$CONFIG_SRC" ]]; then
        echo "ERROR: config file not found:" >&2
        echo "  $CONFIG_SRC" >&2
        exit 1
    fi

    cp "$CONFIG_SRC" "$ACTIVE_CONFIG"
    CONFIG_MODE="external-config"
elif [[ -n "$IN_FEATURES" ]]
then
    if ! is_positive_integer "$IN_FEATURES"; then
        echo "ERROR: --in-features must be a positive integer" >&2
        exit 1
    fi
    if ! is_positive_integer "$OUT_FEATURES"; then
        echo "ERROR: --out-features must be a positive integer" >&2
        exit 1
    fi

    TOTAL_GROUPS=$(((OUT_FEATURES + 4) / 5))
    WORDS_PER_INPUT=$(((TOTAL_GROUPS + 31) / 32))
    TOTAL_WEIGHT_WORDS=$((IN_FEATURES * WORDS_PER_INPUT))
    ACC_EXTRA_BITS="$(ceil_log2 $((IN_FEATURES + 1)))"
    ACC_WIDTH=$((8 + ACC_EXTRA_BITS))

    cat > "$ACTIVE_CONFIG" <<EOF
\`ifndef ZEROSKIP_ACTIVE_CASE_SVH
\`define ZEROSKIP_ACTIVE_CASE_SVH
\`define ZS_NUM_PE             ${NUM_PE}
\`define ZS_NUM_BANKS          ${NUM_PE}
\`define ZS_IN_FEATURES        ${IN_FEATURES}
\`define ZS_OUT_FEATURES       ${OUT_FEATURES}
\`define ZS_LUT_IMPL           0
\`define ZS_ACC_WIDTH          ${ACC_WIDTH}
\`define ZS_WORDS_PER_INPUT    ${WORDS_PER_INPUT}
\`define ZS_TOTAL_WEIGHT_WORDS ${TOTAL_WEIGHT_WORDS}
\`define ZS_WEIGHT_DDR_BASE    30'h00100000
\`endif
EOF

    CONFIG_MODE="generated-shape"
else
    CONFIG_SRC="${ROOT}/configs/pe128_down_proj.svh"

    if [[ ! -f "$CONFIG_SRC" ]]; then
        echo "ERROR: default reference config is missing:" >&2
        echo "  $CONFIG_SRC" >&2
        exit 1
    fi

    cp "$CONFIG_SRC" "$ACTIVE_CONFIG"
    CONFIG_MODE="paper-reference"
fi

cp \
    "${ROOT}/ip/ddr4_emif/ddr4_emif.ip" \
    "${BUILD}/ip/ddr4_emif/ddr4_emif.ip"

cp \
    "${ROOT}/ip/jtag_host/zeroskip_jtag_host.qsys" \
    "${BUILD}/ip/jtag_host/zeroskip_jtag_host.qsys"

for F in \
    zeroskip_jtag_host_clock_in.ip \
    zeroskip_jtag_host_master_0.ip \
    zeroskip_jtag_host_reset_in.ip
do
    cp \
        "${ROOT}/ip/jtag_host/ip/zeroskip_jtag_host/${F}" \
        "${BUILD}/ip/jtag_host/ip/zeroskip_jtag_host/${F}"
done

echo "============================================================"
echo "Architecture : ${ARCH}"
echo "ROOT         : ${ROOT}"
echo "BUILD        : ${BUILD}"
echo "Quartus      : ${QUARTUS_SH}"
echo "Config mode  : ${CONFIG_MODE}"

if [[ "$CONFIG_MODE" == "generated-shape" ]]; then
    echo "Weight shape : [${OUT_FEATURES}, ${IN_FEATURES}] [out,in]"
    echo "PE count     : ${NUM_PE}"
    echo "Groups/input : ${TOTAL_GROUPS}"
    echo "Words/input  : ${WORDS_PER_INPUT}"
    echo "Weight words : ${TOTAL_WEIGHT_WORDS}"
    echo "ACC width    : ${ACC_WIDTH}"
fi

echo "Active config: ${ACTIVE_CONFIG}"
echo "============================================================"

echo
echo "===== ACTIVE CONFIG ====="
cat "$ACTIVE_CONFIG"

cd "${BUILD}"

echo
echo "===== CREATE PROJECT ====="

"${QUARTUS_SH}" \
    -t "${ROOT}/scripts/quartus/create_project.tcl" \
    "${ARCH}"

echo
echo "===== GENERATE IP ====="

"${IPGEN}" \
    --generate_project_ip_files \
    --synthesis=verilog \
    --clear_ip_generation_dirs \
    zeroskip_top

echo
echo "===== FULL COMPILE ====="

"${QUARTUS_SH}" \
    --flow compile zeroskip_top \
    2>&1 | tee compile.log

echo
echo "===== REPORT ====="

"${ROOT}/scripts/quartus/report_results.sh" \
    "${BUILD}"

echo
echo "===== SOF ====="

SOF="${BUILD}/output_files/zeroskip_top.sof"

if [[ ! -f "$SOF" ]]; then
    echo "ERROR: SOF was not generated:" >&2
    echo "  $SOF" >&2
    exit 1
fi

ls -lh "$SOF"
echo "PASS: ${SOF}"
