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
    logic [MONT_R_BITS-1:0] u;
    logic [31:0]            t_pre;
    logic [11:0]            t_red;
    logic [12:0]            sum, diff;
    logic [11:0]            a_plus_t, a_minus_t;

    assign u         = (zeta_b_s1[MONT_R_BITS-1:0] * MONT_Q_INV_NEG[MONT_R_BITS-1:0]);
    assign t_pre     = zeta_b_s1 + u * Q[11:0];
    assign t_red     = (t_pre[27:MONT_R_BITS] >= Q[11:0])
                       ? (t_pre[27:MONT_R_BITS] - Q[11:0])
                       : t_pre[27:MONT_R_BITS];

    assign sum  = a_s1 + t_red;
    assign diff = (a_s1 >= t_red) ? (a_s1 - t_red) : (a_s1 + Q[11:0] - t_red);

    assign a_plus_t  = (sum  >= Q[12:0]) ? (sum  - Q[12:0]) : sum[11:0];
    assign a_minus_t = diff[11:0];

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
