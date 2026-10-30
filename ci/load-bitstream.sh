#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
VIVADO_LAB_SETTINGS=${VIVADO_LAB_SETTINGS:-/opt/Xilinx/2026.1/Vivado_Lab/settings64.sh}
# Vendor setup scripts may reference variables that are not defined yet.
set +u
source "$VIVADO_LAB_SETTINGS"
set -u
if [[ -z ${VIVADO_LAB:-} ]]; then
    VIVADO_LAB=$(command -v vivado_lab) || {
        echo 'ERROR: vivado_lab is unavailable after sourcing settings64.sh.' >&2
        exit 1
    }
fi
export VIVADO_LAB
echo "Vivado Lab environment: $VIVADO_LAB_SETTINGS"
exec python3 -u ci/testbench.py load "$@"
