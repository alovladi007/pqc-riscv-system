// -----------------------------------------------------------------------------
// ntt_butterfly.sv
//
// Single radix-2 Cooley-Tukey butterfly for Kyber's NTT.
//
//   in:  a, b, zeta
//   out: a', b'  where
//         t  = (zeta * b) mod q       <- 1 DSP slice (Montgomery)
//         a' = (a + t)   mod q
//         b' = (a - t)   mod q
//
// Two-cycle pipelined: cycle 0 captures inputs and fires the multiplier;
// cycle 1 does the Montgomery reduce and the add/sub. valid_out is
// asserted on cycle 2.
//
// Verified against python/ntt_ref.py (single-butterfly extraction in
// tb/test_butterfly.py).
// -----------------------------------------------------------------------------

`default_nettype none

module ntt_butterfly #(
    parameter int unsigned Q             = 3329,
    parameter int unsigned MONT_Q_INV_NEG = 3327,    // -q^-1 mod 2^16
    parameter int unsigned MONT_R_BITS    = 16
) (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               valid_in,

    input  wire        [11:0] a,
    input  wire        [11:0] b,
    input  wire        [11:0] zeta,

    output logic       [11:0] a_out,
    output logic       [11:0] b_out,
    output logic              valid_out
);

    // ---------------------------------------------------------------------
    // Stage 0: capture inputs, fire 12x12 -> 24-bit multiply
    // ---------------------------------------------------------------------
    logic [11:0] a_s1;
    logic [23:0] zeta_b_s1;
    logic        valid_s1;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_s1      <= '0;
            zeta_b_s1 <= '0;
            valid_s1  <= 1'b0;
        end else begin
            a_s1      <= a;
            zeta_b_s1 <= zeta * b;
            valid_s1  <= valid_in;
        end
    end

    // ---------------------------------------------------------------------
    // Stage 1: Montgomery-reduce zeta*b, then add/sub
    //   u = (a_low * MONT_Q_INV_NEG) & (R - 1)
    //   t = (a + u*Q) >> R_BITS
    //   if (t >= Q) t -= Q
    // ---------------------------------------------------------------------
    // Explicit width sizing for verilator -Wall.
    //   u_mul = (zeta_b_low * q_inv_neg_low) is a 16x16 -> 32 bit product;
    //   we keep only the low 16 (mod 2^16). t_red_pre is the sum at full
    //   width (24 + 16) so the carry into the high bits is captured.
    localparam int unsigned T_PRE_W = 28;  // zeta_b is 24-bit; u*Q adds < 4 bits

    logic [MONT_R_BITS-1:0]    u;
    logic [MONT_R_BITS*2-1:0]  u_mul;
    logic [T_PRE_W-1:0]        t_pre;
    logic [11:0]               t_red_lo;
    logic [11:0]               t_red_minus_q;
    logic [11:0]               t_red;
    logic [12:0]               sum, diff;
    logic [11:0]               sum_minus_q;
    logic [11:0]               a_plus_t, a_minus_t;

    assign u_mul     = zeta_b_s1[MONT_R_BITS-1:0] * MONT_Q_INV_NEG[MONT_R_BITS-1:0];
    assign u         = u_mul[MONT_R_BITS-1:0];
    // t_pre = zeta_b + u*q, all widened to T_PRE_W bits explicitly.
    assign t_pre     = T_PRE_W'(zeta_b_s1) + T_PRE_W'(u * Q[11:0]);
    assign t_red_lo  = t_pre[T_PRE_W-1:MONT_R_BITS];
    assign t_red_minus_q = t_red_lo - Q[11:0];
    assign t_red     = (t_red_lo >= Q[11:0]) ? t_red_minus_q : t_red_lo;

    assign sum  = {1'b0, a_s1} + {1'b0, t_red};
    assign diff = (a_s1 >= t_red)
                  ? {1'b0, a_s1 - t_red}
                  : {1'b0, a_s1 + Q[11:0] - t_red};

    assign sum_minus_q = sum[11:0] - Q[11:0];
    assign a_plus_t    = (sum >= 13'(Q)) ? sum_minus_q : sum[11:0];
    assign a_minus_t   = diff[11:0];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_out     <= '0;
            b_out     <= '0;
            valid_out <= 1'b0;
        end else begin
            a_out     <= a_plus_t;
            b_out     <= a_minus_t;
            valid_out <= valid_s1;
        end
    end

endmodule

`default_nettype wire
