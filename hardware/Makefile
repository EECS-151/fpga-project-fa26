SHELL                   := $(shell which bash) -o pipefail
ABS_TOP                 := $(subst /cygdrive/c/,C:/,$(shell pwd))
SCRIPTS                 := $(ABS_TOP)/scripts
VIVADO                  ?= vivado
VIVADO_OPTS             ?= -nolog -nojournal -mode batch
FPGA_PART               ?= xczu3eg-sfvc784-2-e
RTL                     += $(subst /cygdrive/c/,C:/,$(shell find $(ABS_TOP)/src -type f -name "*.sv"))
# The Ethernet shell (src/eth) and the vendored verilog-ethernet library it builds on: plain Verilog
ETH_RTL                 := $(subst /cygdrive/c/,C:/,$(shell find $(ABS_TOP)/src/eth $(ABS_TOP)/third_party/verilog-ethernet/rtl $(ABS_TOP)/third_party/verilog-ethernet/lib/axis/rtl -type f -name "*.v"))
# The FPGA build reads the Ethernet interface from src/eth/eth_seal_bundle.vp; simulation uses its
# model in sim_models/ (see ETH_SIM_MODEL below).
SEAL_VP                 := $(ABS_TOP)/src/eth/eth_seal_bundle.vp
SEALED                  ?= $(if $(wildcard $(SEAL_VP)),1,0)
ifeq ($(SEALED),1)
SYNTH_RTL               := $(filter-out $(ABS_TOP)/src/eth/%,$(RTL)) $(SEAL_VP)
SYNTH_ETH_RTL           :=
else
SYNTH_RTL               := $(RTL)
SYNTH_ETH_RTL           := $(ETH_RTL)
endif
CONSTRAINTS             += $(subst /cygdrive/c/,C:/,$(shell find $(ABS_TOP)/src -type f -name "*.xdc"))
TOP                     ?= zu3top
VCS                     := $(VCS_HOME)/bin/vcs -full64
VCS_OPTS                := -notice -line +lint=all,noVCDE,noNS,noSVA-UA -sverilog -kdb -timescale=1ns/10ps -debug_access+all -ignore initializer_driver_checks \
                           +define+ABS_TOP=$(ABS_TOP) +incdir+$(ABS_TOP)/src/riscv_core
VERDI                   ?= $(VERDI_HOME)/bin/verdi
SIM_MODELS              := $(subst /cygdrive/c/,C:/,$(shell find $(ABS_TOP)/sim_models -type f -name "*.sv"))
# Simulation uses the Ethernet interface's model (sim_models/eth_seal_sim.sv).
ETH_SIM_MODEL           ?= 1
ifeq ($(ETH_SIM_MODEL),1)
SIM_SRC                 := $(filter-out $(ABS_TOP)/src/eth/%,$(RTL))
SIM_MODELS_USED         := $(SIM_MODELS)
else
SIM_SRC                 := $(RTL) $(ETH_RTL)
SIM_MODELS_USED         := $(filter-out %/eth_seal_sim.sv,$(SIM_MODELS))
endif
# TODO (checkpoint 3) - Add to SIM_MODELS here

# Xilinx simulation libraries (unisims and XPM) from the Vivado install
XILINX_VIVADO           ?= /share/instsww/xilinx/2025.2/Vivado
UNISIM_LIB              := $(XILINX_VIVADO)/data/verilog/src/unisims
XPM_MODELS              := $(XILINX_VIVADO)/data/ip/xpm/xpm_cdc/hdl/xpm_cdc.sv \
                           $(XILINX_VIVADO)/data/ip/xpm/xpm_memory/hdl/xpm_memory.sv \
                           $(XILINX_VIVADO)/data/ip/xpm/xpm_fifo/hdl/xpm_fifo.sv
XIL_SIM_ARGS            := -v $(UNISIM_LIB)/../glbl.v \
                           -v $(UNISIM_LIB)/../retarget/CPU_GENERIC.v \
                           -y $(UNISIM_LIB) +libext+.v \
                           +incdir+$(UNISIM_LIB)
SIM_FILES               := $(XIL_SIM_ARGS) $(SIM_SRC) $(SIM_MODELS_USED) $(XPM_MODELS)

# ISA and C tests: one waveform per test program
ISA_TESTS               := $(shell find $(ABS_TOP)/../software/riscv-isa-tests -type f -name "*.hex")
ISA_TESTS_FSDB          := $(patsubst %.hex,sim/isa/%.fsdb,$(notdir $(ISA_TESTS)))
C_TESTS                 := $(shell find $(ABS_TOP)/../software/c_tests -type f -name "*.c")
C_TESTS_FSDB            := $(patsubst %.c,sim/c_tests/%.fsdb,$(notdir $(C_TESTS)))

