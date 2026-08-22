#!/usr/bin/env bash
set -euo pipefail

BUILD="${1:?usage: report_results.sh <build-dir>}"

FIT="${BUILD}/output_files/zeroskip_top.fit.rpt"
STA="${BUILD}/output_files/zeroskip_top.sta.rpt"
SUM="${BUILD}/output_files/zeroskip_top.sta.summary"

echo
echo '===== RESOURCE ====='

grep -E \
  'Logic utilization \(in ALMs\)|Total dedicated logic registers|Total block memory bits|Total RAM Blocks|Total DSP Blocks' \
  "$FIT" \
  | head -10

echo
echo '===== FMAX ====='

grep -A8 '^; Fmax Summary' \
  "$STA" \
  | grep 'CLOCK_50' \
  || true

echo
echo '===== SETUP ====='

grep -A3 \
  "Type  : Setup 'CLOCK_50'" \
  "$SUM" \
  || true
