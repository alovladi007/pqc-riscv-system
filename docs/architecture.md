# Architecture

Long form of the architecture diagram on the [portfolio project page](https://alovladi007.github.io/louis-antoine-portfolio/projects/power-electronics/pqc-riscv-system.html).
This file is the implementation-side reference that the RTL and Python
code in this repo answer to.

## Top level

```
+----------------------------------------------------------------------+
|                  RISC-V Application Core (CV32E40P)                  |
|  IF/ID/EX/MEM/WB + Custom-instruction dispatch via RoCC-style iface  |
+----------------------------------+-----------------------------------+
                                   | rd, rs1, rs2, funct7
                                   v
+----------------------------------------------------------------------+
|                       PQC Co-Processor                               |
|                                                                      |
|  +-------------+   +-------------+   +-------------+                 |
|  |  Mod-q ALU  |   |  NTT engine |   |  Keccak     |                 |
|  | (this repo) |   |   (skeleton)|   |   (1 round) |                 |
|  +-------------+   +-------------+   +-------------+                 |
|                                                                      |
|  +-------------+   +-------------+   +-------------+                 |
|  |  Sampler    |   |  Control    |   |  Key buffer |                 |
|  |  (CBD,rej)  |   |  FSM        |   |  (BRAM)     |                 |
|  +-------------+   +-------------+   +-------------+                 |
|                                                                      |
|  +-----------------------------------------------------------+       |
|  |   TRNG (ring-osc + von-Neumann debias + health tests)     |       |
|  +-----------------------------------------------------------+       |
+----------------------------------------------------------------------+
```

## ISA extension (proposed)

| Mnemonic     | Encoding (funct7) | rs1                  | rs2                | rd       | Effect |
|--------------|-------------------|----------------------|--------------------|----------|--------|
| `kem.keygen` | `0x10`            | seed_pubkey ptr      | seed_secret ptr    | status   | Generate (pk, sk) into RAM |
| `kem.encaps` | `0x11`            | pk ptr               | rng_seed ptr       | status   | Generate (ct, ss) |
| `kem.decaps` | `0x12`            | sk ptr               | ct ptr             | status   | Recover ss |
| `dsa.sign`   | `0x20`            | sk ptr               | msg ptr+len        | status   | Produce signature |
| `dsa.verify` | `0x21`            | pk ptr               | (msg, sig) ptrs    | result   | 0 = valid, 1 = invalid |
| `ntt.fwd`    | `0x30`            | poly ptr             | —                  | status   | Forward NTT in place |
| `ntt.inv`    | `0x31`            | poly ptr             | —                  | status   | Inverse NTT in place |
| `keccak.f`   | `0x40`            | state ptr            | rounds (1..24)     | status   | Run N rounds of Keccak-f[1600] |

Block memory addresses are read by the co-processor over AXI-Stream from the
key buffer / RAM; the core just passes pointers and waits for completion.

## Pipeline budget (target)

| Stage                | Cycles | Notes |
|----------------------|--------|-------|
| NTT (256-pt fwd)     | ~2k    | 7 stages × 128 butterflies × 2-cycle butterfly + overhead |
| NTT (256-pt inv)     | ~2k    | symmetric |
| Pointwise multiply   | ~256   | 1 cycle per pair (pipelined Montgomery) |
| Keccak-f[1600] (24r) | ~24    | one round per cycle, fully unrolled would be 1 cycle |
| Sampler (CBD)        | ~64    | for one polynomial of n=256 |
| Sampler (rejection)  | ~variable | depends on rejection rate (~256 expected for Kyber) |
| Kyber768 encaps      | ~15-25k cycles | dominant: 4 NTTs + 4 ptmuls + 4 Keccak invocations |
| Kyber768 decaps      | ~17-27k cycles | dominant: 5 NTTs + 4 ptmuls + 4 Keccak invocations |

At a 100 MHz fabric clock, that's roughly 150-250 µs per encapsulation —
matches the budget on the portfolio project page (≤ 60 µs is a stretch
goal at 200 MHz; baseline target is ≤ 250 µs at 100 MHz).

## Verification

See [tb/](../tb/) for the cocotb testbenches. The flow is:

1. **Reference in Python** ([../python/](../python/)) — exhaustive on small
   domains, Hypothesis-driven property tests for the full range. Currently
   43 tests, ~2 seconds to run.
2. **Bit-exact comparison** — cocotb drives the RTL with the same vectors
   the Python reference accepts, compares outputs.
3. **Synthesis lint** — `verilator --lint-only -Wall` catches the obvious
   stuff on every push.
4. **(Future)** Formal: `sby` cover + assertion checks on the FSM.
5. **(Future)** Real silicon: `dudect` on the cycle counters once the
   accelerator runs on a Kria board.
