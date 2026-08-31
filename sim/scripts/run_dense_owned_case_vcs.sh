#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <prepared-case-dir>" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
CASE="$1"

if [[ ! -f "$CASE/zeroskip_active_case.svh" ]]; then
  echo "missing $CASE/zeroskip_active_case.svh" >&2
  exit 1
fi

# Avoid the interactive cp alias seen on the servers.
/bin/cp -f "$CASE/zeroskip_active_case.svh" top/zeroskip_active_case.svh
mkdir -p "$CASE/vcs_results" "$CASE/vcs_build"

TOP=tb_dense_owned_case
BUILD="$CASE/vcs_build/$TOP"
rm -rf "$BUILD"
mkdir -p "$BUILD"

vcs -full64 -sverilog -timescale=1ns/1ps \
  -f sim/filelists/dense_owned_case.f \
  -o "$BUILD/simv"

"$BUILD/simv" +CASE_DIR="$(realpath "$CASE")"
