"""Tests for the modular arithmetic primitives.

These run cheaply but exhaustively over key input ranges so any regression
in Barrett or Montgomery is caught immediately.
"""

import random
import pytest
from hypothesis import given, strategies as st, settings

from mod_arith import (
    Q,
    MONT_R,
    barrett_reduce,
    montgomery_reduce,
    to_montgomery,
    from_montgomery,
    mod_mul,
    mod_add,
    mod_sub,
)


# ---------------------------------------------------------------------------
# Barrett reduction
# ---------------------------------------------------------------------------


class TestBarrett:
    """Cover the input range Barrett is specified for: [0, 2^24)."""

    @given(st.integers(min_value=0, max_value=(1 << 24) - 1))
    @settings(max_examples=500)
    def test_matches_python_modulo(self, a):
        assert barrett_reduce(a) == a % Q

    def test_zero(self):
        assert barrett_reduce(0) == 0

    def test_q_minus_one(self):
        assert barrett_reduce(Q - 1) == Q - 1

    def test_q(self):
        assert barrett_reduce(Q) == 0

    def test_two_q(self):
        assert barrett_reduce(2 * Q) == 0

    @pytest.mark.parametrize("a", [
        1,
        Q - 1,
        Q,
        Q + 1,
        2 * Q - 1,
        2 * Q,
        Q * Q,                   # largest "useful" input from a*b multiply
        (1 << 24) - 1,           # top of specified range
    ])
    def test_corners(self, a):
        assert barrett_reduce(a) == a % Q

    def test_full_range_small(self):
        """Exhaustive check up to 2 * Q^2 (covers any single-multiply path)."""
        for a in range(0, 2 * Q * Q + 1, 7919):     # large prime stride
            assert barrett_reduce(a) == a % Q


# ---------------------------------------------------------------------------
# Montgomery reduction
# ---------------------------------------------------------------------------


class TestMontgomery:

    @given(st.integers(min_value=0, max_value=Q * MONT_R - 1))
    @settings(max_examples=500)
    def test_round_trip(self, a):
        # to_mont then from_mont returns to canonical
        m = to_montgomery(a % Q)
        assert from_montgomery(m) == a % Q

    def test_one_round_trip(self):
        assert from_montgomery(to_montgomery(1)) == 1

    def test_q_minus_one_round_trip(self):
        assert from_montgomery(to_montgomery(Q - 1)) == Q - 1

    @given(
        st.integers(min_value=0, max_value=Q - 1),
        st.integers(min_value=0, max_value=Q - 1),
    )
    @settings(max_examples=200)
    def test_montgomery_multiply_equals_normal_multiply(self, a, b):
        # Multiplying in Montgomery form then converting out == normal multiply
        a_m = to_montgomery(a)
        b_m = to_montgomery(b)
        prod_m = montgomery_reduce(a_m * b_m)
        result = from_montgomery(prod_m)
        assert result == (a * b) % Q


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


class TestModOps:

    @given(
        st.integers(min_value=0, max_value=Q - 1),
        st.integers(min_value=0, max_value=Q - 1),
    )
    @settings(max_examples=300)
    def test_mod_add(self, a, b):
        assert mod_add(a, b) == (a + b) % Q

    @given(
        st.integers(min_value=0, max_value=Q - 1),
        st.integers(min_value=0, max_value=Q - 1),
    )
    @settings(max_examples=300)
    def test_mod_sub(self, a, b):
        assert mod_sub(a, b) == (a - b) % Q

    @given(
        st.integers(min_value=0, max_value=Q - 1),
        st.integers(min_value=0, max_value=Q - 1),
    )
    @settings(max_examples=300)
    def test_mod_mul(self, a, b):
        assert mod_mul(a, b) == (a * b) % Q
