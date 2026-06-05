# PQC on RISC-V

Systems-engineering project: hardware-accelerated **ML-KEM (Kyber768)** and
**ML-DSA (Dilithium3)** as a custom RISC-V instruction extension, with
side-channel-aware microarchitecture targeting a Xilinx Kria KV260 (Zynq
UltraScale+) FPGA.

**Status:** Phase 3a — Python reference + working forward NTT engine RTL.
See [project page on the portfolio](https://alovladi007.github.io/louis-antoine-portfolio/projects/power-electronics/pqc-riscv-system.html)
for the full architecture, trade studies, threat model, and roadmap.

---

## What this is

A real post-quantum crypto subsystem is not "implement Kyber and call it
done." The interesting engineering lives in:

- **Hardware/software partitioning** — what runs in the RISC-V core, what
  runs in the co-processor, what runs in a dedicated TRNG
- **Side-channel posture** — constant-time control FSM, Boolean masking on
  NTT butterflies, TVLA-driven design iteration
- **Standards alignment** — NIST FIPS 203 / 204, NIST SP 800-90B,
  ISO/IEC 17825, CNSA 2.0
- **Verification** — Known Answer Tests, `dudect` for timing, cocotb for
  RTL, ChipWhisperer TVLA on real silicon
- **Integration** — OpenSSL provider shim so the accelerator backs real
  TLS 1.3 handshakes, not just synthetic benchmarks

This repo is the implementation side of that engineering. The companion
project page on the portfolio documents the architecture and trade studies.

## Repo layout

```
pqc-riscv-system/
├── python/                # Pure-Python reference + benchmark harness
│   ├── kyber/             # Kyber768 (ML-KEM) reference implementation
│   ├── ntt_ref.py         # Reference NTT against which the RTL is verified
│   ├── kats/              # NIST FIPS 203 Known Answer Test vectors
│   ├── bench.py           # Performance measurement harness
│   └── tests/             # pytest suite
├── rtl/                   # SystemVerilog RTL (synthesizable)
│   ├── kyber_q_alu.sv     # Modular arithmetic for q = 3329 (Barrett + Mont)
│   ├── ntt_butterfly.sv   # Single NTT butterfly (radix-2)
│   ├── ntt_engine.sv      # Iterative NTT engine (256-point, n=256)
│   └── keccak_round.sv    # Single round of Keccak-f[1600]
├── tb/                    # cocotb testbenches
│   ├── test_q_alu.py      # Modular arithmetic correctness vs Python
│   ├── test_ntt.py        # NTT correctness vs Python reference
│   └── Makefile           # cocotb sim driver (Icarus / Verilator backends)
├── docs/                  # Architecture + threat model
│   ├── architecture.md
│   └── threat-model.md
└── .github/workflows/
    └── ci.yml             # pytest + verilator lint on every push
```

## Quick start

### Python reference + KATs

```bash
cd python
python -m pip install -r requirements.txt
pytest tests/ -v
python bench.py                  # cycles + wall-clock for keygen/encaps/decaps
```

### RTL simulation (cocotb)

```bash
cd tb
make SIM=icarus                  # or SIM=verilator
```

Each module under `rtl/` has a matching cocotb test that compares against the
Python reference. CI runs them automatically on every push.

## What's done in Phase 2 + Phase 3a

**Python reference (FIPS 203 ML-KEM-768)**
- [x] `python/kyber768.py`: `keygen_internal(d, z)`, `encaps_internal(ek, m)`,
      `decaps(dk, c)`, plus `os.urandom`-backed wrappers
- [x] Standalone NTT / inverse NTT (256-point over GF(3329))
- [x] Modular arithmetic primitives (Barrett, Montgomery) — Python + SV
- [x] Polynomial machinery: compress/decompress (`d ∈ {1,4,5,10,11}`),
      byte_encode/decode, CBD(η) noise sampling, rejection sampling
      from SHAKE128
- [x] Symmetric primitives wired (G = SHA3-512, H = SHA3-256,
      J = SHAKE256→32B, PRF = SHAKE256-based, XOF = SHAKE128 stream)
- [x] Keccak-f[1600] reference (`python/keccak_ref.py`) — reproduces
      the published `f^24(0)` lane-0 constant `0xF1258F7940E1DDE7`
- [x] **Correctness validated 26/26:** 10 round-trip tests +
      16 byte-exact cross-checks against
      [kyber-py](https://github.com/GiacomoPope/kyber-py) (every byte of
      `ek`, `dk`, `c`, `K` matches for randomized seeds)

**SystemVerilog RTL (Phase 3a)**
- [x] `kyber_q_alu.sv` — Barrett + modular add/sub, 4 cocotb tests
- [x] `ntt_butterfly.sv` — radix-2 Cooley-Tukey + Montgomery, 3 cocotb tests
- [x] `ntt_inv_butterfly.sv` — radix-2 Gentleman-Sande + Montgomery
- [x] `ntt_engine.sv` — **full 256-pt in-place forward + inverse NTT,
      16-state FSM, internal twiddle ROM, byte-exact match to
      python/ntt_ref.py over 8 cocotb tests (forward zero/delta/2 random,
      inverse zero/delta/random, forward+inverse round-trip)**
- [x] `keccak_round.sv` — single Keccak-f[1600] round, Verilator-clean
- [x] `keccak_f1600.sv` — **24-round controller, byte-exact match to
      python/keccak_ref.py over 3 cocotb tests (zero / random /
      f∘f compose)**
- [x] `sha3_256.sv` — **SHA3-256 sponge wrapping keccak_f1600;
      byte-streaming interface, rate=136, domain=0x06; 6 cocotb tests
      vs python/sponge_ref.sha3_256 including the published "abc" KAT
      and rate-boundary stress cases**

**Python (Phase 4a)**
- [x] `python/sponge_ref.py` — full sponge layer (SHA3-256/512 +
      SHAKE-128/256) on top of keccak_ref; 62 tests cross-validate
      against `hashlib`

**CI** (green at HEAD)
- `pytest` over the full Python suite — **131 tests pass** (NTT/Kyber 69 + sponge 62)
- `verilator --lint-only -Wall` on every RTL module
- cocotb (Icarus): q_alu (4/4), butterfly (3/3),
  **ntt_engine forward+inverse (8/8), keccak_f1600 (3/3), sha3_256 (6/6)**
  — **24 cocotb tests**

## Phase 3b — Keccak cocotb fix shipped

Phase 3a left `make keccak` paused on an Icarus VPI binding bug:
state-array reads returned all-X under cocotb even though the same
RTL produced canonical Keccak-Team `f^24(0) = 0xF1258F7940E1DDE7` in
a pure-SV testbench (`tb/test_keccak_standalone.sv`).

Root cause was the `keccak_round` port signature using unpacked
arrays:

```sv
input  wire [63:0] state_in [0:24]
output logic [63:0] state_out [0:24]
```

Icarus's VPI under cocotb does not propagate driver values through
unpacked-array module ports — `state_in` arrived all-X even when the
calling register held correct values, so `round_out` went X and
propagated forward.

Fix (commit `7814b0a`): pack the ports into 1600-bit bit-vectors and
unpack internally. Algorithm unchanged; verification path now binds
cleanly through cocotb. All three keccak tests pass in CI.

## Phase 3c — Inverse NTT shipped

`ntt_engine.sv` now implements both directions. The `inverse` input
selects:

- **inverse=0** — Cooley-Tukey butterfly, schedule length=128..2
  halving with k=1..127 incrementing (forward NTT, byte-exact to
  pq-crystals/kyber `poly_ntt()` semantics).
- **inverse=1** — Gentleman-Sande butterfly
  (`rtl/ntt_inv_butterfly.sv`), schedule length=2..128 doubling with
  k=127..1 decrementing, followed by a 256-cycle final scaling pass
  `mem[j] <- f_inv * mem[j] mod q` where `f_inv = 128⁻¹ mod 3329 = 3303`
  (Kyber uses an incomplete NTT with 7 halvings, so the scaling
  factor is `n/2⁻¹` not `n⁻¹`). The scaling pass reuses the forward
  butterfly with `a=0, zeta=MONT_F_INV=512` so its output `a_out =
  f_inv * coef mod q`. No new arithmetic unit needed.

The strongest correctness test, `ntt_round_trip`, confirms forward
then inverse reproduces a random 256-coefficient input bit-exactly.

## What's coming next

**Phase 4** (synthesis + integration)
- [ ] RoCC-style wrapper for CV32E40P integration
- [ ] Synthesis pass for Kria KV260; resource utilization report
- [ ] Rejection sampler + CBD sampler in RTL
- [ ] Sponge / absorb / squeeze layer on top of `keccak_f1600.sv`

**Phase 5** (side-channel)
- [ ] Boolean masking on NTT butterflies (DPA countermeasure)
- [ ] TVLA framework (ChipWhisperer Husky + CW313 target board)

## Security notice — please read

The Python reference in this repo is for **functional verification of the
RTL**, not for production use. It is straightforward Python and makes no
constant-time guarantees. Do not use it to protect actual secrets.

For production post-quantum crypto today, use a reviewed implementation:

- [pq-crystals/kyber](https://github.com/pq-crystals/kyber) (canonical C reference)
- [liboqs](https://github.com/open-quantum-safe/liboqs) (Open Quantum Safe)
- [PyCryptodome](https://www.pycryptodome.org/) for production Python

This repo is a learning + systems-engineering exercise, clearly scoped as
such. The threat-model document explains what attacks the *final* design
intends to mitigate; the current Python reference does not implement those
countermeasures yet.

## Standards

| Standard | Role |
| --- | --- |
| [NIST FIPS 203](https://csrc.nist.gov/pubs/fips/203/final) | ML-KEM (Kyber) — primitive correctness |
| [NIST FIPS 204](https://csrc.nist.gov/pubs/fips/204/final) | ML-DSA (Dilithium) — primitive correctness |
| [NIST SP 800-90B](https://csrc.nist.gov/publications/detail/sp/800-90b/final) | Entropy source assessment for the TRNG |
| [ISO/IEC 17825](https://www.iso.org/standard/82371.html) | Non-invasive side-channel attack testing (TVLA) |
| [CNSA 2.0](https://www.nsa.gov/Press-Room/News-Highlights/Article/Article/3148990/) | NSA operational guidance on PQC migration |

## License

[MIT](LICENSE) — see file for full text. Pure-Python reference is original
work. KAT vectors imported from pq-crystals/kyber are under that project's
license.

## Related

- [CV-QKD Network Architecture](https://github.com/alovladi007/cvqkd-network) —
  sister project. The PQC accelerator in this repo is the building block
  of the trusted-node hardware in the CV-QKD network's hybrid PQC + QKD
  key management design.
- [Portfolio project page](https://alovladi007.github.io/louis-antoine-portfolio/projects/power-electronics/pqc-riscv-system.html) —
  full architecture, trade studies, threat model.
