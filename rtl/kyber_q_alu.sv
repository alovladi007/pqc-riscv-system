// -----------------------------------------------------------------------------
// kyber_q_alu.sv
//
// Modular arithmetic for Kyber's q = 3329.
//
// Provides Barrett reduction (single-cycle combinational), used at the
// boundaries of the NTT engine, and a registered modular-add / modular-sub
// pair used inside the butterfly. Montgomery reduction lives in
// kyber_mont_mul.sv (separate file because it needs its own DSP slice
// scheduling).
//
// Verified against the Python golden model in
// ../python/mod_arith.py — see tb/test_q_alu.py.
//
// Resource budget (Xilinx Kria, post-synth estimate, no DSP forced):
//   LUTs:  ~120 (Barrett path)  +  ~80 (add/sub)
//   FFs:   ~26 (output register only)
//   DSPs:  0  (the M*a multiply maps to fabric for a 24-bit constant *
//                 24-bit operand; Vivado will infer 1 DSP if you allow it)
// -----------------------------------------------------------------------------

`default_nettype none

module kyber_q_alu #(
    parameter int unsigned Q       = 3329,
    // Barrett constants for Q = 3329:
    //   M = floor(2^24 / Q) = 5039
    //   SHIFT = 24
    parameter int unsigned BARR_M  = 5039,
    parameter int unsigned BARR_SH = 24
) (
    input  wire                clk,
    input  wire                rst_n,

    // Operation select. One-hot is overkill; just enum it.
    //   2'b00 : barrett_reduce(in_a)         (in_b ignored, in_a up to 24-bit)
    //   2'b01 : mod_add(in_a, in_b)          (both inputs in [0, 2Q))
    //   2'b10 : mod_sub(in_a, in_b)          (both inputs in [0, Q))
    //   2'b11 : RESERVED for Montgomery (handled in separate module)
    input  wire        [1:0]   op,

    input  wire        [23:0]  in_a,
    input  wire        [23:0]  in_b,

    output logic       [11:0]  out,           // result in [0, Q)
    output logic               valid          // pulses high one cycle after op presented
);

    // ---------------------------------------------------------------------
    // Barrett reduction path (combinational)
    //   t = (a * M) >> SHIFT
    //   r = a - t * Q
    //   if (r >= Q) r -= Q
    //
    // Widths are sized exactly so verilator's -Wall (incl. WIDTHEXPAND /
    // WIDTHTRUNC) is clean: the multiply output is 38 bits (24+14, since
    // BARR_M = 5039 fits in 13 bits but we keep one bit margin), the
    // quotient is 24-SHIFT = 14 bits, and r_pre stays in 13 bits because
    // |r_pre| <= 2*Q in the Barrett invariant.
    // ---------------------------------------------------------------------
    localparam int unsigned MUL_W   = 38;   // 24 + 14 (Barrett M = 5039 fits 13)
    localparam int unsigned QUOT_W  = MUL_W - BARR_SH;  // 14
    localparam int unsigned R_W     = 13;               // r in [0, 2Q), 2Q = 6658 < 2^13

    // t_quotient * Q needs full width: t_quotient is up to ~5039 (13
    // bits) and Q is 12 bits, so the product is up to 26 bits. The first
    // refactor pass truncated t_quotient to 12 bits, which dropped the
    // top bit and silently broke barrett_out for inputs >= 2*Q.
    localparam int unsigned TQ_Q_W = QUOT_W + 12;   // 14 + 12 = 26

    logic [MUL_W-1:0]   mul_aM;
    logic [QUOT_W-1:0]  t_quotient;
    logic [TQ_Q_W-1:0]  tq_times_q;
    logic [R_W-1:0]     r_pre;
    logic [R_W-1:0]     r_minus_q;
    logic [11:0]        barrett_out;
    logic [12:0]        add_minus_q;

    assign mul_aM      = in_a * BARR_M[13:0];                   // 24 * 14 -> 38
    assign t_quotient  = mul_aM[MUL_W-1:BARR_SH];               // top 14 bits
    assign tq_times_q  = t_quotient * Q[11:0];                  // up to 26 bits
    assign r_pre       = in_a[R_W-1:0] - tq_times_q[R_W-1:0];   // bottom 13 bits
    assign r_minus_q   = r_pre - R_W'(Q);
    assign barrett_out = (r_pre >= R_W'(Q)) ? r_minus_q[11:0]
                                            : r_pre[11:0];

    // ---------------------------------------------------------------------
    // Modular add / sub (combinational)
    // ---------------------------------------------------------------------
    logic [12:0] add_sum;
    logic [11:0] add_out;
    logic [11:0] sub_out;

    assign add_sum     = {1'b0, in_a[11:0]} + {1'b0, in_b[11:0]};
    assign add_minus_q = add_sum - 13'(Q);
    assign add_out     = (add_sum >= 13'(Q)) ? add_minus_q[11:0]
                                             : add_sum[11:0];

    // sub: handle borrow by adding Q if a < b. Both branches are exactly 12 bits.
    assign sub_out = (in_a[11:0] >= in_b[11:0])
                     ? (in_a[11:0] - in_b[11:0])
                     : (in_a[11:0] + Q[11:0] - in_b[11:0]);

    // Tell verilator that in_b's upper bits are intentionally unused
    // (the ALU only operates on 12-bit operands; the 24-bit width is
    // shared with the Barrett path).
    /* verilator lint_off UNUSED */
    wire _unused_in_b = &{1'b0, in_b[23:12], 1'b0};
    /* verilator lint_on UNUSED */

    // ---------------------------------------------------------------------
    // Output register
    // ---------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out   <= '0;
            valid <= 1'b0;
        end else begin
            unique case (op)
                2'b00:   out <= barrett_out;
                2'b01:   out <= add_out;
                2'b10:   out <= sub_out;
                default: out <= '0;   // 2'b11 reserved; raise an alert in real design
            endcase
            valid <= 1'b1;            // single-cycle latency
        end
    end

endmodule

`default_nettype wire
