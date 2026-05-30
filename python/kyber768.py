"""
ML-KEM-768 (Kyber768) per NIST FIPS 203.

Top-level functions:

  keygen_internal(d, z)             -> (ek, dk)
  encaps_internal(ek, m)            -> (K, c)
  decaps(dk, c)                     -> K

  keygen()                          -> (ek, dk)        # uses os.urandom
  encaps(ek)                        -> (K, c)          # uses os.urandom

The *_internal forms take the random seeds as arguments so the same
function reproduces NIST KAT vectors deterministically.

ML-KEM-768 parameters (k=3 variant):
  n  = 256
  q  = 3329
  k  = 3
  eta1 = 2,  eta2 = 2
  du = 10,  dv = 4

Sizes (bytes):
  ek  : 1184
  dk  : 2400
  c   : 1088
  K   : 32

Implementation discipline
-------------------------
This is the spec-following reference. Each step cites the FIPS 203
algorithm number it implements. The code is meant to be read alongside
the standard, not to be the fastest path. It is not constant-time and
not for production use.

Cross-validated against the kyber-py package (added as a dev dep in
tests/test_kyber768.py) over hundreds of random (d, z, m) triples.
"""

from __future__ import annotations
import os
from typing import List, Tuple

from mod_arith import mod_add, mod_sub
from ntt_ref import ntt, inv_ntt, ntt_mul, poly_add, poly_sub
from poly import (
    Q, N,
    compress, decompress,
    byte_encode, byte_decode,
    sample_ntt, sample_poly_cbd,
)
from sym import G, H, J, PRF, XOF


# ML-KEM-768 parameter set (FIPS 203 §4 Table 2)
K_PARAM = 3
ETA1 = 2
ETA2 = 2
DU = 10
DV = 4

# Byte sizes per Table 3
EK_SIZE = 384 * K_PARAM + 32      # 1184
DK_SIZE = 768 * K_PARAM + 96      # 2400
CT_SIZE = 32 * (DU * K_PARAM + DV)  # 1088
SS_SIZE = 32                      # K


# -----------------------------------------------------------------------------
# Internal helpers — vectors of polynomials, matrix expansion
# -----------------------------------------------------------------------------

def _generate_matrix(rho: bytes, transposed: bool) -> List[List[List[int]]]:
    """Expand matrix A_hat from seed rho via SHAKE128 rejection sampling.

    Returns a (k x k) matrix of NTT-domain polynomials. If transposed is True
    we read XOF(rho, i, j) for entry (i, j); else XOF(rho, j, i). FIPS 203
    uses the transposed form in K-PKE.Encrypt (alg 13 line 5) and the non-
    transposed form in K-PKE.KeyGen (alg 12 line 4).
    """
    mat: List[List[List[int]]] = [[None] * K_PARAM for _ in range(K_PARAM)]  # type: ignore
    for i in range(K_PARAM):
        for j in range(K_PARAM):
            if transposed:
                xof = XOF(rho, i, j)
            else:
                xof = XOF(rho, j, i)
            mat[i][j] = sample_ntt(xof)
    return mat


def _vec_ntt(v: List[List[int]]) -> List[List[int]]:
    return [ntt(p) for p in v]


def _vec_inv_ntt(v: List[List[int]]) -> List[List[int]]:
    return [inv_ntt(p) for p in v]


def _vec_add(a: List[List[int]], b: List[List[int]]) -> List[List[int]]:
    return [poly_add(x, y) for x, y in zip(a, b)]


def _matvec_mul(mat: List[List[List[int]]], v: List[List[int]]) -> List[List[int]]:
    """Matrix-vector product in NTT domain: out[i] = sum_j mat[i][j] * v[j]."""
    out: List[List[int]] = []
    for i in range(K_PARAM):
        acc = [0] * N
        for j in range(K_PARAM):
            acc = poly_add(acc, ntt_mul(mat[i][j], v[j]))
        out.append(acc)
    return out


def _inner_product(a: List[List[int]], b: List[List[int]]) -> List[int]:
    """sum_i a[i] * b[i] in NTT domain."""
    acc = [0] * N
    for x, y in zip(a, b):
        acc = poly_add(acc, ntt_mul(x, y))
    return acc


# -----------------------------------------------------------------------------
# K-PKE (the underlying public-key encryption scheme)
# -----------------------------------------------------------------------------

def _kpke_keygen(d: bytes) -> Tuple[bytes, bytes]:
    """K-PKE.KeyGen (alg 12). d is 32 bytes."""
    rho, sigma = G(d + bytes([K_PARAM]))

    # Build matrix A_hat in NTT domain
    A_hat = _generate_matrix(rho, transposed=False)

    # Sample secret s and noise e from CBD(eta1)
    n_counter = 0
    s = []
    for _ in range(K_PARAM):
        s.append(sample_poly_cbd(ETA1, PRF(ETA1, sigma, n_counter)))
        n_counter += 1
    e = []
    for _ in range(K_PARAM):
        e.append(sample_poly_cbd(ETA1, PRF(ETA1, sigma, n_counter)))
        n_counter += 1

    s_hat = _vec_ntt(s)
    e_hat = _vec_ntt(e)

    # t_hat = A_hat * s_hat + e_hat
    t_hat = _vec_add(_matvec_mul(A_hat, s_hat), e_hat)

    ek_pke = b"".join(byte_encode(12, p) for p in t_hat) + rho
    dk_pke = b"".join(byte_encode(12, p) for p in s_hat)
    return ek_pke, dk_pke


