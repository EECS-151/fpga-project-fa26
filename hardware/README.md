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

- Clean simulation outputs: `make clean-sim`
- Forcefully re-run a testbench: `make -B sim/cpu_tb.fsdb`

## CAD Flow
- Lint RTL with verilator: `make lint`
- Open Vivado GUI: `make vivado`
- Elaborate and open circuit in GUI: `make elaborate`
- Synthesis: `make synth`
    - Log file: `build/synth/synth.log`
- Place, Route, Bitstream Generation (Implementation): `make impl`
    - Log file: `build/impl/impl.log`
- Program FPGA: `make program`
- Force program FPGA (don't rebuild bitstream if RTL changed): `make program-force`
- Clean CAD flow outputs: `make clean-build`

## Runtime
- Run screen to open UART connection: `make screen`
    - To exit screen: Ctrl-A Shift-K (then press 'y')
