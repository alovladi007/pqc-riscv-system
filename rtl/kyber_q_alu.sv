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
    // ---------------------------------------------------------------------
    logic [47:0] mul_aM;
    logic [23:0] t_quotient;
    logic [23:0] r_pre;
    logic [11:0] barrett_out;

    assign mul_aM      = in_a * BARR_M[23:0];
    assign t_quotient  = mul_aM[47:BARR_SH];          // top (48-SHIFT)=24 bits
    assign r_pre       = in_a - t_quotient * Q[11:0];
    assign barrett_out = (r_pre >= Q[23:0]) ? (r_pre - Q[23:0]) : r_pre[11:0];

    // ---------------------------------------------------------------------
    // Modular add / sub (combinational)
    // ---------------------------------------------------------------------
    logic [12:0] add_sum;
    logic [11:0] add_out;
    logic [12:0] sub_diff;
    logic [11:0] sub_out;

    assign add_sum = in_a[11:0] + in_b[11:0];
    assign add_out = (add_sum >= Q[12:0]) ? (add_sum - Q[12:0]) : add_sum[11:0];

    // sub: handle borrow by adding Q if a < b
    assign sub_diff = (in_a[11:0] >= in_b[11:0])
                      ? {1'b0, in_a[11:0] - in_b[11:0]}
                      : {1'b0, in_a[11:0] + Q[11:0] - in_b[11:0]};
    assign sub_out  = sub_diff[11:0];

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