def _kpke_encrypt(ek_pke: bytes, m: bytes, r: bytes) -> bytes:
    """K-PKE.Encrypt (alg 13). m is 32 bytes (plaintext message). r is 32 bytes (randomness)."""
    # Parse ek_pke
    t_hat = [byte_decode(12, ek_pke[384 * i:384 * (i + 1)]) for i in range(K_PARAM)]
    rho = ek_pke[384 * K_PARAM:384 * K_PARAM + 32]

    A_hat_T = _generate_matrix(rho, transposed=True)

    # Sample y from CBD(eta1), e1, e2 from CBD(eta2)
    n_counter = 0
    y = []
    for _ in range(K_PARAM):
        y.append(sample_poly_cbd(ETA1, PRF(ETA1, r, n_counter)))
        n_counter += 1
    e1 = []
    for _ in range(K_PARAM):
        e1.append(sample_poly_cbd(ETA2, PRF(ETA2, r, n_counter)))
        n_counter += 1
    e2 = sample_poly_cbd(ETA2, PRF(ETA2, r, n_counter))

    y_hat = _vec_ntt(y)

    # u = NTT^-1(A_hat^T * y_hat) + e1
    u = _vec_add(_vec_inv_ntt(_matvec_mul(A_hat_T, y_hat)), e1)

    # mu = decompress_1(byte_decode_1(m))
    mu = decompress(1, byte_decode(1, m))

    # v = NTT^-1(t_hat . y_hat) + e2 + mu
    v = poly_add(poly_add(inv_ntt(_inner_product(t_hat, y_hat)), e2), mu)

    # Compress and pack
    c1 = b"".join(byte_encode(DU, compress(DU, ui)) for ui in u)
    c2 = byte_encode(DV, compress(DV, v))
    return c1 + c2


def _kpke_decrypt(dk_pke: bytes, c: bytes) -> bytes:
    """K-PKE.Decrypt (alg 14)."""
    c1_size = 32 * DU * K_PARAM
    c1, c2 = c[:c1_size], c[c1_size:]

    u_prime = [
        decompress(DU, byte_decode(DU, c1[32 * DU * i:32 * DU * (i + 1)]))
        for i in range(K_PARAM)
    ]
    v_prime = decompress(DV, byte_decode(DV, c2))
    s_hat = [byte_decode(12, dk_pke[384 * i:384 * (i + 1)]) for i in range(K_PARAM)]

    # w = v' - NTT^-1(s_hat . NTT(u'))
    w = poly_sub(v_prime, inv_ntt(_inner_product(s_hat, _vec_ntt(u_prime))))
    # m = byte_encode_1(compress_1(w))
    return byte_encode(1, compress(1, w))


# -----------------------------------------------------------------------------
# ML-KEM (FO-transformed KEM wrapping K-PKE)
# -----------------------------------------------------------------------------

def keygen_internal(d: bytes, z: bytes) -> Tuple[bytes, bytes]:
    """ML-KEM.KeyGen_internal (alg 16). d and z are each 32 bytes."""
    if len(d) != 32 or len(z) != 32:
        raise ValueError("ML-KEM keygen seeds d and z must each be 32 bytes")
    ek_pke, dk_pke = _kpke_keygen(d)
    ek = ek_pke
    dk = dk_pke + ek + H(ek) + z
    return ek, dk


def encaps_internal(ek: bytes, m: bytes) -> Tuple[bytes, bytes]:
    """ML-KEM.Encaps_internal (alg 17). m is 32 bytes (the random message)."""
    if len(ek) != EK_SIZE:
        raise ValueError(f"ek must be {EK_SIZE} bytes, got {len(ek)}")
    if len(m) != 32:
        raise ValueError(f"m must be 32 bytes, got {len(m)}")
    K, r = G(m + H(ek))
    c = _kpke_encrypt(ek, m, r)
    return K, c


def decaps(dk: bytes, c: bytes) -> bytes:
    """ML-KEM.Decaps (alg 18). Always returns a 32-byte key (implicit rejection)."""
    if len(dk) != DK_SIZE:
        raise ValueError(f"dk must be {DK_SIZE} bytes, got {len(dk)}")
    if len(c) != CT_SIZE:
        raise ValueError(f"c must be {CT_SIZE} bytes, got {len(c)}")

    dk_pke = dk[:384 * K_PARAM]
    ek = dk[384 * K_PARAM:768 * K_PARAM + 32]
    h = dk[768 * K_PARAM + 32:768 * K_PARAM + 64]
    z = dk[768 * K_PARAM + 64:768 * K_PARAM + 96]

    m_prime = _kpke_decrypt(dk_pke, c)
    K_prime, r_prime = G(m_prime + h)
    K_bar = J(z + c)
    c_prime = _kpke_encrypt(ek, m_prime, r_prime)
    # Constant-ish-time selection (this is a reference, not constant-time)
    if c == c_prime:
        return K_prime
    return K_bar


# -----------------------------------------------------------------------------
# Wrappers that source randomness from the OS
# -----------------------------------------------------------------------------

def keygen() -> Tuple[bytes, bytes]:
    return keygen_internal(os.urandom(32), os.urandom(32))


def encaps(ek: bytes) -> Tuple[bytes, bytes]:
    return encaps_internal(ek, os.urandom(32))
