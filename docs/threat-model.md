# Threat model

Same table as on the [portfolio project page](https://alovladi007.github.io/louis-antoine-portfolio/projects/power-electronics/pqc-riscv-system.html),
expanded with implementation notes that belong in the repo rather than on
the public-facing page.

## Threat catalog

### T1 — Remote timing analysis

**Capability assumed:** any network-side attacker who can repeatedly trigger
the KEM (e.g. a TLS handshake initiator) and measure server-side response
time to nanosecond resolution by repeated probing and statistical aggregation.

**Mitigation in this design:** the control FSM and the NTT engine have no
data-dependent branches. Rejection sampling is the one place where input
secrecy interacts with iteration count — handled by a constant-bound padding
strategy (always run `MAX_REJECTIONS` iterations, mask out the failed ones).

**Verification:** `dudect` (Daniel J. Bernstein) on every secret-handling
routine, run in CI before tape-out. Currently a placeholder; will be wired
when the FPGA bring-up lands.

### T2 — Simple Power Analysis (SPA)

**Capability assumed:** local attacker with a single power trace.

**Mitigation:** same as T1 plus Hamming-weight-balanced state encoding in
the FSM. The Mod-q ALU avoids data-dependent fast paths.

**Residual risk:** low. Single-trace SPA on a Kyber-class scheme with
constant-time control is generally infeasible.

### T3 — Differential Power Analysis (DPA)

**Capability assumed:** local attacker with thousands of traces under
chosen-ciphertext conditions.

**Mitigation:** first-order Boolean masking on the NTT butterflies. The
butterfly takes two shares per coefficient; share refresh happens on
boundary entry. Shuffled rejection sampling adds further noise.

**Residual risk:** higher-order DPA not addressed in V1. Documented as a
deferred item.

### T4 — Electromagnetic side channel (TEMPEST)

**Capability assumed:** near-field probe placed on the FPGA package or PCB.

**Mitigation:** same masking as T3. EM is amplitude-vs-time, so masking
that defeats DPA also blunts EM. Integrators are advised in the
integration guide to add a metal can.

**Residual risk:** out of scope for V1 (no compliance claim against
NSA TEMPEST levels).

### T5 — Fault injection (voltage / clock glitch)

**Capability assumed:** physical access, glitch generator (~$5k of gear).

**Mitigation:** redundant computation on the signing path (double sign,
compare); sanity checks on NTT output (max-coefficient bound check). The
RoCC return status carries a fault flag distinct from "wrong result".

**Residual risk:** laser fault injection not addressed. Out of scope for V1.

### T6 — Trojan-horse / supply chain

**Capability assumed:** compromised bitstream or compromised toolchain.

**Mitigation:** reproducible build. `Makefile` pins Vivado version,
toolchain hashes, and the exact RTL git commit. Bitstream hash is the
release artifact; users can rebuild and compare.

**Residual risk:** doesn't address a compromised Vivado / Verilator binary.
Documented for downstream users.

## Standards alignment

- **NIST FIPS 203** — ML-KEM (Kyber). Functional correctness verified by
  imported KAT vectors from pq-crystals/kyber.
- **NIST FIPS 204** — ML-DSA (Dilithium). Phase 6.
- **NIST SP 800-90B** — Entropy source assessment. The TRNG section will
  carry a min-entropy estimate and health-test description before tape-out.
- **ISO/IEC 17825** — Non-invasive side-channel attack testing (TVLA).
  Target: |T| < 4.5 at 10⁵ traces, fixed-vs-random.
- **CNSA 2.0** — Operational guidance from NSA on PQC migration. Drives
  the choice of ML-KEM-768 over ML-KEM-512 (CNSA 2.0 requires Category 3
  or higher for "secret" classification).
