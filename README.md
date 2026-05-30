# PQC on RISC-V

Systems-engineering project: hardware-accelerated **ML-KEM (Kyber768)** and
**ML-DSA (Dilithium3)** as a custom RISC-V instruction extension, with
side-channel-aware microarchitecture targeting a Xilinx Kria KV260 (Zynq
UltraScale+) FPGA.

**Status:** Phase 2 — Python reference + RTL skeleton. See [project page on
the portfolio](https://alovladi007.github.io/louis-antoine-portfolio/projects/power-electronics/pqc-riscv-system.html)
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

## What's done in Phase 2

- [x] Pure-Python ML-KEM-768 reference (`python/kyber768.py`):
      `keygen_internal(d, z)`, `encaps_internal(ek, m)`, `decaps(dk, c)`
      per FIPS 203, plus `keygen()` / `encaps()` wrappers
- [x] Standalone NTT / inverse NTT reference (256-point over GF(3329))
- [x] Modular arithmetic primitives (Barrett, Montgomery) — Python + SV
- [x] Polynomial machinery: compress/decompress (`d ∈ {1,4,5,10,11}`),
      byte_encode/decode, CBD(η) noise sampling, rejection sampling
      from SHAKE128
- [x] Symmetric primitives wired (G = SHA3-512, H = SHA3-256,
      J = SHAKE256→32B, PRF = SHAKE256-based, XOF = SHAKE128 stream)
- [x] **Correctness validated 26/26:** 10 round-trip tests +
      16 byte-exact cross-checks against
      [kyber-py](https://github.com/GiacomoPope/kyber-py) (every byte of
      `ek`, `dk`, `c`, `K` matches for randomized seeds)
- [x] cocotb testbench framework with Python-as-golden-model pattern
- [x] CI: `pytest` + `verilator --lint-only` + cocotb on every push

## What's coming in Phase 3

- [ ] Full NTT engine RTL (currently butterfly + engine skeleton, needs the
      twiddle-factor schedule + control FSM completed)
- [ ] Keccak-f[1600] full 24-round pipeline
- [ ] Rejection sampler + CBD sampler
- [ ] RoCC wrapper for CV32E40P integration
- [ ] Synthesis pass for Kria KV260; resource utilization report
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
