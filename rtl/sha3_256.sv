// -----------------------------------------------------------------------------
// sha3_256.sv
//
// SHA3-256 sponge wrapped around keccak_f1600.
//
//   rate     = 136 bytes (17 lanes × 64 bits)
//   capacity =  64 bytes ( 8 lanes × 64 bits)
//   domain   = 0x06
//   output   = 32 bytes (4 lanes)
//
// Byte-streaming interface:
//
//   in_valid / in_byte / in_last -> caller drives one byte per cycle.
//                                   `in_last` must coincide with the
//                                   final byte. `in_ready` deasserts
//                                   during XOR+permute passes; caller
//                                   must throttle accordingly.
//
//   out_valid / out_byte         -> 32 bytes emitted one per cycle
//                                   once squeezing starts.
//   done                         -> pulses high one cycle when output
//                                   is fully emitted; ready to be
//                                   re-driven by the testbench.
//
// Implementation notes:
//   - Absorb buffer is packed `logic [1087:0]` (17 × 64) — keeps the
//     write/read paths Icarus-friendly. Unpacked-array indexing is
//     specifically what bit us in the Keccak Phase-3b VPI debug.
//   - Lane traversal during absorb/squeeze follows FIPS 202 §B.1:
//     i-th byte block maps to lane (x=i%5, y=i//5), flat = 5x+y.
//   - XOR-then-permute is the 17-step sequence
//     `READ(state[k]) -> latch -> LOAD(state[k] ^ buf[k])` repeated for
//     k = 0..16, then START -> WAIT_DONE.
// -----------------------------------------------------------------------------

