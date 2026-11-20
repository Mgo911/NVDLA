#!/usr/bin/env bash
# ==============================================================================
# NVDLA VCS + Verdi Simulation Runner
#
# Usage:
#   ./run_vcs.sh                           # Run default sanity0 test
#   ./run_vcs.sh -t conv_8x8_fc_int16      # Run specified test
#   ./run_vcs.sh -gui                      # Run sanity0 and open Verdi GUI
#   ./run_vcs.sh -t sanity1 -gui           # Run sanity1 and open Verdi GUI
#   ./run_vcs.sh -clean                    # Clean temporary simulation outputs
# ==============================================================================

set -e

TEST_NAME="sanity0"
OPEN_GUI=0
DO_CLEAN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--test)
      TEST_NAME="$2"
      shift 2
      ;;
    -gui|--gui)
      OPEN_GUI=1
      shift
      ;;
    -clean|--clean)
      DO_CLEAN=1
      shift
      ;;
    -h|--help)
      echo "Usage: $0 [-t <test_name>] [-gui] [-clean]"
      echo "Available tests (under verif/traces/traceplayer/):"
      echo "  sanity0, sanity1, sanity2, sanity3"
      echo "  conv_8x8_fc_int16, googlenet_conv2_3x3_int16, sdp_relu_int16, pdp_max_pooling_int16"
      exit 0
      ;;
    *)
      echo "[ERROR] Unknown option: $1 (Run with -h for help)"
      exit 1
      ;;
  esac
done

PROJ_ROOT=$(cd "$(dirname "$0")" && pwd)
SIM_DIR="${PROJ_ROOT}/verif/sim"
TEST_PATH="../traces/traceplayer/${TEST_NAME}"

# Self-heal line endings and permissions for tools/bin and verif scripts
if [ -d "${PROJ_ROOT}/tools/bin" ]; then
    sed -i 's/\r$//' "${PROJ_ROOT}/tools/bin/"* 2>/dev/null || true
    chmod +x "${PROJ_ROOT}/tools/bin/"* 2>/dev/null || true
fi
if [ -d "${PROJ_ROOT}/verif" ]; then
    find "${PROJ_ROOT}/verif" -name "*.pl" -exec sed -i 's/\r$//' {} + 2>/dev/null || true
    find "${PROJ_ROOT}/verif" -name "*.pl" -exec chmod +x {} + 2>/dev/null || true
fi

# 0. Check VCS and Verdi
if ! command -v vcs &> /dev/null; then
    echo "[ERROR] 'vcs' not found in PATH! Please load EDA environment/module first."
    exit 1
fi

export VCS_HOME=$(dirname $(dirname $(which vcs)))
if command -v verdi &> /dev/null; then
    export VERDI_HOME=$(dirname $(dirname $(which verdi)))
    export NOVAS_HOME="${VERDI_HOME}"
else
    echo "[WARN] 'verdi' not found in PATH. Waveform viewing might not work."
fi

export PATH="${PROJ_ROOT}/tools/bin:${PATH}"
export PERL5LIB="${PROJ_ROOT}/tools/lib:${PERL5LIB}"

# Ensure tree.make exists (required by tmake)
if [ ! -f "${PROJ_ROOT}/tree.make" ]; then
    echo "[INFO] Creating default tree.make..."
    cat << 'TREE_EOF' > "${PROJ_ROOT}/tree.make"
PROJECTS := nv_full
CPP  := /usr/bin/cpp
GCC  := /usr/bin/g++
PERL := /usr/bin/perl
JAVA := /usr/bin/java
SYSTEMC := /usr/local/systemc-2.3.0/
VERILATOR := verilator
CLANG := clang
TREE_EOF
fi

echo "=================================================="
echo " [INFO] PROJ_ROOT : ${PROJ_ROOT}"
echo " [INFO] VCS_HOME  : ${VCS_HOME}"
echo " [INFO] VERDI_HOME: ${VERDI_HOME}"
echo " [INFO] TEST_NAME : ${TEST_NAME}"
echo "=================================================="

# 1. Clean mode
if [ "${DO_CLEAN}" -eq 1 ]; then
    echo "[INFO] Cleaning simulation artifacts..."
    cd "${SIM_DIR}"
    make clean_tests || true
    rm -rf simv* csrc *.fsdb *.vpd *.log
    echo "[INFO] Clean completed."
    exit 0
fi

# 2. Check if trace directory exists
if [ ! -d "${PROJ_ROOT}/verif/traces/traceplayer/${TEST_NAME}" ]; then
    echo "[ERROR] Test case not found: ${PROJ_ROOT}/verif/traces/traceplayer/${TEST_NAME}"
    echo "Please check available tests in verif/traces/traceplayer/"
    exit 1
fi

# 3. Check if RTL is generated, generate if not present
if [ ! -d "${PROJ_ROOT}/outdir/nv_full/vmod" ]; then
    echo "[INFO] RTL not generated yet, running 'tmake -b vmod'..."
    cd "${PROJ_ROOT}"
    tmake -b vmod
fi

# 4. Build simulation executable with VCS
cd "${SIM_DIR}"
echo "[INFO] Compiling simulation testbench with VCS (VERDI/FSDB enabled)..."
make build DUMP=1 DUMPER=VERDI

# 5. Run test
echo "[INFO] Running simulation test: ${TEST_NAME} ..."
make run DUMP=1 DUMPER=VERDI TESTDIR="${TEST_PATH}"

echo "=================================================="
echo " [INFO] Simulation completed! Checked with checktest."
echo "=================================================="

# 6. Open Verdi waveform
if [ "${OPEN_GUI}" -eq 1 ]; then
    FSDB_PATH=$(find "${SIM_DIR}" -name "*.fsdb" -newer "${SIM_DIR}/simv" 2>/dev/null | head -n 1)
    if [ -z "${FSDB_PATH}" ]; then
        FSDB_PATH=$(find "${SIM_DIR}" -name "*.fsdb" 2>/dev/null | head -n 1)
    fi

    if [ -n "${FSDB_PATH}" ] && [ -f "${FSDB_PATH}" ]; then
        echo "[INFO] Launching Verdi with waveform: ${FSDB_PATH} ..."
        cd "${SIM_DIR}"
        if [ -d "simv.daidir/kdb" ]; then
            verdi -dbdir simv.daidir -ssf "${FSDB_PATH}" &
        else
            verdi -sv -f ../dut/dut.f ../synth_tb/tb_top.v \
                +incdir+../dut \
                +incdir+../../outdir/nv_full/vmod/include \
                +incdir+../../outdir/nv_full/vmod/vlibs \
                +incdir+../synth_tb \
                -y ../synth_tb \
                -y ../../outdir/nv_full/vmod/vlibs \
                +libext+.v+.sv \
                -top top -ssf "${FSDB_PATH}" &
        fi
    else
        echo "[WARN] FSDB file not found, falling back to 'make verdi'..."
        make verdi TESTDIR="${TEST_PATH}" &
    fi
fi
