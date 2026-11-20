# Some available commands

## Simulation

### Regular Testbenches
```bash
make sim/cpu_tb.fsdb
# logfile
cat sim/cpu_tb.log
# waveform
make verdi TB=cpu_tb
```

### ISA Tests
```bash
make isa-tests
verdi -dbdir sim/isa/isa_tb.tb.daidir -ssf sim/isa/rv32ui-p-add.fsdb &
```

### Accelerator Tests (Checkpoint 3)
```bash
# unit testbenches: ffs, book_side, quote_mgr (any latency; results are checked at valid/done)
make sim/ffs_tb.fsdb
make sim/book_side_tb.fsdb
make sim/quote_mgr_tb.fsdb
# the whole accelerator against the test vectors (sim/accel/vectors), every case
make accel-core-tests
# one case, with waveforms (in sim/accel/out)
WAVES=1 CPU_PERIODS=10 sim/accel/run_accel_core.sh default_seed1
# your CPU and the accelerator together, through the MMIO window (software/accel_mmio)
make -C ../software/accel_mmio
make sim/accel_mmio_tb.fsdb
```

- Run every CPU testbench (builds the software first): `python3 scripts/run_all_sims.py` (`-c` to keep going after a failure)
- Clean simulation outputs: `make clean-sim`
- Forcefully re-run a testbench: `make -B sim/cpu_tb.fsdb`

## CAD Flow
- Checkpoint 3: set `HAS_ACCEL = 1'b1` in `src/zu3top.sv` to build with the accelerator. Its clock is
  `ACCEL_CLOCK_MHZ`, next to it.
- Lint RTL with verilator: `make lint`
- Open Vivado GUI: `make vivado`
- Elaborate and open circuit in GUI: `make elaborate`
- Synthesis: `make synth`
    - Log file: `build/synth/synth.log`
- Place, Route, Bitstream Generation (Implementation): `make impl`
    - Log file: `build/impl/impl.log`
- Program FPGA: `make program`
- Force program FPGA (don't rebuild bitstream if RTL changed): `make program-force`
- Give your FPGA board back: `make release`
- Show the board you currently hold: `make board-status`
- Clean CAD flow outputs: `make clean-build`

## Runtime
- Run screen to open UART connection: `make screen`
    - To exit screen: Ctrl-A Shift-K (then press 'y')

## Figure of Merit (Checkpoint 4)
FOM = 10^5 · sqrt(F<sub>max,CPU</sub> / (CPI × T<sub>t2t</sub> × cost))

- F<sub>max,CPU</sub> (MHz): the CPU clock, from `build/impl/post_route_timing_summary.rpt`. Timing must be met.
- CPI: the geometric mean of the `bdd`, `mmult`, `qsort` and `sha256` benchmarks' CPIs, run on your board.
- T<sub>t2t</sub> (ns): the median tick-to-trade the trading simulator shows for a round with your board
  (its FPGA tag latency median).
- cost: `build/impl/post_route_utilization.rpt`, priced by `scripts/get_cost.py`.

```bash
make impl && make program               # the CPI runs on the board you hold
make -C ../software/benchmark           # build the benchmarks
python3 scripts/fom.py --t2t <median tick-to-trade in ns>
```
- Results are also written to `fom.txt` (`-o` to change).
- Override any input instead of measuring it: `-c COST`, `-f FMAX_MHZ`, `--cpi CPI`.
- Quick estimates: `python3 scripts/fom.py -s ...` uses the post-synthesis reports;
  `python3 scripts/get_cpi.py` estimates CPI in simulation from the small benchmarks.
