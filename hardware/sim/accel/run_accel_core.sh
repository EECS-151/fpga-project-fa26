#!/bin/sh
# usage: sim/accel/run_accel_core.sh [case ...]       (every case: make accel-core-tests)
# accel_core (src/accel) against the expected vectors (sim/accel/vectors), under VCS, with the
# CPU port on its own clock. Runs every case (or the named ones) at BUS_BYTES 8 and 1, once per CPU
# clock period.
#   SYSTEM=1     test accel_system instead (zu3top's wrapper) on the Ethernet interface's simulation
#                model (sim_models/eth_seal_sim.sv): BUS_BYTES 1 only
#   CPU_PERIODS  CPU clock periods in ns; the accelerator's is 10 (default: "10 6.83 13.7":
#                equal, a faster CPU, a slower one)
#   WAVES=1      dump each run's waveform to $OUT/<case>.<bus>.cpu<period>.fsdb (open it in Verdi);
#                best with one case and one period, e.g.
#                WAVES=1 CPU_PERIODS=10 sim/accel/run_accel_core.sh default_seed1
#   VECTORS      the vectors directory                  (default: sim/accel/vectors)
#   OUT          scratch directory                      (default: sim/accel/out)
set -e
cd "$(dirname "$0")/../.."
HW="$(pwd)"
CPU_PERIODS="${CPU_PERIODS:-10 6.83 13.7}"
VECTORS="${VECTORS:-$HW/sim/accel/vectors}"
OUT="${OUT:-$HW/sim/accel/out}"
SYSTEM="${SYSTEM:-0}"
WAVES="${WAVES:-0}"
if [ "$SYSTEM" = 1 ]; then BUSES=1; else BUSES="8 1"; fi
if [ "$WAVES" = 1 ]; then WAVE_OPTS="-kdb -debug_access+all +define+WAVES"; WAVE_TAG=_waves; else WAVE_OPTS=""; WAVE_TAG=""; fi
mkdir -p "$OUT"
rm -rf "$OUT"/simv_* "$OUT"/csrc_*                     # never test stale RTL
A="$HW/src/accel"
SOURCES="$A/true_dual_port_bram.sv $A/ffs.sv $A/book_side.sv $A/quote_mgr.sv
  $A/order_state.sv $A/msg_ingress.sv $A/msg_egress.sv $A/async_fifo.sv $A/cdc_handshake.sv $A/cpu_if.sv
  $A/book_resync.sv $A/response_closer.sv $A/accel_ctrl.sv $A/accel_core.sv
  $A/accel_system.sv $HW/sim_models/eth_seal_sim.sv $HW/sim/accel/accel_core_tb.sv"
CASES="${*:-$(ls "$VECTORS" | grep -v '\.md$')}"
failed=0
cd "$OUT"
for BUS in $BUSES; do
  for CASE in $CASES; do
    [ -f "$VECTORS/$CASE/params.txt" ] || { echo "no such case: $CASE (see $VECTORS)"; exit 1; }
    read HARD MAXQ QUIET < "$VECTORS/$CASE/params.txt"
    BIN="simv_${BUS}_${HARD}_${MAXQ}${WAVE_TAG}"
    if [ ! -x "$BIN" ]; then
      vcs -full64 -sverilog -timescale=1ns/10ps $WAVE_OPTS -Mdir="csrc_$BIN" -o "$BIN" \
        -pvalue+accel_core_tb.BUS_BYTES=$BUS -pvalue+accel_core_tb.HARD_POSITION_LIMIT=$HARD \
        -pvalue+accel_core_tb.MAX_ORDER_QTY=$MAXQ -pvalue+accel_core_tb.VIA_SYSTEM=$SYSTEM \
        $SOURCES > "$BIN.compile.log" 2>&1 \
        || { echo "compile failed: $OUT/$BIN.compile.log"; exit 1; }
    fi
    # quiet cases: no RX gaps, no TX stalls
    if [ "$QUIET" = 1 ]; then KNOBS="+rx_gap=0 +tx_stall=0 +pop=100"; else KNOBS=""; fi
    for P in $CPU_PERIODS; do
      LOG="$CASE.$BUS.cpu$P.log"
      ./"$BIN" +vectors="$VECTORS/$CASE" +cpu_period=$P +fsdbfile+"$CASE.$BUS.cpu$P.fsdb" $KNOBS > "$LOG" 2>&1 || true
      if grep -q "^PASS" "$LOG"; then echo "ok    $CASE BUS_BYTES=$BUS cpu_period=$P"
      else failed=1; echo "FAIL  $CASE BUS_BYTES=$BUS cpu_period=$P  ($OUT/$LOG)"; grep -m 5 -E "FAIL|Fatal|Error" "$LOG" || true; fi
    done
  done
done
[ $failed = 0 ] && echo "PASS: every case at BUS_BYTES $BUSES, CPU periods $CPU_PERIODS" || { echo "some cases FAILED (logs in $OUT)"; exit 1; }
