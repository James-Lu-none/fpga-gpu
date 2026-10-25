#!/usr/bin/env bash
set -euo pipefail
mode=${1:?Usage: vivado.sh implementation|bitstream}
[[ $mode == implementation || $mode == bitstream ]] || exit 2
cd "$(dirname "$0")/.."
VIVADO_SETTINGS=${VIVADO_SETTINGS:-/opt/Xilinx/2026.1/Vivado/settings64.sh}
if [[ -n $VIVADO_SETTINGS ]]; then
    # Vivado's vendor environment setup may reference unset variables.
    set +u
    source "$VIVADO_SETTINGS"
    set -u
fi
export XILINXD_LICENSE_FILE="${XILINXD_LICENSE_FILE:-/opt/Xilinx/Xilinx.lic}"
command -v vivado >/dev/null || { echo 'ERROR: Vivado is unavailable; check VIVADO_SETTINGS and the installation.' >&2; exit 1; }
export CI_OUTPUT_DIR="$PWD/artifacts/vivado"
mkdir -p "$CI_OUTPUT_DIR"
collect_logs() {
    local rc=$?
    if [[ $mode == implementation ]]; then
        mkdir -p "$CI_OUTPUT_DIR/run-logs"
        while IFS= read -r -d '' file; do
            cp --parents "$file" "$CI_OUTPUT_DIR/run-logs/" || true
        done < <(find fpga-gpu-hardware "$CI_OUTPUT_DIR/project" -path '*.runs/*' -type f \
            \( -name '*.log' -o -name '*.rpt' \) -print0)
    fi
    exit "$rc"
}
trap collect_logs EXIT
if [[ $mode == implementation ]]; then
    git rev-parse HEAD > "$CI_OUTPUT_DIR/source-sha.txt"
    git submodule status --recursive > "$CI_OUTPUT_DIR/submodules.txt"
    vivado -version > "$CI_OUTPUT_DIR/vivado-version.txt"
else
    test "$(cat "$CI_OUTPUT_DIR/source-sha.txt")" = "$(git rev-parse HEAD)"
    vivado -version > "$CI_OUTPUT_DIR/current-vivado-version.txt"
    cmp "$CI_OUTPUT_DIR/vivado-version.txt" "$CI_OUTPUT_DIR/current-vivado-version.txt"
    (cd "$CI_OUTPUT_DIR" && sha256sum -c checkpoint.sha256)
fi
case "$mode" in
    implementation) tcl_script=implement.tcl ;;
    bitstream) tcl_script=write_bitstream.tcl ;;
esac
vivado -mode batch -notrace -source "fpga-gpu-hardware/$tcl_script" \
    -log "$CI_OUTPUT_DIR/$mode.log" -journal "$CI_OUTPUT_DIR/$mode.jou"
if [[ $mode == implementation ]]; then
    (cd "$CI_OUTPUT_DIR" && sha256sum routed.dcp > checkpoint.sha256)
else
    (cd "$CI_OUTPUT_DIR" && sha256sum top.bit top.bin > bitstream.sha256)
fi
