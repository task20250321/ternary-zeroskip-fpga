#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CASE_DIR="${1:?usage: run_fpga_jtag_case.sh sim/prepared_cases/<case-id>}"
CASE_DIR="$(cd "${ROOT}" && realpath "${CASE_DIR}")"

export ZS_CASE_DIR="${CASE_DIR}"
export ZS_MASTER_INDEX="${ZS_MASTER_INDEX:-0}"

cd "${ROOT}"
system-console \
  --cli \
  --project_dir="${ROOT}" \
  --script=tools/jtag_load_run_dump.tcl

python3 tools/compare_zeroskip_results.py \
  --expected "${CASE_DIR}/expected_outputs.txt" \
  --fpga "${CASE_DIR}/fpga_outputs.txt" \
  ${VCS_COMPARE:+--vcs "${CASE_DIR}/vcs_results/vcs_outputs.txt"}

cat "${CASE_DIR}/fpga_status.txt"
