// -----------------------------------------------------------------------------
// sample_poly_cbd2.sv
//
// Kyber centered binomial distribution sampler with η = 2 — the noise
// sampler used for e, e1, e2 in Kyber768 keygen/encrypt/decrypt.
//
//   input  : 32-byte sigma + 1-byte nonce (33 bytes total)
//   xof    : SHAKE-256(sigma || nonce) → 128 bytes
//   coef[i]= (popcount(bits[4i : 4i+2]) - popcount(bits[4i+2 : 4i+4])) mod q
//            for i = 0..255
//
// Each input byte produces TWO coefficients: bit-positions 0..3 of the
// byte give coef[2k], bit-positions 4..7 give coef[2k+1]. The RTL writes
// both coefs in the same cycle to coef_mem (single-port BRAM is fine for
// simulation; synthesis targets a dual-port BRAM where these writes go
// to different ports — standard on Xilinx 7-series / Zynq UltraScale+).
//
// Verified against python/sponge_ref.sample_cbd2_from_seed.
// -----------------------------------------------------------------------------

`default_nettype none

module sample_poly_cbd2 #(
    parameter int unsigned Q          = 3329,
    parameter int unsigned N          = 256,
    parameter int unsigned XOF_BYTES  = 128   // 64 * η, η = 2
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        start,

    // Seed input stream — 32-byte sigma followed by 1-byte nonce, total 33
    input  wire        seed_valid,
    input  wire [7:0]  seed_byte,
    input  wire        seed_last,
    output logic       seed_ready,

    output logic       done,

    input  wire [$clog2(N)-1:0] read_addr,
    output logic [11:0] read_data
);

    // ---------------------------------------------------------------------
    // SHAKE-256 instance
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

    shake_256 u_xof (
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
    // Per-byte processing: extract two 4-bit windows, each yielding
    //   coef = (popcount(a-bits) - popcount(b-bits)) mod q.
    // For η = 2 the bit windows are 2 bits wide so popcount is just
    // (bit0 + bit1).
    // ---------------------------------------------------------------------
    function automatic [11:0] cbd_coef(input [1:0] a, input [1:0] b);
        logic [1:0] pop_a, pop_b;
        pop_a = {1'b0, a[0]} + {1'b0, a[1]};
        pop_b = {1'b0, b[0]} + {1'b0, b[1]};
        if (pop_a >= pop_b) begin
            cbd_coef = 12'({pop_a - pop_b});
        end else begin
            cbd_coef = 12'(Q) - 12'({pop_b - pop_a});
        end
    endfunction

    logic [11:0] coef_low, coef_high;
    assign coef_low  = cbd_coef(xof_out_byte[1:0], xof_out_byte[3:2]);
    assign coef_high = cbd_coef(xof_out_byte[5:4], xof_out_byte[7:6]);

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

    logic [7:0] byte_idx;     // 0..127 (need 8 bits for compare-to-128)

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= S_IDLE;
        else        state <= state_next;
    end

    always_comb begin
        state_next = state;
        unique case (state)
            S_IDLE: if (start)                       state_next = S_KICK;
            S_KICK:                                   state_next = S_RUN;
            S_RUN : if (byte_idx == 8'd128)           state_next = S_DONE;
            S_DONE:                                   state_next = S_IDLE;
            default:                                  state_next = S_IDLE;
        endcase
    end

    assign done = (state == S_DONE);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            xof_start <= 1'b0;
            byte_idx  <= '0;
        end else begin
            xof_start <= 1'b0;

            unique case (state)
                S_IDLE: if (start) byte_idx <= '0;

                S_KICK: xof_start <= 1'b1;

                S_RUN: begin
                    if (xof_out_valid) begin
                        // Two writes per cycle to different addresses
                        // (dual-port BRAM target).
                        coef_mem[{byte_idx[6:0], 1'b0}] <= coef_low;
                        coef_mem[{byte_idx[6:0], 1'b1}] <= coef_high;
                        byte_idx <= byte_idx + 8'd1;
                    end
                end

                S_DONE: ;
                default: ;
            endcase
        end
    end

endmodule

`default_nettype wire
