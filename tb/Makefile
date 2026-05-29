# cocotb driver for the Kyber RTL. Default simulator is Icarus; switch with
# `make SIM=verilator`. CI uses Icarus because it's smaller to install.
SIM      ?= icarus
TOPLEVEL_LANG ?= verilog
WAVES    ?= 0

# Tell cocotb where to find the Python golden model
export PYTHONPATH := $(PWD)/../python:$(PYTHONPATH)

# Shared sources every test pulls in
RTL_DIR = ../rtl
COMMON_SOURCES = $(RTL_DIR)/kyber_q_alu.sv

# Per-test targets — each one runs an independent cocotb test
.PHONY: all q_alu butterfly clean

all: q_alu

q_alu:
	$(MAKE) -f Makefile.run \
		MODULE=test_q_alu \
		TOPLEVEL=kyber_q_alu \
		VERILOG_SOURCES="$(RTL_DIR)/kyber_q_alu.sv"

butterfly:
	$(MAKE) -f Makefile.run \
		MODULE=test_butterfly \
		TOPLEVEL=ntt_butterfly \
		VERILOG_SOURCES="$(RTL_DIR)/ntt_butterfly.sv"

clean:
	rm -rf sim_build results.xml *.vcd *.fst __pycache__
