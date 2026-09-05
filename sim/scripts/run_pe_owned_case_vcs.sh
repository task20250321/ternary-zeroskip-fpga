# SPDX-License-Identifier: Apache-2.0
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CASE_DIR="${1:?usage: run_pe_owned_case_vcs.sh sim/prepared_cases/<case-id>}"
CASE_DIR="$(cd "${ROOT}" && realpath "${CASE_DIR}")"
mkdir -p "${CASE_DIR}/vcs_results"
if [[ ! -f "${CASE_DIR}/zeroskip_active_case.svh" ]]; then
  echo "[ERROR] missing ${CASE_DIR}/zeroskip_active_case.svh" >&2; exit 1
fi
/bin/cp -f "${CASE_DIR}/zeroskip_active_case.svh" "${ROOT}/top/zeroskip_active_case.svh"
BUILD="${CASE_DIR}/vcs_build_pe_owned"
rm -rf "${BUILD}"
mkdir -p "${BUILD}"
cd "${ROOT}"

vcs \
  -full64 \
  -sverilog \
  -timescale=1ns/1ps \
  +incdir+top \
  +incdir+sim/tb \
  -f sim/filelists/zeroskip_pe_owned_case.f \
  -top tb_zeroskip_pe_owned_case \
  -o "${BUILD}/simv" \
  -Mdir="${BUILD}/csrc" \
  -l "${BUILD}/compile.log"


# TB writes one decimal output file per physical bank.
mkdir -p "${CASE_DIR}/vcs_results/banks"

"${BUILD}/simv" \
  "+CASE_DIR=${CASE_DIR}" \
  -l "${CASE_DIR}/vcs_results/run_pe_owned.log"

cat "${CASE_DIR}/vcs_results/vcs_run_report.txt"
