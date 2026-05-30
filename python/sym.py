"""
Symmetric primitives for Kyber per FIPS 203 §4.1.

Kyber uses the SHA-3 family for everything: SHA3-256, SHA3-512, SHAKE128
(as the XOF for matrix expansion), and SHAKE256 (as the PRF for noise and
as the K-derivation hash). All four are in Python's stdlib `hashlib`.

The function names match FIPS 203 notation:
  G  : 64-byte hash               (= SHA3-512)
  H  : 32-byte hash               (= SHA3-256)
  J  : 32-byte SHAKE256 output    (used in implicit rejection)
  PRF: SHAKE256-based PRF with a single seed and 1-byte nonce
  XOF: SHAKE128-based extendable output, used to expand matrix A_hat

Nothing here is constant-time-claimed — this is the spec-following Python
reference, not the production target.
"""

from __future__ import annotations
import hashlib


def G(data: bytes) -> tuple[bytes, bytes]:
    """SHA3-512(data), returned split as (first 32 bytes, last 32 bytes).

    FIPS 203 uses G to derive a (rho, sigma) pair from a 32-byte seed in
    K-PKE.KeyGen, so returning the split form is convenient.
    """
    h = hashlib.sha3_512(data).digest()
    return h[:32], h[32:]


def H(data: bytes) -> bytes:
    """SHA3-256(data) — 32 bytes."""
    return hashlib.sha3_256(data).digest()


def J(data: bytes) -> bytes:
    """SHAKE256(data, 32 bytes). Used in implicit rejection on decapsulation
    when the re-encrypted ciphertext doesn't match the received ciphertext.
    """
    return hashlib.shake_256(data).digest(32)


def PRF(eta: int, seed: bytes, nonce: int) -> bytes:
    """SHAKE256-based PRF used to seed CBD noise sampling.

    Per FIPS 203 §4.2: PRF_eta(s, b) = SHAKE256(s || b, 64 * eta bytes).
    The output length depends on the noise parameter (eta1 for the noise
    in keygen, eta2 for the small noise terms in encryption).
    """
    if eta not in (2, 3):
        raise ValueError(f"unsupported eta={eta} (Kyber uses 2 or 3)")
    if len(seed) != 32:
        raise ValueError(f"PRF seed must be 32 bytes, got {len(seed)}")
    if not (0 <= nonce < 256):
        raise ValueError(f"PRF nonce must fit in one byte, got {nonce}")
    return hashlib.shake_256(seed + bytes([nonce])).digest(64 * eta)


class XOF:
    """SHAKE128 as the extendable output function used to expand matrix A_hat.

    Per FIPS 203 §4.2.2: XOF(rho, j, i) = SHAKE128(rho || j || i, ...).
    The output is consumed lazily by rejection sampling in sample_ntt.

    Implemented as a chunk-at-a-time reader so the rejection sampler can
    keep asking for more bytes until it has 256 valid coefficients.
    """

    def __init__(self, rho: bytes, j: int, i: int):
        if len(rho) != 32:
            raise ValueError(f"XOF seed must be 32 bytes, got {len(rho)}")
        if not (0 <= j < 256 and 0 <= i < 256):
            raise ValueError(f"XOF indices must fit in one byte each, got j={j}, i={i}")
        # SHAKE is a sponge — we consume the seed once and then squeeze chunks
        # on demand. hashlib's shake_128 returns the full digest of a fixed
        # length, so we squeeze in chunks of CHUNK bytes and re-hash when the
        # buffer drains. This matches what the reference C implementation
        # does at the API level.
        self._shake = hashlib.shake_128(rho + bytes([j, i]))
        self._buf = b""
        self._chunk_size = 168  # SHAKE128 rate in bytes (one squeezed block)
        self._squeezed = 0

    def read(self, n: int) -> bytes:
        """Return n more bytes of the XOF stream."""
        while len(self._buf) < n:
            # hashlib doesn't expose incremental squeezing, so we re-digest
            # at increasing lengths and slice off the new bytes. This is
            # correct because SHAKE output is deterministic and prefix-stable.
            self._squeezed += self._chunk_size
            full = self._shake.digest(self._squeezed)
            self._buf += full[self._squeezed - self._chunk_size:self._squeezed]
        out, self._buf = self._buf[:n], self._buf[n:]
        return out
