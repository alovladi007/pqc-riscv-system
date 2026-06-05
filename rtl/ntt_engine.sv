// -----------------------------------------------------------------------------
// ntt_engine.sv
//
// Forward NTT engine for Kyber's n=256, q=3329 incomplete NTT.
//
// Self-contained: holds the 256-coefficient polynomial in an internal
// register array, exposes a load port and a read port, and runs the full
// 7-stage in-place transform on `start`. Twiddle factors (zetas[0..127])
// are baked in at elaboration from the bit-reversed index of ZETA=17.
//
// Forward only in Phase 3a. The `inverse` input is reserved and ignored
// for now; inverse NTT is Phase 3b (Gentleman-Sande butterfly needs a
// different schedule and a separate butterfly variant).
//
// Verified against python/ntt_ref.py:ntt() in tb/test_ntt_engine.py.
//
// Performance (Icarus simulation, behavioural):
//   ~10 cycles per butterfly. 128 butterflies × 7 stages ≈ 9000 cycles.
//   The point isn't raw cycle count — Phase 4's synthesis pass will pipeline
//   this further. The point at this stage is correctness.
// -----------------------------------------------------------------------------

`default_nettype none

module ntt_engine #(
    parameter int unsigned Q      = 3329,
    parameter int unsigned N      = 256,
    parameter int unsigned COEF_W = 12,
    parameter int unsigned ZETA   = 17,   // 256th root of unity mod Q
    parameter int unsigned MONT_R_MOD_Q = 2285  // R = 2^16 mod Q, used to
                                                // pre-scale the twiddle ROM
                                                // into Montgomery form so the
                                                // butterfly (which Montgomery-
                                                // reduces zeta*b internally)
                                                // produces canonical output
) (
    input  wire                  clk,
    input  wire                  rst_n,

    // Control
    input  wire                  start,    // pulse high to begin NTT
    input  wire                  inverse,  // reserved (Phase 3b); ignored
    output logic                 busy,
    output logic                 done,     // pulses high one cycle when transform completes

    // Polynomial load port (testbench writes 256 coeffs before `start`)
    input  wire                       load_en,
    input  wire  [$clog2(N)-1:0]      load_addr,
    input  wire  [COEF_W-1:0]         load_data,

    // Polynomial readout port (combinational; valid after `done`)
    input  wire  [$clog2(N)-1:0]      read_addr,
    output logic [COEF_W-1:0]         read_data
);

    // ---------------------------------------------------------------------
    // Twiddle ROM: zetas[k] = ZETA^br7(k) mod Q, for k in [0, 128).
    // zetas[0] is unused in the NTT loop (k starts at 1) but precomputed
    // anyway so address arithmetic stays simple.
    // ---------------------------------------------------------------------
    function automatic [11:0] zeta_value(input int unsigned idx);
        int unsigned br;
        int unsigned acc;
        int unsigned base;
        int unsigned exp;
        int unsigned i;
        // 7-bit bit reversal
        br = 0;
        for (i = 0; i < 7; i++) begin
            br |= ((idx >> i) & 1) << (6 - i);
        end
        // ZETA^br mod Q via repeated squaring
        acc = 1;
        base = ZETA;
        exp = br;
        while (exp != 0) begin
            if ((exp & 32'd1) != 0) acc = (acc * base) % Q;
            base = (base * base) % Q;
            exp = exp >> 1;
        end
        // Convert to Montgomery form so the butterfly's Montgomery
        // reduction of zeta_mont * b lands canonical zeta * b mod Q.
        acc = (acc * MONT_R_MOD_Q) % Q;
        zeta_value = 12'(acc);
    endfunction

    logic [COEF_W-1:0] zetas [0:127];
    initial begin
        for (int unsigned ki = 0; ki < 128; ki++) begin
            zetas[ki] = zeta_value(ki);
        end
    end

    // ---------------------------------------------------------------------
    // Polynomial storage (256 × 12 bits).
    // ---------------------------------------------------------------------
    logic [COEF_W-1:0] mem [0:N-1];

    // Registered readout. Same rationale as keccak_f1600 — the cocotb VPI
    // sampling under Icarus has trouble with comb assigns through unpacked
    // array indices, so we register the output. One-cycle read latency.
    always_ff @(posedge clk) begin
        read_data <= mem[read_addr];
    end

    // ---------------------------------------------------------------------
    // FSM
    //
    //   S_IDLE      : waiting for start
    //   S_READ_A    : assert read of mem[start_idx + j]
    //   S_READ_B    : capture a, assert read of mem[start_idx + j + length]
    //   S_LATCH_B   : capture b
    //   S_BF_LOAD   : drive butterfly inputs (valid_in pulses)
    //   S_BF_WAIT0  : pipeline cycle 1
    //   S_BF_WAIT1  : wait for valid_out (butterfly is 2-cycle pipelined)
    //   S_WRITE_BACK: write a_out -> mem[j], b_out -> mem[j+length]
    //   S_ADVANCE   : bump j / block / stage / k
    //   S_DONE      : pulse done, return to IDLE
    //
    // Schedule and indexing match python/ntt_ref.py:ntt() exactly.
    // ---------------------------------------------------------------------
    typedef enum logic [3:0] {
        S_IDLE       = 4'd0,
        S_READ_A     = 4'd1,
        S_READ_B     = 4'd2,
        S_LATCH_B    = 4'd3,
        S_BF_LOAD    = 4'd4,
        S_BF_WAIT0   = 4'd5,
        S_BF_WAIT1   = 4'd6,
        S_WRITE_BACK = 4'd7,
        S_ADVANCE    = 4'd8,
        S_DONE       = 4'd9
    } state_e;

    state_e state, state_next;

    // Stage counters. length starts at 128 and halves each stage:
    //   stage 0: length=128, 1 block of 128 butterflies, k=1
    //   stage 1: length= 64, 2 blocks of  64,            k=2..3
    //   ...
    //   stage 6: length=  2, 64 blocks of  2,            k=64..127
    //   total: 7 * 128 = 896 butterflies, k goes 1..127.
    logic [7:0]            length;
    logic [$clog2(N)-1:0]  start_idx;
    logic [$clog2(N)-1:0]  j;
    logic [7:0]            k;

    // Held operands and butterfly handshake
    logic [COEF_W-1:0]     a_reg, b_reg;
    logic                  bf_valid_in;
    logic [COEF_W-1:0]     bf_a_out, bf_b_out;
    logic                  bf_valid_out;

    // Butterfly instance
    ntt_butterfly #(.Q(Q)) u_bf (
        .clk       (clk),
        .rst_n     (rst_n),
        .valid_in  (bf_valid_in),
        .a         (a_reg),
        .b         (b_reg),
        .zeta      (zetas[k[6:0]]),
        .a_out     (bf_a_out),
        .b_out     (bf_b_out),
        .valid_out (bf_valid_out)
    );

    // -----------------------------------------------------------------
    // State register + transitions
    // -----------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= S_IDLE;
        else        state <= state_next;
    end

    always_comb begin
        state_next = state;
        unique case (state)
            S_IDLE      : if (start)        state_next = S_READ_A;
            S_READ_A    :                    state_next = S_READ_B;
            S_READ_B    :                    state_next = S_LATCH_B;
            S_LATCH_B   :                    state_next = S_BF_LOAD;
            S_BF_LOAD   :                    state_next = S_BF_WAIT0;
            S_BF_WAIT0  :                    state_next = S_BF_WAIT1;
            S_BF_WAIT1  : if (bf_valid_out)  state_next = S_WRITE_BACK;
            S_WRITE_BACK:                    state_next = S_ADVANCE;
            S_ADVANCE   : begin
                if ((j + 1) < length) begin
                    state_next = S_READ_A;        // next j in this block
                end else if ((10'({1'b0, start_idx}) + 10'({length, 1'b0})) < 10'(N)) begin
                    state_next = S_READ_A;        // next block in this stage
                end else if (length != 2) begin
                    state_next = S_READ_A;        // next stage
                end else begin
                    state_next = S_DONE;          // all 7 stages complete
                end
            end
            S_DONE      :                    state_next = S_IDLE;
            default     :                    state_next = S_IDLE;
        endcase
    end

    assign busy = (state != S_IDLE);
    assign done = (state == S_DONE);

    // -----------------------------------------------------------------
    // Datapath registers and writes
    // -----------------------------------------------------------------
    logic [$clog2(N)-1:0] j_plus_length;
    assign j_plus_length = start_idx + j + length[$clog2(N)-1:0];

    logic [$clog2(N)-1:0] j_addr;
    assign j_addr = start_idx + j;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            length      <= 8'd128;
            start_idx   <= '0;
            j           <= '0;
            k           <= 8'd1;
            a_reg       <= '0;
            b_reg       <= '0;
            bf_valid_in <= 1'b0;
        end else begin
            // Load port — always accept, no busy gate, so the testbench
            // can preload the polynomial cleanly before pulsing start.
            if (load_en) begin
                mem[load_addr] <= load_data;
            end

            // Reset counters at every START
            if (state == S_IDLE && start) begin
                length      <= 8'd128;
                start_idx   <= '0;
                j           <= '0;
                k           <= 8'd1;
            end

            // Capture operands
            if (state == S_READ_A) begin
                a_reg <= mem[j_addr];
            end
            if (state == S_READ_B) begin
                b_reg <= mem[j_plus_length];
            end

            // Pulse valid_in for one cycle when entering S_BF_LOAD
            bf_valid_in <= (state_next == S_BF_LOAD);

            // Commit butterfly results
            if (state == S_WRITE_BACK) begin
                mem[j_addr]         <= bf_a_out;
                mem[j_plus_length]  <= bf_b_out;
            end

            // Bump counters
            if (state == S_ADVANCE) begin
                if ((j + 1) < length) begin
                    j <= j + 1;
                end else if ((10'({1'b0, start_idx}) + 10'({length, 1'b0})) < 10'(N)) begin
                    j         <= '0;
                    start_idx <= start_idx + (2 * length[$clog2(N)-1:0]);
                    k         <= k + 1;
                end else if (length != 2) begin
                    j         <= '0;
                    start_idx <= '0;
                    length    <= length >> 1;
                    k         <= k + 1;
                end
                // else: all done — FSM moves to S_DONE
            end
        end
    end

    // suppress unused: `inverse` reserved for Phase 3b
    /* verilator lint_off UNUSED */
    wire _unused = &{1'b0, inverse, 1'b0};
    /* verilator lint_on UNUSED */

endmodule

`default_nettype wire
