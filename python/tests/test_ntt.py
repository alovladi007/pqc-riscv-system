"""Tests for the NTT reference.

The acceptance test that matters: ntt(inv_ntt(x)) == x for random inputs,
and ntt_mul of NTT(a) and NTT(b) corresponds to schoolbook multiplication
of a and b in the ring Z_q[X]/(X^256 + 1).
"""

import random
import pytest

from ntt_ref import N, Q, ntt, inv_ntt, ntt_mul, poly_add, poly_sub


def _random_poly(seed=0):
    rng = random.Random(seed)
    return [rng.randrange(Q) for _ in range(N)]


def _schoolbook_mul(a, b):
    """Reference multiplication in Z_q[X]/(X^N + 1) — quadratic, used as
    the golden model for ntt_mul.
    """
    result = [0] * N
    for i in range(N):
        for j in range(N):
            k = (i + j) % N
            sign = -1 if (i + j) >= N else 1
            result[k] = (result[k] + sign * a[i] * b[j]) % Q
    return result


class TestNTT:

    @pytest.mark.parametrize("seed", range(10))
    def test_inverse(self, seed):
        a = _random_poly(seed)
        assert inv_ntt(ntt(a)) == a

    def test_zero(self):
        z = [0] * N
        assert ntt(z) == z
        assert inv_ntt(z) == z

    def test_constant(self):
        # Constant polynomial: NTT(c) is c times the identity vector times
        # whatever the Kyber incomplete-NTT structure dictates — just check
        # round-trip.
        c = [42] * N
        assert inv_ntt(ntt(c)) == c

    @pytest.mark.parametrize("seed", range(5))
    def test_ntt_mul_matches_schoolbook(self, seed):
        rng = random.Random(seed)
        # Use small coefficients to keep schoolbook reference fast and
        # representative of post-CBD distributions.
        a = [rng.randrange(-3, 4) % Q for _ in range(N)]
        b = [rng.randrange(-3, 4) % Q for _ in range(N)]

        a_ntt = ntt(a)
        b_ntt = ntt(b)
        prod_ntt = ntt_mul(a_ntt, b_ntt)
        prod = inv_ntt(prod_ntt)
        ref = _schoolbook_mul(a, b)
        assert prod == ref


class TestPolyOps:

    @pytest.mark.parametrize("seed", range(5))
    def test_add_subtract(self, seed):
        rng = random.Random(seed)
        a = [rng.randrange(Q) for _ in range(N)]
        b = [rng.randrange(Q) for _ in range(N)]
        c = poly_add(a, b)
        a_back = poly_sub(c, b)
        assert a_back == a
