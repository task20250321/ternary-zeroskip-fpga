#!/usr/bin/env bash
set -euo pipefail

ARCH="${1:?usage: build.sh <zeroskip|dense>}"

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

echo "============================================================"
echo "Architecture : ${ARCH}"
echo "ROOT         : ${ROOT}"
echo "BUILD        : ${BUILD}"
echo "Quartus      : ${QUARTUS_SH}"
echo "============================================================"

# ------------------------------------------------------------
# Check repository-side source files before touching BUILD.
# ------------------------------------------------------------
REQUIRED_FILES=(
    "${ROOT}/configs/pe128_down_proj.svh"
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

# ------------------------------------------------------------
# Completely disposable Quartus build tree.
# ------------------------------------------------------------
rm -rf "${BUILD}"

mkdir -p \
    "${BUILD}/include" \
    "${BUILD}/ip/ddr4_emif" \
    "${BUILD}/ip/jtag_host/ip/zeroskip_jtag_host"

# ------------------------------------------------------------
# Fixed PE128 paper configuration.
# ------------------------------------------------------------
cp \
    "${ROOT}/configs/pe128_down_proj.svh" \
    "${BUILD}/include/zeroskip_active_case.svh"

# ------------------------------------------------------------
# DDR4 EMIF parameterization.
# ------------------------------------------------------------
cp \
    "${ROOT}/ip/ddr4_emif/ddr4_emif.ip" \
    "${BUILD}/ip/ddr4_emif/ddr4_emif.ip"

# ------------------------------------------------------------
# JTAG-to-Avalon Platform Designer source + child IP
# parameterizations.
# ------------------------------------------------------------
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
