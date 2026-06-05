// -----------------------------------------------------------------------------
// ntt_engine.sv
//
// Forward + inverse NTT engine for Kyber's n=256, q=3329 incomplete NTT.
//
// Self-contained: holds the 256-coefficient polynomial in an internal
// register array, exposes a load port and a read port. On `start`:
//
//   - inverse=0 -> runs the 7-stage in-place forward NTT (Cooley-Tukey
//     butterfly) with twiddle ROM indexed k=1..127, length=128 halving.
//   - inverse=1 -> runs the 7-stage in-place inverse NTT (Gentleman-Sande
//     butterfly) with twiddle ROM indexed k=127..1, length=2 doubling,
//     followed by a final scaling pass mem[j] <- f_inv * mem[j] mod q.
//
// Verified against python/ntt_ref.py:ntt() and inv_ntt() in
// tb/test_ntt_engine.py.
//
// Phase 3a shipped the forward path. Phase 3c adds the inverse path
// and the final scaling pass.
// -----------------------------------------------------------------------------

`default_nettype none

module ntt_engine #(
    parameter int unsigned Q      = 3329,
    parameter int unsigned N      = 256,
    parameter int unsigned COEF_W = 12,
    parameter int unsigned ZETA   = 17,           // 256th root of unity mod Q
    parameter int unsigned MONT_R_MOD_Q = 2285,   // R = 2^16 mod Q; pre-scales
                                                  // the twiddle ROM into
                                                  // Montgomery form so the
                                                  // butterfly produces canonical
                                                  // output after Mont-reduce.
    parameter int unsigned MONT_F_INV  = 512      // f_inv * R mod Q,
                                                  // where f_inv = n^-1 mod Q
                                                  //              = 3303 for
                                                  //              n=256, q=3329.
                                                  // 3303 * 2285 mod 3329 = 512.
                                                  // Used by the final scaling
                                                  // pass on the inverse path.
) (
    input  wire                  clk,
    input  wire                  rst_n,

    // Control
    input  wire                  start,    // pulse high to begin transform
    input  wire                  inverse,  // 0 = forward NTT, 1 = inverse NTT
    output logic                 busy,
    output logic                 done,     // pulses high one cycle when complete

    // Polynomial load port (testbench writes 256 coeffs before `start`)
    input  wire                       load_en,
    input  wire  [$clog2(N)-1:0]      load_addr,
    input  wire  [COEF_W-1:0]         load_data,

    // Polynomial readout port (registered; valid after `done`)
    input  wire  [$clog2(N)-1:0]      read_addr,
    output logic [COEF_W-1:0]         read_data
);

    // ---------------------------------------------------------------------
    // Twiddle ROM: zetas[k] = ZETA^br7(k) * R mod Q, for k in [0, 128).
    // Bit-reversed and pre-scaled into Montgomery form at elaboration.
    // ---------------------------------------------------------------------
    function automatic [11:0] zeta_value(input int unsigned idx);
        int unsigned br;
        int unsigned acc;
        int unsigned base;
        int unsigned exp;
        int unsigned i;
        br = 0;
        for (i = 0; i < 7; i++) begin
            br |= ((idx >> i) & 1) << (6 - i);
        end
        acc = 1;
        base = ZETA;
        exp = br;
        while (exp != 0) begin
            if ((exp & 32'd1) != 0) acc = (acc * base) % Q;
            base = (base * base) % Q;
            exp = exp >> 1;
        end
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

    // Registered readout (cocotb-Icarus VPI hazard sidestep).
    always_ff @(posedge clk) begin
        read_data <= mem[read_addr];
    end

    // ---------------------------------------------------------------------
    // FSM
    //
    // Transform pass (7 stages × 128 butterflies = 896 butterflies):
    //   S_IDLE      : waiting for start
    //   S_READ_A    : assert read of mem[j_addr]
    //   S_READ_B    : capture a, assert read of mem[j_addr + length]
    //   S_LATCH_B   : capture b
    //   S_BF_LOAD   : drive butterfly inputs (valid_in pulses)
    //   S_BF_WAIT0  : pipeline cycle 1
    //   S_BF_WAIT1  : wait for valid_out
    //   S_WRITE_BACK: write back a_out -> mem[j], b_out -> mem[j+length]
    //   S_ADVANCE   : bump j / block / stage / k
    //                 if transform fully done:
    //                   inverse=0 -> S_DONE
    //                   inverse=1 -> S_SC_READ (start scaling)
    //
    // Scale pass (inverse only, 256 cycles wall-clock × ~6 cycles each):
    //   S_SC_READ   : assert read of mem[sj]
    //   S_SC_LATCH  : capture b_reg = mem[sj]
    //   S_SC_LOAD   : drive forward butterfly with a=0, b=coef, zeta=MONT_F_INV
    //   S_SC_WAIT0  : pipeline cycle 1
    //   S_SC_WAIT1  : wait for valid_out
    //   S_SC_WRITE  : write back a_out = f_inv * coef mod q; bump sj
    //                if sj==N: S_DONE
    //                else:     S_SC_READ
    //
    //   S_DONE      : pulse done, return to IDLE
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
        S_SC_READ    = 4'd9,
        S_SC_LATCH   = 4'd10,
        S_SC_LOAD    = 4'd11,
        S_SC_WAIT0   = 4'd12,
        S_SC_WAIT1   = 4'd13,
        S_SC_WRITE   = 4'd14,
        S_DONE       = 4'd15
    } state_e;

    state_e state, state_next;

    // Latched inverse mode (sampled at start, stays through the run)
    logic                  inverse_mode;

    // Stage counters
    logic [7:0]            length;
    logic [$clog2(N)-1:0]  start_idx;
    logic [$clog2(N)-1:0]  j;
    logic [7:0]            k;

    // Scaling-pass counter
    logic [$clog2(N):0]    sj;     // 0..N (one extra bit for the terminating compare)

    // Held operands and butterfly handshakes
    logic [COEF_W-1:0]     a_reg, b_reg;
    logic                  bf_valid_in_fwd, bf_valid_in_inv;
    logic [COEF_W-1:0]     bf_a_out_fwd, bf_b_out_fwd;
    logic [COEF_W-1:0]     bf_a_out_inv, bf_b_out_inv;
    logic                  bf_valid_out_fwd, bf_valid_out_inv;

    // Effective butterfly outputs (muxed by current mode + which is active)
    logic [COEF_W-1:0]     bf_a_out, bf_b_out;
    logic                  bf_valid_out;

    // Twiddle selector — Montgomery-form value of the active k or MONT_F_INV
    logic [COEF_W-1:0]     zeta_sel;

    // ---------------------------------------------------------------------
    // Butterfly instances. Forward is also reused for the inverse scale
    // pass (a=0, b=coef, zeta=MONT_F_INV -> a_out = f_inv * coef mod q).
    // ---------------------------------------------------------------------
    ntt_butterfly #(.Q(Q)) u_bf_fwd (
        .clk       (clk),
        .rst_n     (rst_n),
        .valid_in  (bf_valid_in_fwd),
        .a         (a_reg),
        .b         (b_reg),
        .zeta      (zeta_sel),
        .a_out     (bf_a_out_fwd),
        .b_out     (bf_b_out_fwd),
        .valid_out (bf_valid_out_fwd)
    );

    ntt_inv_butterfly #(.Q(Q)) u_bf_inv (
        .clk       (clk),
        .rst_n     (rst_n),
        .valid_in  (bf_valid_in_inv),
        .a         (a_reg),
        .b         (b_reg),
        .zeta      (zeta_sel),
        .a_out     (bf_a_out_inv),
        .b_out     (bf_b_out_inv),
        .valid_out (bf_valid_out_inv)
    );

    // Pick active butterfly outputs:
    //   - during the transform pass: forward iff inverse_mode==0, else inverse
    //   - during the scale pass: always forward (a=0, b=coef path)
    logic in_scale_pass;
    assign in_scale_pass = (state == S_SC_READ)  || (state == S_SC_LATCH)  ||
                           (state == S_SC_LOAD)  || (state == S_SC_WAIT0)  ||
                           (state == S_SC_WAIT1) || (state == S_SC_WRITE);

    always_comb begin
        if (in_scale_pass) begin
            bf_a_out     = bf_a_out_fwd;
            bf_b_out     = bf_b_out_fwd;
            bf_valid_out = bf_valid_out_fwd;
        end else if (inverse_mode) begin
            bf_a_out     = bf_a_out_inv;
            bf_b_out     = bf_b_out_inv;
            bf_valid_out = bf_valid_out_inv;
        end else begin
            bf_a_out     = bf_a_out_fwd;
            bf_b_out     = bf_b_out_fwd;
            bf_valid_out = bf_valid_out_fwd;
        end
    end

    // Twiddle / scale-factor selector
    always_comb begin
        if (in_scale_pass) begin
            zeta_sel = 12'(MONT_F_INV);
        end else begin
            zeta_sel = zetas[k[6:0]];
        end
    end

    // ---------------------------------------------------------------------
    // FSM next-state
    // ---------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= S_IDLE;
        else        state <= state_next;
    end

    // Last-stage-of-transform detector. Differs for forward vs inverse:
    //   forward done: length==2 (we've just finished the smallest-length stage)
    //   inverse done: length==128 (we've just finished the largest)
    logic last_transform_stage;
    assign last_transform_stage = inverse_mode ? (length == 8'd128)
                                               : (length == 8'd2);

    // Block-done detector: start_idx + 2*length >= N
    logic block_done;
    assign block_done = (10'({1'b0, start_idx}) + 10'({length, 1'b0})) >= 10'(N);

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
                if ((j + 1) < length[$clog2(N)-1:0]) begin
                    state_next = S_READ_A;        // next j in this block
                end else if (!block_done) begin
                    state_next = S_READ_A;        // next block in this stage
                end else if (!last_transform_stage) begin
                    state_next = S_READ_A;        // next stage
                end else if (inverse_mode) begin
                    state_next = S_SC_READ;       // begin inverse scaling
                end else begin
                    state_next = S_DONE;          // forward done
                end
            end
            // Scale pass (inverse only)
            S_SC_READ   :                    state_next = S_SC_LATCH;
            S_SC_LATCH  :                    state_next = S_SC_LOAD;
            S_SC_LOAD   :                    state_next = S_SC_WAIT0;
            S_SC_WAIT0  :                    state_next = S_SC_WAIT1;
            S_SC_WAIT1  : if (bf_valid_out)  state_next = S_SC_WRITE;
            S_SC_WRITE  : begin
                if (sj == ($clog2(N)+1)'(N - 1)) state_next = S_DONE;
                else                              state_next = S_SC_READ;
            end
            S_DONE      :                    state_next = S_IDLE;
            default     :                    state_next = S_IDLE;
        endcase
    end

    assign busy = (state != S_IDLE);
    assign done = (state == S_DONE);

    // ---------------------------------------------------------------------
    // Datapath
    // ---------------------------------------------------------------------
    logic [$clog2(N)-1:0] j_plus_length;
    assign j_plus_length = start_idx + j + length[$clog2(N)-1:0];

    logic [$clog2(N)-1:0] j_addr;
    assign j_addr = start_idx + j;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            length          <= 8'd128;
            start_idx       <= '0;
            j               <= '0;
            k               <= 8'd1;
            sj              <= '0;
            a_reg           <= '0;
            b_reg           <= '0;
            bf_valid_in_fwd <= 1'b0;
            bf_valid_in_inv <= 1'b0;
            inverse_mode    <= 1'b0;
        end else begin
            // Load port — accepted any time so the testbench can preload
            if (load_en) begin
                mem[load_addr] <= load_data;
            end

            // Reset counters at every START. Schedule depends on mode.
            if (state == S_IDLE && start) begin
                inverse_mode <= inverse;
                sj           <= '0;
                start_idx    <= '0;
                j            <= '0;
                if (inverse) begin
                    length <= 8'd2;
                    k      <= 8'd127;
                end else begin
                    length <= 8'd128;
                    k      <= 8'd1;
                end
            end

            // Transform-pass operand capture
            if (state == S_READ_A) begin
                a_reg <= mem[j_addr];
            end
            if (state == S_READ_B) begin
                b_reg <= mem[j_plus_length];
            end

            // Scale-pass operand capture: a=0, b=mem[sj]
            if (state == S_SC_READ) begin
                a_reg <= '0;
            end
            if (state == S_SC_LATCH) begin
                b_reg <= mem[sj[$clog2(N)-1:0]];
            end

            // Drive butterfly valid_in pulses. Forward butterfly is used
            // for forward transform AND for the scale pass; inverse
            // butterfly only for the inverse transform pass.
            bf_valid_in_fwd <= (state_next == S_BF_LOAD && !inverse_mode)
                            || (state_next == S_SC_LOAD);
            bf_valid_in_inv <= (state_next == S_BF_LOAD &&  inverse_mode);

            // Commit transform-pass results
            if (state == S_WRITE_BACK) begin
                mem[j_addr]        <= bf_a_out;
                mem[j_plus_length] <= bf_b_out;
            end

            // Commit scale-pass result
            if (state == S_SC_WRITE) begin
                mem[sj[$clog2(N)-1:0]] <= bf_a_out;
                sj <= sj + 1'b1;
            end

            // Transform-pass advance (forward and inverse differ in how
            // length and k evolve, but the block-traversal is the same).
            if (state == S_ADVANCE) begin
                if ((j + 1) < length[$clog2(N)-1:0]) begin
                    j <= j + 1;
                end else if (!block_done) begin
                    j         <= '0;
                    start_idx <= start_idx + (2 * length[$clog2(N)-1:0]);
                    k         <= inverse_mode ? (k - 1) : (k + 1);
                end else if (!last_transform_stage) begin
                    j         <= '0;
                    start_idx <= '0;
                    length    <= inverse_mode ? (length << 1) : (length >> 1);
                    k         <= inverse_mode ? (k - 1) : (k + 1);
                end
                // else: all transform stages done — FSM moves to S_DONE
                //       (forward) or S_SC_READ (inverse)
            end
        end
    end

endmodule

`default_nettype wire