`default_nettype none

module sha3_256 (
    input  wire        clk,
    input  wire        rst_n,

    // Byte input
    input  wire        in_valid,
    input  wire [7:0]  in_byte,
    input  wire        in_last,
    output logic       in_ready,

    // Byte output
    output logic       out_valid,
    output logic [7:0] out_byte,
    output logic       done
);

    // ---------------------------------------------------------------------
    // FIPS 202 §B.1 lane traversal: byte block i -> lane (i%5, i//5),
    // flat index = 5*(i%5) + (i//5).
    // ---------------------------------------------------------------------
    function automatic [4:0] lane_xy(input [4:0] i);
        // 17 entries for SHA3-256's rate; default to 0 for unused indices.
        unique case (i)
            5'd0 : lane_xy = 5'd0;  5'd1 : lane_xy = 5'd5;
            5'd2 : lane_xy = 5'd10; 5'd3 : lane_xy = 5'd15;
            5'd4 : lane_xy = 5'd20; 5'd5 : lane_xy = 5'd1;
            5'd6 : lane_xy = 5'd6;  5'd7 : lane_xy = 5'd11;
            5'd8 : lane_xy = 5'd16; 5'd9 : lane_xy = 5'd21;
            5'd10: lane_xy = 5'd2;  5'd11: lane_xy = 5'd7;
            5'd12: lane_xy = 5'd12; 5'd13: lane_xy = 5'd17;
            5'd14: lane_xy = 5'd22; 5'd15: lane_xy = 5'd3;
            5'd16: lane_xy = 5'd8;
            default: lane_xy = 5'd0;
        endcase
    endfunction

    // ---------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------
    localparam int unsigned RATE_BYTES = 136;
    localparam int unsigned RATE_LANES =  17;
    localparam int unsigned OUT_BYTES  =  32;
    localparam logic [7:0]  DOMAIN     = 8'h06;

    // ---------------------------------------------------------------------
    // Keccak permutation
    // ---------------------------------------------------------------------
    logic         kf_start;
    logic         kf_busy;
    logic         kf_done;
    logic         kf_load_en;
    logic [4:0]   kf_load_addr;
    logic [63:0]  kf_load_data;
    logic [4:0]   kf_read_addr;
    logic [63:0]  kf_read_data;

    keccak_f1600 u_keccak (
        .clk       (clk),
        .rst_n     (rst_n),
        .start     (kf_start),
        .busy      (kf_busy),
        .done      (kf_done),
        .load_en   (kf_load_en),
        .load_addr (kf_load_addr),
        .load_data (kf_load_data),
        .read_addr (kf_read_addr),
        .read_data (kf_read_data)
    );

    // ---------------------------------------------------------------------
    // Absorb buffer — packed 17 × 64 bits.
    // ---------------------------------------------------------------------
    logic [RATE_LANES*64-1:0] absorb_buf;

    // Counters
    logic [4:0]   abs_lane_idx;     // 0..16, lane within absorb_buf currently being filled
    logic [2:0]   abs_byte_idx;     // 0..7,  byte within current lane

    // XOR-permute walker
    logic [4:0]   merge_idx;        // 0..17

    // Squeeze counters
    logic [5:0]   out_idx;          // 0..31 (one extra bit for terminating compare)
    logic [63:0]  squeeze_lane;     // latched lane being emitted

    // Pending state machine flags
    logic         seen_last;        // in_last seen — final padded block in flight
    logic         in_squeeze;       // squeeze phase active

    // ---------------------------------------------------------------------
    // FSM
    // ---------------------------------------------------------------------
    typedef enum logic [3:0] {
        S_IDLE          = 4'd0,
        S_ABSORB        = 4'd1,
        S_PAD           = 4'd2,
        S_XOR_READ      = 4'd3,
        S_XOR_WAIT      = 4'd4,
        S_XOR_LOAD      = 4'd5,
        S_PERMUTE_START = 4'd6,
        S_PERMUTE_WAIT  = 4'd7,
        S_SQ_READ       = 4'd8,
        S_SQ_WAIT       = 4'd9,
        S_SQ_LATCH      = 4'd10,
        S_SQ_EMIT       = 4'd11,
        S_DONE          = 4'd12
    } state_e;

    state_e state, state_next;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= S_IDLE;
        else        state <= state_next;
    end

    // Convenience: the packed-block lane index "i" -> 64-bit slice base
    // into absorb_buf is i*64. We use this both at load-time and at
    // XOR-time below.

    // Padded-block trigger: we've just placed the last byte (with
    // padding overlay) and need to XOR + permute.
    // Full-block trigger: 17 lanes filled during normal absorb.
    logic full_block_filled;
    assign full_block_filled = (abs_lane_idx == 5'(RATE_LANES - 1)) &&
                               (abs_byte_idx == 3'd7);

    always_comb begin
        state_next = state;
        unique case (state)
            S_IDLE          : if (in_valid) state_next = S_ABSORB;
            S_ABSORB        : begin
                if (in_valid && in_last)              state_next = S_PAD;
                else if (in_valid && full_block_filled) state_next = S_XOR_READ;
                // else: stay in S_ABSORB
            end
            S_PAD           :                       state_next = S_XOR_READ;
            S_XOR_READ      :                       state_next = S_XOR_WAIT;
            S_XOR_WAIT      :                       state_next = S_XOR_LOAD;
            S_XOR_LOAD      : begin
                if (merge_idx == 5'(RATE_LANES - 1)) state_next = S_PERMUTE_START;
                else                                 state_next = S_XOR_READ;
            end
            S_PERMUTE_START :                       state_next = S_PERMUTE_WAIT;
            S_PERMUTE_WAIT  : begin
                if (kf_done) begin
                    if (seen_last) state_next = S_SQ_READ;
                    else           state_next = S_ABSORB;
                end
            end
            S_SQ_READ       :                       state_next = S_SQ_WAIT;
            S_SQ_WAIT       :                       state_next = S_SQ_LATCH;
            S_SQ_LATCH      :                       state_next = S_SQ_EMIT;
            S_SQ_EMIT       : begin
                if (out_idx == 6'(OUT_BYTES - 1))    state_next = S_DONE;
                else if (out_idx[2:0] == 3'd7)       state_next = S_SQ_READ;
                // else: stay in S_SQ_EMIT to emit next byte from squeeze_lane
            end
            S_DONE          :                       state_next = S_IDLE;
            default         :                       state_next = S_IDLE;
        endcase
    end

    // ---------------------------------------------------------------------
    // Datapath
    // ---------------------------------------------------------------------
    assign in_ready  = (state == S_IDLE) || (state == S_ABSORB);
    assign out_valid = (state == S_SQ_EMIT);
    assign done      = (state == S_DONE);

    // The next byte to write into absorb_buf (with padding overlay applied
    // when we're stepping into S_PAD or sitting in S_ABSORB on the last byte).
    logic [7:0] abs_byte_in;
    assign abs_byte_in = in_byte;

    // Position helpers
    logic [10:0]  buf_byte_bit;     // bit position in absorb_buf for the current write
    assign buf_byte_bit = ({6'd0, abs_lane_idx} * 11'd64) +
                          ({8'd0, abs_byte_idx} * 11'd8);

    // Position of the last byte in the rate block (for the 0x80 padding bit)
    localparam int unsigned LAST_BIT = (RATE_BYTES - 1) * 8;

    // 64-bit slice base address into absorb_buf for current merge step.
    logic [10:0] merge_bit;
    assign merge_bit = {6'd0, merge_idx} * 11'd64;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            absorb_buf   <= '0;
            abs_lane_idx <= '0;
            abs_byte_idx <= '0;
            merge_idx    <= '0;
            out_idx      <= '0;
            squeeze_lane <= '0;
            seen_last    <= 1'b0;
            in_squeeze   <= 1'b0;
            kf_start     <= 1'b0;
            kf_load_en   <= 1'b0;
            kf_load_addr <= '0;
            kf_load_data <= '0;
            kf_read_addr <= '0;
            out_byte     <= '0;
        end else begin
            // Defaults (overridden below per-state)
            kf_start   <= 1'b0;
            kf_load_en <= 1'b0;

            unique case (state)
                // -------------------------------------------------------
                S_IDLE: begin
                    // First in_valid handled in S_ABSORB next cycle by
                    // S_IDLE -> S_ABSORB transition; reset state if a
                    // run is starting.
                    if (state_next == S_ABSORB) begin
                        absorb_buf   <= '0;
                        abs_lane_idx <= '0;
                        abs_byte_idx <= '0;
                        merge_idx    <= '0;
                        out_idx      <= '0;
                        seen_last    <= 1'b0;
                    end
                end

                // -------------------------------------------------------
                S_ABSORB: begin
                    if (in_valid) begin
                        // Place this byte at (abs_lane_idx, abs_byte_idx)
                        absorb_buf[buf_byte_bit +: 8] <= abs_byte_in;
                        // Counter advance
                        if (abs_byte_idx == 3'd7) begin
                            abs_byte_idx <= 3'd0;
                            abs_lane_idx <= abs_lane_idx + 5'd1;
                        end else begin
                            abs_byte_idx <= abs_byte_idx + 3'd1;
                        end
                        // Note: if full_block_filled and !in_last, FSM
                        // transitions to S_XOR_READ; counter wraparound
                        // happens after the XOR-permute completes (see
                        // S_PERMUTE_WAIT -> S_ABSORB transition below).
                        // If in_last: FSM transitions to S_PAD next cycle.
                        if (in_last) begin
                            seen_last <= 1'b1;
                        end
                    end
                end

                // -------------------------------------------------------
                S_PAD: begin
                    // Apply the domain byte at the NEXT position after the
                    // last input byte, and 0x80 at the LAST byte of the rate
                    // block. The last-input byte already lives in absorb_buf
                    // from the S_ABSORB step; (abs_lane_idx, abs_byte_idx)
                    // now point to the next free slot.
                    absorb_buf[buf_byte_bit +: 8] <= DOMAIN;
                    absorb_buf[LAST_BIT  +: 8]
                        <= absorb_buf[LAST_BIT +: 8] ^ 8'h80;
                    // Reset merge_idx for the XOR-permute pass that follows
                    merge_idx <= '0;
                end

                // -------------------------------------------------------
                S_XOR_READ: begin
                    kf_read_addr <= lane_xy(merge_idx);
                end

                // -------------------------------------------------------
                S_XOR_WAIT: begin
                    // Wait one cycle so the registered read_data updates.
                end

                // -------------------------------------------------------
                S_XOR_LOAD: begin
                    kf_load_en   <= 1'b1;
                    kf_load_addr <= lane_xy(merge_idx);
                    kf_load_data <= kf_read_data ^ absorb_buf[merge_bit +: 64];
                    if (merge_idx != 5'(RATE_LANES - 1)) begin
                        merge_idx <= merge_idx + 5'd1;
                    end
                end

                // -------------------------------------------------------
                S_PERMUTE_START: begin
                    kf_start <= 1'b1;
                end

                // -------------------------------------------------------
                S_PERMUTE_WAIT: begin
                    if (kf_done) begin
                        // Reset absorb buffer for next block (in case of
                        // multi-block absorb) or for next sponge run.
                        absorb_buf   <= '0;
                        abs_lane_idx <= '0;
                        abs_byte_idx <= '0;
                        merge_idx    <= '0;
                        if (seen_last) begin
                            // Move into squeeze
                            out_idx    <= '0;
                            in_squeeze <= 1'b1;
                        end
                    end
                end

                // -------------------------------------------------------
                S_SQ_READ: begin
                    kf_read_addr <= lane_xy({2'd0, out_idx[5:3]});
                end

                // -------------------------------------------------------
                S_SQ_WAIT: begin
                    // Wait one cycle so registered read_data updates.
                end

                // -------------------------------------------------------
                S_SQ_LATCH: begin
                    squeeze_lane <= kf_read_data;
                end

                // -------------------------------------------------------
                S_SQ_EMIT: begin
                    // Emit byte out_idx[2:0] of squeeze_lane (little-endian)
                    out_byte <= squeeze_lane[{out_idx[2:0], 3'b000} +: 8];
                    if (out_idx != 6'(OUT_BYTES - 1)) begin
                        out_idx <= out_idx + 6'd1;
                    end
                end

                // -------------------------------------------------------
                S_DONE: begin
                    in_squeeze <= 1'b0;
                end

                default: ;
            endcase
        end
    end

endmodule

`default_nettype wire
