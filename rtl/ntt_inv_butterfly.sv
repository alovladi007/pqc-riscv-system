// -----------------------------------------------------------------------------
// ntt_inv_butterfly.sv
//
// Single radix-2 Gentleman-Sande butterfly for Kyber's inverse NTT.
//
//   in:  a, b, zeta_mont   (zeta in Montgomery form: zeta * R mod q)
//   out: a', b'  where
//         t  = a                                         <- just capture
//         a' = (a + b)              mod q                <- the sum
//         b' = Mont(zeta_mont * (b - a))                 <- mont-reduced product
//
// Two-cycle pipelined — same shape as ntt_butterfly so the engine FSM
// can drive either with the same handshake (valid_in / valid_out).
//
// Verified against python/ntt_ref.py:inv_ntt() in tb/test_ntt_engine.py
// (the full inverse engine wraps this and includes the final n^-1 scale).
// -----------------------------------------------------------------------------

`default_nettype none

module ntt_inv_butterfly #(
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
    // Stage 0: capture a+b and zeta * (b - a)
    //
    // a + b uses a 13-bit sum then a single conditional subtract of Q.
    // b - a is computed as (b - a) mod q (add Q if it underflows). The
    // 12x12 -> 24-bit product fires here.
    // ---------------------------------------------------------------------
    logic [12:0]   ab_sum;
    logic [11:0]   ab_sum_minus_q;
    logic [11:0]   ab_sum_modq;
    logic [11:0]   b_minus_a_modq;

    assign ab_sum         = {1'b0, a} + {1'b0, b};
    assign ab_sum_minus_q = ab_sum[11:0] - Q[11:0];
    assign ab_sum_modq    = (ab_sum >= 13'(Q)) ? ab_sum_minus_q : ab_sum[11:0];

    assign b_minus_a_modq = (b >= a) ? (b - a) : (b + Q[11:0] - a);

    logic [11:0]   a_plus_b_s1;
    logic [23:0]   zeta_diff_s1;
    logic          valid_s1;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_plus_b_s1  <= '0;
            zeta_diff_s1 <= '0;
            valid_s1     <= 1'b0;
        end else begin
            a_plus_b_s1  <= ab_sum_modq;
            zeta_diff_s1 <= zeta * b_minus_a_modq;
            valid_s1     <= valid_in;
        end
    end

    // ---------------------------------------------------------------------
    // Stage 1: Montgomery reduce zeta * (b - a)
    //   u = (zeta_diff_low * MONT_Q_INV_NEG) mod 2^16
    //   t = (zeta_diff + u*Q) >> R_BITS
    //   if (t >= Q) t -= Q
    // ---------------------------------------------------------------------
    localparam int unsigned T_PRE_W = 28;

    logic [MONT_R_BITS-1:0]    u;
    logic [MONT_R_BITS*2-1:0]  u_mul;
    logic [T_PRE_W-1:0]        t_pre;
    logic [11:0]               t_red_lo;
    logic [11:0]               t_red_minus_q;
    logic [11:0]               t_red;

    assign u_mul         = zeta_diff_s1[MONT_R_BITS-1:0] * MONT_Q_INV_NEG[MONT_R_BITS-1:0];
    assign u             = u_mul[MONT_R_BITS-1:0];
    assign t_pre         = T_PRE_W'(zeta_diff_s1) + T_PRE_W'(u * Q[11:0]);
    assign t_red_lo      = t_pre[T_PRE_W-1:MONT_R_BITS];
    assign t_red_minus_q = t_red_lo - Q[11:0];
    assign t_red         = (t_red_lo >= Q[11:0]) ? t_red_minus_q : t_red_lo;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_out     <= '0;
            b_out     <= '0;
            valid_out <= 1'b0;
        end else begin
            a_out     <= a_plus_b_s1;
            b_out     <= t_red;
            valid_out <= valid_s1;
        end
    end

endmodule

`default_nettype wire
