#!/usr/bin/env bash
# Copyright 2026 Yu Inoue
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
exec "${ROOT}/scripts/quartus/build.sh" zeroskip "$@"
