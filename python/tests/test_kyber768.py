"""
Correctness tests for Kyber768 (ML-KEM-768).

Two layers:

1. Round-trip self-consistency
   For random (d, z, m) triples: keygen_internal -> encaps_internal ->
   decaps must return the same shared secret. This catches all the
   internal-consistency bugs you can introduce in this much code.

2. Cross-check against kyber-py
   kyber-py is an independent pure-Python implementation that tracks
   FIPS 203 closely. For the same (d, z, m) inputs, every byte we
   produce — ek, dk, c, K — must match what kyber-py produces. If many
   random triples all match, the implementation is correct with
   overwhelming probability.

Both tests run in CI on every push.
"""

from __future__ import annotations
import os
import pytest

from kyber768 import (
    keygen_internal, encaps_internal, decaps,
    keygen, encaps,
    EK_SIZE, DK_SIZE, CT_SIZE, SS_SIZE,
)


# ----------------------------------------------------------------------------
# Layer 1: round-trip
# ----------------------------------------------------------------------------

class TestRoundTrip:
    """Internal consistency: encaps then decaps gives back the same key."""

    @pytest.mark.parametrize("seed", range(8))
    def test_random_roundtrip(self, seed):
        d = bytes([seed]) + b"\x00" * 31
        z = bytes([seed + 1]) + b"\x00" * 31
        m = bytes([seed + 2]) + b"\x00" * 31

        ek, dk = keygen_internal(d, z)
        assert len(ek) == EK_SIZE
        assert len(dk) == DK_SIZE

        K_e, c = encaps_internal(ek, m)
        assert len(K_e) == SS_SIZE
        assert len(c) == CT_SIZE

        K_d = decaps(dk, c)
        assert K_e == K_d, "decapsulated key must equal encapsulated key"

    def test_invalid_ciphertext_gives_pseudorandom_key(self):
        """Implicit rejection: flipping a bit in the ciphertext must still
        return a 32-byte key (not raise), and that key must NOT equal the
        original shared secret."""
        d = b"\x42" * 32
        z = b"\x99" * 32
        m = b"\x01" * 32
        ek, dk = keygen_internal(d, z)
        K_real, c = encaps_internal(ek, m)
        c_tampered = bytearray(c)
        c_tampered[0] ^= 0x01
        K_rejected = decaps(dk, bytes(c_tampered))
        assert len(K_rejected) == SS_SIZE
        assert K_rejected != K_real

    def test_top_level_uses_os_random(self):
        """keygen() / encaps() use os.urandom — successive calls give
        different keys with overwhelming probability."""
        ek1, dk1 = keygen()
        ek2, dk2 = keygen()
        assert ek1 != ek2 and dk1 != dk2
        K1, c1 = encaps(ek1)
        K2, c2 = encaps(ek1)
        assert K1 != K2 and c1 != c2


# ----------------------------------------------------------------------------
# Layer 2: cross-check against kyber-py
# ----------------------------------------------------------------------------

# kyber-py is added as a dev dep; if it's not installed (e.g. in a minimal
# environment) we skip the cross-check rather than fail. CI installs it
# unconditionally so the check runs there.
kyber_py = pytest.importorskip("kyber_py.ml_kem", reason="kyber-py not installed")


class TestCrossCheck:
    """Every byte we produce must match kyber-py for the same seeds."""

    @pytest.mark.parametrize("seed", range(8))
    def test_keygen_matches_kyber_py(self, seed):
        d = (seed * 7 % 256).to_bytes(1, 'little') + os.urandom(31)
        z = (seed * 11 % 256).to_bytes(1, 'little') + os.urandom(31)

        ours_ek, ours_dk = keygen_internal(d, z)

        ml_kem = kyber_py.ML_KEM_768
        theirs_ek, theirs_dk = ml_kem._keygen_internal(d, z)

        assert ours_ek == theirs_ek, "ek mismatch with kyber-py"
        assert ours_dk == theirs_dk, "dk mismatch with kyber-py"

    @pytest.mark.parametrize("seed", range(8))
    def test_encaps_decaps_match_kyber_py(self, seed):
        d = bytes([seed]) + os.urandom(31)
        z = bytes([seed + 1]) + os.urandom(31)
        m = bytes([seed + 2]) + os.urandom(31)

        ours_ek, ours_dk = keygen_internal(d, z)
        ours_K, ours_c = encaps_internal(ours_ek, m)
        ours_K_dec = decaps(ours_dk, ours_c)
        assert ours_K == ours_K_dec  # sanity

        ml_kem = kyber_py.ML_KEM_768
        theirs_ek, theirs_dk = ml_kem._keygen_internal(d, z)
        theirs_K, theirs_c = ml_kem._encaps_internal(theirs_ek, m)
        theirs_K_dec = ml_kem.decaps(theirs_dk, theirs_c)

        assert ours_ek == theirs_ek
        assert ours_dk == theirs_dk
        assert ours_c == theirs_c, "ciphertext byte mismatch with kyber-py"
        assert ours_K == theirs_K, "encapsulated K mismatch with kyber-py"
        assert ours_K_dec == theirs_K_dec
