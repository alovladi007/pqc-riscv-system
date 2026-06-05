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
.PHONY: all q_alu butterfly ntt_engine keccak clean

all: q_alu butterfly ntt_engine keccak

q_alu:
	$(MAKE) -f Makefile.run \
		SIM_BUILD=sim_build/q_alu \
		MODULE=test_q_alu \
		TOPLEVEL=kyber_q_alu \
		VERILOG_SOURCES="$(RTL_DIR)/kyber_q_alu.sv"

butterfly:
	$(MAKE) -f Makefile.run \
		SIM_BUILD=sim_build/butterfly \
		MODULE=test_butterfly \
		TOPLEVEL=ntt_butterfly \
		VERILOG_SOURCES="$(RTL_DIR)/ntt_butterfly.sv"

ntt_engine:
	$(MAKE) -f Makefile.run \
		SIM_BUILD=sim_build/ntt_engine \
		MODULE=test_ntt_engine \
		TOPLEVEL=ntt_engine \
		VERILOG_SOURCES="$(RTL_DIR)/ntt_butterfly.sv $(RTL_DIR)/ntt_inv_butterfly.sv $(RTL_DIR)/ntt_engine.sv"

keccak:
	$(MAKE) -f Makefile.run \
		SIM_BUILD=sim_build/keccak \
		MODULE=test_keccak \
		TOPLEVEL=keccak_f1600 \
		VERILOG_SOURCES="$(RTL_DIR)/keccak_round.sv $(RTL_DIR)/keccak_f1600.sv"

clean:
	rm -rf sim_build results.xml *.vcd *.fst __pycache__
