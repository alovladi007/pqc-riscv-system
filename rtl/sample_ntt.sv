// -----------------------------------------------------------------------------
// sample_ntt.sv
//
// Kyber matrix-A polynomial sampler. Wraps shake_128 and runs the
// rejection-sample loop from FIPS 203 §4.2.2 / Avanzi et al §1.5.1:
//
//   for each 3-byte group (b0, b1, b2) from the SHAKE-128 stream:
//       d1 = b0 | ((b1 & 0x0F) << 8)            (low 12 bits)
//       d2 = (b1 >> 4) | (b2 << 4)              (high 12 bits)
//       if d1 < q: accept
//       if d2 < q and not done: accept
//   until 256 coefficients accepted.
//
// Interface:
//   start          -> pulse high to begin
//   seed_*         -> byte stream of the 34-byte ρ‖j‖i seed; flow-controlled
//                     via seed_ready (passthrough to shake_128.in_ready)
//   done           -> pulses high one cycle when 256 coefficients ready
//   read_addr/data -> registered output port for the 256 12-bit coefs
//
// Throughput / queueing
// ---------------------
// SHAKE-128 produces ≤ 1 byte per cycle (paused during permutes). The
// rejection loop processes a triple in 3 cycles and produces 0, 1, or 2
// accepts; with q = 3329 the expected acceptance rate is ~81%, so on
// average 1.62 accepts per triple = 0.54 accepts/cycle. coef_mem has a
// single write port (1 accept/cycle max). To stay within that, the
// architecture writes d1 on the byte-2 cycle directly, and queues d2 in
// a 1-slot register `d2_pending`. d2 commits at the very NEXT cycle —
// always a "byte-0-of-next-triple" cycle or a permute-paused cycle, so
// no collision with d1. The next d2 enqueue (at byte-2 of triple B) is
// guaranteed to find the queue empty because byte-0-of-B preceded
// byte-2-of-B by 2 cycles, draining the previous d2.
//
// Verified against python/sponge_ref.sample_ntt_from_seed.
// -----------------------------------------------------------------------------

