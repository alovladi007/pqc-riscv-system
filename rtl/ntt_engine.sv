// -----------------------------------------------------------------------------
// ntt_engine.sv  (SKELETON)
//
// Top-level iterative NTT engine for Kyber's n=256, q=3329 incomplete NTT.
// 7 stages, 128 butterflies per stage = 896 butterfly operations per NTT.
// At 2 cycles/butterfly + control overhead, target ~2k cycles for one NTT.
//
// THIS FILE IS A STAGED SKELETON. The control FSM and the twiddle-factor
// ROM scheduler are scoped here but not yet implemented — Phase 3.
//
// What's done:
//   * Module interface, parameterization
//   * Polynomial RAM read/write address generation skeleton
//   * Hooks for the butterfly instance + the zetas ROM
//
// What's planned (Phase 3):
//   * FSM controller (IDLE -> LOAD -> NTT_STAGE[0..6] -> DONE)
//   * Twiddle-factor sequencer (matches python/ntt_ref.py ZETAS table order)
//   * Inverse-NTT support (reuse the butterfly, reverse the schedule)
//   * Pipeline interlock (2-cycle butterfly latency + RAM read latency)
// -----------------------------------------------------------------------------

`default_nettype none

module ntt_engine #(
    parameter int unsigned Q = 3329,
    parameter int unsigned N = 256,
    parameter int unsigned COEF_W = 12
) (
    input  wire                  clk,
    input  wire                  rst_n,

    // Control
    input  wire                  start,
    input  wire                  inverse,        // 1 = inverse NTT, 0 = forward
    output logic                 busy,
    output logic                 done,

    // Polynomial RAM interface (Bob Smith style: dual-port BRAM)
    output logic [$clog2(N)-1:0] poly_rd_addr,
    input  wire  [COEF_W-1:0]    poly_rd_data,
    output logic [$clog2(N)-1:0] poly_wr_addr,
    output logic [COEF_W-1:0]    poly_wr_data,
    output logic                 poly_wr_en,

    // Twiddle ROM interface (precomputed ZETAS[] from python/ntt_ref.py)
    output logic [6:0]           zeta_addr,      // 128 entries
    input  wire  [COEF_W-1:0]    zeta_data
);

    // ---------------------------------------------------------------------
    // Internal state — placeholder until the control FSM lands in Phase 3.
    // ---------------------------------------------------------------------
    typedef enum logic [2:0] {
        S_IDLE   = 3'd0,
        S_LOAD   = 3'd1,
        S_STAGE  = 3'd2,
        S_DONE   = 3'd3
    } state_e;

    state_e state, state_next;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= S_IDLE;
        else        state <= state_next;
    end

    always_comb begin
        state_next = state;
        case (state)
            S_IDLE:  if (start) state_next = S_LOAD;
            S_LOAD:  state_next = S_STAGE;    // placeholder
            S_STAGE: state_next = S_DONE;     // placeholder
            S_DONE:  state_next = S_IDLE;
            default: state_next = S_IDLE;
        endcase
    end

    assign busy = (state != S_IDLE);
    assign done = (state == S_DONE);

    // ---------------------------------------------------------------------
    // Address generation — placeholders.
    // TODO(Phase 3): generate the correct read/write addresses per stage.
    // ---------------------------------------------------------------------
    assign poly_rd_addr = '0;
    assign poly_wr_addr = '0;
    assign poly_wr_data = '0;
    assign poly_wr_en   = 1'b0;
    assign zeta_addr    = '0;

    // ---------------------------------------------------------------------
    // Butterfly instance — wired but not yet driven by a real schedule.
    // ---------------------------------------------------------------------
    logic [COEF_W-1:0] bf_a, bf_b;
    logic [COEF_W-1:0] bf_a_out, bf_b_out;
    logic              bf_valid_in, bf_valid_out;

    assign bf_a        = poly_rd_data;
    assign bf_b        = poly_rd_data;       // placeholder
    assign bf_valid_in = 1'b0;                // placeholder

    ntt_butterfly #(.Q(Q)) u_bf (
        .clk       (clk),
        .rst_n     (rst_n),
        .valid_in  (bf_valid_in),
        .a         (bf_a),
        .b         (bf_b),
        .zeta      (zeta_data),
        .a_out     (bf_a_out),
        .b_out     (bf_b_out),
        .valid_out (bf_valid_out)
    );

    // suppress "unused" lint warnings while skeleton is filled in
    /* verilator lint_off UNUSED */
    wire _unused = &{1'b0, inverse, bf_a_out, bf_b_out, bf_valid_out, 1'b0};
    /* verilator lint_on UNUSED */

endmodule

`default_nettype wire