sim/%.tb: sim/%.sv $(SIM_SRC) $(SIM_MODELS_USED)
	cd sim && $(VCS) $(VCS_OPTS) -o $*.tb $(SIM_FILES) $*.sv -top $* -top glbl

sim/%.fsdb: sim/%.tb
	cd sim && ./$*.tb +verbose=1 +fsdbfile+$*.fsdb |& tee $*.log

# Open Verdi with FSDB and VCS dbdir. Usage: make verdi [TB=cpu_tb]
verdi: sim/$(TB).fsdb
	$(VERDI) -dbdir sim/$(TB).tb.daidir -ssf sim/$(TB).fsdb &

sim/isa/isa_tb.tb: sim/isa_tb.sv $(SIM_SRC) $(SIM_MODELS_USED)
	@mkdir -p sim/isa
	@cd sim/isa && $(VCS) $(VCS_OPTS) +incdir+$(ABS_TOP)/sim -o isa_tb.tb $(SIM_FILES) ../isa_tb.sv -top isa_tb -top glbl > isa_tb_compile.log 2>&1

sim/isa/%.fsdb: sim/isa/isa_tb.tb $(ABS_TOP)/../software/riscv-isa-tests/%.hex
	@cd sim/isa && ./isa_tb.tb +verbose=1 +hex_file=$(word 2,$^) +test_name=$* +fsdbfile+$*.fsdb > $*.log 2>&1

isa-tests: $(ISA_TESTS_FSDB)
	@echo ""
	@echo "============================================================"
	@echo " ISA Test Results"
	@echo "============================================================"
	@printf "%-30s %8s  %s\n" "TEST" "CYCLES" "RESULT"
	@printf "%-30s %8s  %s\n" "----" "------" "------"
	@total=0; passed=0; failed=0; timeout=0; \
	for test in $(ISA_TESTS_FSDB:sim/isa/%.fsdb=%); do \
		log=sim/isa/$$test.log; \
		total=$$((total + 1)); \
		if [ ! -f $$log ]; then \
			printf "%-30s %8s  %s\n" "$$test" "-" "NO LOG"; \
		elif grep -q "\[passed\]" $$log; then \
			cycles=$$(grep "\[passed\]" $$log | grep -oP 'in\s+\K[0-9]+'); \
			printf "%-30s %8s  %s\n" "$$test" "$$cycles" "PASSED"; \
			passed=$$((passed + 1)); \
		elif grep -q "\[failed\]" $$log; then \
			printf "%-30s %8s  %s\n" "$$test" "-" "FAILED"; \
			failed=$$((failed + 1)); \
		elif grep -qiE "TIMEOUT|simulation time limit" $$log; then \
			printf "%-30s %8s  %s\n" "$$test" "-" "TIMEOUT"; \
			timeout=$$((timeout + 1)); \
		else \
			printf "%-30s %8s  %s\n" "$$test" "-" "UNKNOWN"; \
			failed=$$((failed + 1)); \
		fi; \
	done; \
	echo "============================================================"; \
	printf "Total: $$total  |  Passed: $$passed  |  Failed: $$failed  |  Timeout: $$timeout\n"; \
	echo "============================================================"

sim/c_tests/c_tests_tb.tb: sim/c_tests_tb.sv $(SIM_SRC) $(SIM_MODELS_USED)
	@mkdir -p sim/c_tests
	@cd sim/c_tests && $(VCS) $(VCS_OPTS) +incdir+$(ABS_TOP)/sim -o c_tests_tb.tb $(SIM_FILES) ../c_tests_tb.sv -top c_tests_tb -top glbl > c_tests_tb_compile.log 2>&1

sim/c_tests/%.fsdb: sim/c_tests/c_tests_tb.tb $(ABS_TOP)/../software/c_tests/%
	@cd sim/c_tests && ./c_tests_tb.tb +verbose=1 +hex_file=$(word 2,$^)/$*.hex +test_name=$* +fsdbfile+$*.fsdb > $*.log 2>&1

c-tests: $(C_TESTS_FSDB)

build/target.tcl: $(SYNTH_RTL) $(SYNTH_ETH_RTL) $(CONSTRAINTS)
	mkdir -p build
	truncate -s 0 $@
	echo "set ABS_TOP                        $(ABS_TOP)"    >> $@
	echo "set TOP                            $(TOP)"    >> $@
	echo "set FPGA_PART                      $(FPGA_PART)"  >> $@
	echo "set SEALED                         $(SEALED)"  >> $@
	echo "set_param general.maxThreads       4"    >> $@
	echo "set_param general.maxBackupLogs    0"    >> $@
	echo -n "set RTL { " >> $@
	FLIST="$(SYNTH_RTL)"; for f in $$FLIST; do echo -n "$$f " ; done >> $@
	echo "}" >> $@
	echo -n "set ETH_RTL { " >> $@
	FLIST="$(SYNTH_ETH_RTL)"; for f in $$FLIST; do echo -n "$$f " ; done >> $@
	echo "}" >> $@
	echo -n "set CONSTRAINTS { " >> $@
	FLIST="$(CONSTRAINTS)"; for f in $$FLIST; do echo -n "$$f " ; done >> $@
	echo "}" >> $@