`default_nettype none

module sample_ntt #(
    parameter int unsigned Q         = 3329,
    parameter int unsigned N         = 256,
    parameter int unsigned XOF_BYTES = 1024
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        start,

    // Seed input stream (forwarded to shake_128)
    input  wire        seed_valid,
    input  wire [7:0]  seed_byte,
    input  wire        seed_last,
    output logic       seed_ready,

    output logic       done,

    // Coefficient output (registered, mirrors ntt_engine's interface)
    input  wire [$clog2(N)-1:0] read_addr,
    output logic [11:0] read_data
);

    // ---------------------------------------------------------------------
    // SHAKE-128 instance
    // ---------------------------------------------------------------------
    logic         xof_start;
    logic [15:0]  xof_bytes_req;
    logic         xof_in_valid;
    logic [7:0]   xof_in_byte;
    logic         xof_in_last;
    logic         xof_in_ready;
    logic         xof_out_valid;
    logic [7:0]   xof_out_byte;
    logic         xof_done;

    assign xof_bytes_req = 16'(XOF_BYTES);
    assign xof_in_valid  = seed_valid;
    assign xof_in_byte   = seed_byte;
    assign xof_in_last   = seed_last;
    assign seed_ready    = xof_in_ready;

    shake_128 u_xof (
        .clk           (clk),
        .rst_n         (rst_n),
        .start         (xof_start),
        .out_bytes_req (xof_bytes_req),
        .in_valid      (xof_in_valid),
        .in_byte       (xof_in_byte),
        .in_last       (xof_in_last),
        .in_ready      (xof_in_ready),
        .out_valid     (xof_out_valid),
        .out_byte      (xof_out_byte),
        .done          (xof_done)
    );

    // ---------------------------------------------------------------------
    // Coefficient memory + registered read port
    // ---------------------------------------------------------------------
    logic [11:0] coef_mem [0:N-1];

    always_ff @(posedge clk) begin
        read_data <= coef_mem[read_addr];
    end

    // ---------------------------------------------------------------------
    // Triple-byte processing
    // ---------------------------------------------------------------------
    logic [7:0]  buf0, buf1;
    logic [1:0]  byte_in_triple;
    logic [8:0]  accepted_count;       // 0..N
    logic        d2_pending;
    logic [11:0] d2_value;

    // Width-explicit combinational extracts. byte_in_triple==2 means
    // buf0, buf1 hold bytes 0 and 1; the wire xof_out_byte carries byte 2.
    logic [11:0] d1_calc, d2_calc;
    assign d1_calc = {4'b0, buf0} | ({8'b0, buf1[3:0]} << 8);
    assign d2_calc = {8'b0, buf1[7:4]} | ({4'b0, xof_out_byte} << 4);

    logic d1_accept, d2_accept;
    assign d1_accept = (d1_calc < 12'(Q));
    assign d2_accept = (d2_calc < 12'(Q));

    // Pre-computed accepted_count + 1 so the part-select indexing in the
    // datapath stays a simple-name part-select (Verilator parses expressions
    // like (acc+1)[N-1:0] poorly; pre-computing avoids that).
    logic [8:0] acc_plus_one;
    assign acc_plus_one = accepted_count + 9'd1;

    // ---------------------------------------------------------------------
    // FSM
    // ---------------------------------------------------------------------
    typedef enum logic [1:0] {
        S_IDLE = 2'd0,
        S_KICK = 2'd1,
        S_RUN  = 2'd2,
        S_DONE = 2'd3
    } state_e;

    state_e state, state_next;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= S_IDLE;
        else        state <= state_next;
    end

    always_comb begin
        state_next = state;
        unique case (state)
            S_IDLE: if (start)                    state_next = S_KICK;
            S_KICK:                                state_next = S_RUN;
            S_RUN : if (accepted_count == 9'(N))   state_next = S_DONE;
            S_DONE:                                state_next = S_IDLE;
            default:                               state_next = S_IDLE;
        endcase
    end

    assign done = (state == S_DONE);

    // ---------------------------------------------------------------------
    // Datapath
    // ---------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            xof_start      <= 1'b0;
            buf0           <= '0;
            buf1           <= '0;
            byte_in_triple <= '0;
            accepted_count <= '0;
            d2_pending     <= 1'b0;
            d2_value       <= '0;
        end else begin
            xof_start <= 1'b0;

            unique case (state)
                S_IDLE: begin
                    if (start) begin
                        buf0           <= '0;
                        buf1           <= '0;
                        byte_in_triple <= '0;
                        accepted_count <= '0;
                        d2_pending     <= 1'b0;
                    end
                end

                S_KICK: xof_start <= 1'b1;

                S_RUN: begin
                    // (1) Drain queued d2 if pending. This happens at most
                    //     once per cycle, on the cycle right after a d2
                    //     was queued (always a byte-0 or paused cycle).
                    if (d2_pending && accepted_count < 9'(N)) begin
                        coef_mem[accepted_count[$clog2(N)-1:0]] <= d2_value;
                        accepted_count <= accepted_count + 9'd1;
                        d2_pending     <= 1'b0;
                    end

                    // (2) Byte capture / triple-process. d1 commits this
                    //     cycle; d2 (if accepted) is queued for next.
                    if (xof_out_valid) begin
                        unique case (byte_in_triple)
                            2'd0: begin
                                buf0           <= xof_out_byte;
                                byte_in_triple <= 2'd1;
                            end
                            2'd1: begin
                                buf1           <= xof_out_byte;
                                byte_in_triple <= 2'd2;
                            end
                            2'd2: begin
                                byte_in_triple <= 2'd0;
                                // Commit d1 directly to coef_mem if accepted.
                                // Drain doesn't conflict — it was a different
                                // address (smaller index).
                                if (d1_accept && accepted_count < 9'(N)) begin
                                    // accepted_count was incremented above
                                    // ONLY if d2_pending fired. So compute
                                    // the right index:
                                    if (d2_pending) begin
                                        // post-drain index = accepted_count + 1
                                        coef_mem[acc_plus_one[$clog2(N)-1:0]] <= d1_calc;
                                        accepted_count <= accepted_count + 9'd2;
                                    end else begin
                                        coef_mem[accepted_count[$clog2(N)-1:0]] <= d1_calc;
                                        accepted_count <= accepted_count + 9'd1;
                                    end
                                end
                                // Queue d2 if accepted and we still need it.
                                // Compute future-accepted-count after d1 commits:
                                if (d2_accept) begin
                                    // future count = accepted_count + drain_inc + d1_inc
                                    if ((accepted_count
                                         + 9'((d2_pending ? 1 : 0))
                                         + 9'((d1_accept ? 1 : 0))) < 9'(N)) begin
                                        d2_pending <= 1'b1;
                                        d2_value   <= d2_calc;
                                    end
                                end
                            end
                            default: ;
                        endcase
                    end
                end

                S_DONE: ;
                default: ;
            endcase
        end
    end

endmodule

`default_nettype wire
