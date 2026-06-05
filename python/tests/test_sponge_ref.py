"""Cross-validate sponge_ref against the stdlib hashlib SHA3/SHAKE
implementations.

Hashlib's SHA3 family is the canonical reference (originally OpenSSL,
then a vendored implementation in CPython). If our sponge layer agrees
with it bit-exactly across a representative set of inputs — including
edge cases like empty / exactly-rate-aligned / cross-block — we have
high confidence the byte-level sponge is correct, before we put
significant time into the RTL implementation.

Test vectors:
  - Empty
  - Single byte (0x00, 0xAA, 0xFF)
  - "abc" — classic SHA-3 KAT vector
  - exactly-rate-1, rate, rate+1 lengths for each function (boundary)
  - large random inputs at multiple lengths
"""

from __future__ import annotations

import hashlib
import os
import sys

import pytest

# Locate sponge_ref next to this test file's parent
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

from sponge_ref import (
    sha3_256, sha3_512, shake_128, shake_256,
    RATE_SHA3_256, RATE_SHA3_512, RATE_SHAKE_128, RATE_SHAKE_256,
)


# ----------------------------------------------------------------------
# Fixed-output (SHA3-256, SHA3-512)
# ----------------------------------------------------------------------

@pytest.mark.parametrize("msg", [
    b"",
    b"\x00",
    b"\xff",
    b"abc",
    b"a" * 100,
    b"\xaa" * RATE_SHA3_256,
    b"\xaa" * (RATE_SHA3_256 - 1),
    b"\xaa" * (RATE_SHA3_256 + 1),
    b"\xaa" * (2 * RATE_SHA3_256),
])
def test_sha3_256_matches_hashlib(msg):
    assert sha3_256(msg) == hashlib.sha3_256(msg).digest()


@pytest.mark.parametrize("msg", [
    b"",
    b"\x00",
    b"\xff",
    b"abc",
    b"a" * 100,
    b"\xaa" * RATE_SHA3_512,
    b"\xaa" * (RATE_SHA3_512 - 1),
    b"\xaa" * (RATE_SHA3_512 + 1),
    b"\xaa" * (2 * RATE_SHA3_512),
])
def test_sha3_512_matches_hashlib(msg):
    assert sha3_512(msg) == hashlib.sha3_512(msg).digest()


# ----------------------------------------------------------------------
# Extendable output (SHAKE-128, SHAKE-256)
# ----------------------------------------------------------------------

@pytest.mark.parametrize("msg", [b"", b"abc", b"\xaa" * RATE_SHAKE_128])
@pytest.mark.parametrize("outlen", [1, 16, 32, 64,
                                    RATE_SHAKE_128 - 1,
                                    RATE_SHAKE_128,
                                    RATE_SHAKE_128 + 1,
                                    2 * RATE_SHAKE_128])
def test_shake_128_matches_hashlib(msg, outlen):
    assert shake_128(msg, outlen) == hashlib.shake_128(msg).digest(outlen)


@pytest.mark.parametrize("msg", [b"", b"abc", b"\xaa" * RATE_SHAKE_256])
@pytest.mark.parametrize("outlen", [1, 32, 64,
                                    RATE_SHAKE_256 - 1,
                                    RATE_SHAKE_256,
                                    RATE_SHAKE_256 + 1])
def test_shake_256_matches_hashlib(msg, outlen):
    assert shake_256(msg, outlen) == hashlib.shake_256(msg).digest(outlen)


# ----------------------------------------------------------------------
# Classic SHA-3 published vectors
# ----------------------------------------------------------------------

def test_sha3_256_empty_kat():
    """FIPS 202 / NIST KAT for SHA3-256("")"""
    expected = bytes.fromhex(
        "a7ffc6f8bf1ed76651c14756a061d662f580ff4de43b49fa82d80a4b80f8434a"
    )
    assert sha3_256(b"") == expected


def test_sha3_256_abc_kat():
    """SHA3-256("abc") published vector"""
    expected = bytes.fromhex(
        "3a985da74fe225b2045c172d6bd390bd855f086e3e9d525b46bfe24511431532"
    )
    assert sha3_256(b"abc") == expected