setup: build/target.tcl

elaborate: build/target.tcl $(SCRIPTS)/elaborate.tcl
	mkdir -p ./build
	cd ./build && $(VIVADO) $(VIVADO_OPTS) -source $(SCRIPTS)/elaborate.tcl |& tee elaborate.log

../software/bios/bios.hex: ../software/bios/bios.c
	cd ../software/bios && $(MAKE)

build/synth/$(TOP).dcp: build/target.tcl $(SCRIPTS)/synth.tcl ../software/bios/bios.hex
	mkdir -p ./build/synth/
	cd ./build/synth/ && $(VIVADO) $(VIVADO_OPTS) -source $(SCRIPTS)/synth.tcl |& tee synth.log

synth: build/synth/$(TOP).dcp

build/impl/$(TOP).bit: build/synth/$(TOP).dcp $(SCRIPTS)/impl.tcl
	mkdir -p ./build/impl/
	cd ./build/impl && $(VIVADO) $(VIVADO_OPTS) -source $(SCRIPTS)/impl.tcl |& tee impl.log

impl: build/impl/$(TOP).bit
all: build/impl/$(TOP).bit

program: build/impl/$(TOP).bit $(SCRIPTS)/program.tcl
	@rm -f $(SCRIPTS)/assign_board_log.tmp $(SCRIPTS)/port.tmp $(SCRIPTS)/serial.tmp; \
	if ! assign-fpga-board > $(SCRIPTS)/assign_board_log.tmp 2>&1 & then \
		sleep 1; \
	fi; \
	if grep -q "already have an instance" $(SCRIPTS)/assign_board_log.tmp; then \
		PID=$$(grep -oP '\d+' $(SCRIPTS)/assign_board_log.tmp | tail -n 1); \
		echo "Stale instance found (PID: $$PID). Clearing process tree..."; \
		SUDO_PID=$$(pstree -p -s $$PID | grep -oP 'sudo\([0-9]+\)' | head -n 1 | grep -oP '\d+'); \
		if [ -n "$$SUDO_PID" ]; then \
			kill $$SUDO_PID; \
			sleep 1; \
		fi; \
		assign-fpga-board > $(SCRIPTS)/assign_board_log.tmp 2>&1 & \
	fi; \
	echo "Waiting for board assignment..."; \
	while ! grep -q "Vivado hw_server port:" $(SCRIPTS)/assign_board_log.tmp; do \
		sleep 0.2; \
	done; \
	PORT=$$(grep -oP 'Vivado hw_server port: \K\d+' $(SCRIPTS)/assign_board_log.tmp); \
	SERIAL=$$(grep -oP 'serial \K[A-Z0-9]+' $(SCRIPTS)/assign_board_log.tmp); \
	echo "BOARD SERIAL: $$SERIAL"; \
	/share/instsww/xilinx/2025.2/Vivado/bin/hw_server -stcp:localhost:$$PORT > /dev/null 2>&1 & \
	cd build/impl && $(VIVADO) $(VIVADO_OPTS) -source $(SCRIPTS)/program.tcl -tclargs $$PORT

program-force:
	cd build/impl && $(VIVADO) $(VIVADO_OPTS) -source $(SCRIPTS)/program.tcl

vivado: build
	cd build && nohup $(VIVADO) </dev/null >/dev/null 2>&1 &

lint:
	verilator -DABS_TOP=$(ABS_TOP) --lint-only --top-module $(TOP) $(RTL) -I$(ABS_TOP)/src/riscv_core $(ABS_TOP)/stubs/PLLE2_ADV.sv $(ABS_TOP)/sim_models/BUFG.sv

sim_build/compile_simlib/synopsys_sim.setup:
	mkdir -p sim_build/compile_simlib
	cd build/sim_build/compile_simlib && $(VIVADO) $(VIVADO_OPTS) -source $(SCRIPTS)/compile_simlib.tcl

compile_simlib: sim_build/compile_simlib/synopsys_sim.setup

screen:
	screen /dev/ttyUSB0 115200

clean-sim:
	rm -rf *.daidir sim/output.txt \
	sim/*.tb sim/*.daidir sim/csrc \
	sim/ucli.key sim/*.fsdb sim/novas* \
	sim/*.jou sim/*.log sim/*.out \
	sim/isa sim/c_tests \
	novas.* verdiLog

clean-build:
	rm -rf ./build

clean: clean-sim clean-build

.PHONY: setup elaborate synth impl program program-force vivado all lint compile_simlib screen verdi \
        isa-tests c-tests clean clean-sim clean-build
.PRECIOUS: sim/%.tb
