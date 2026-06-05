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
//   start       -> pulse to begin a new hash. Resets internal counters.
//   in_valid    -> caller asserts when driving a byte.
//   in_byte     -> the byte.
//   in_last     -> asserted with the final byte.
//   in_ready    -> asserted when the FSM can accept a byte this cycle.
//                  Deasserts during XOR+permute pre-blocks, padding,
//                  and squeeze.
//
//   out_valid / out_byte -> 32 bytes emitted one per cycle.
//   done                 -> pulses high one cycle after last byte.
//
// Implementation notes:
//   - Absorb buffer is packed `logic [1087:0]` (17 × 64). Lane traversal
//     during absorb and squeeze follows FIPS 202 §B.1: i-th byte block
//     maps to state lane (x=i%5, y=i//5), looked up by a case-decoded
//     `lane_xy(i)` function (no unpacked-array variable indexing — same
//     reason we needed packed ports for keccak_round in Phase 3b).
//   - XOR-then-permute is the 17-step sequence
//     `READ(state[k]) -> WAIT -> LOAD(state[k] ^ buf[k])` repeated for
//     k = 0..16, then START -> WAIT_DONE.
//   - `out_byte` is combinational on the latched squeeze_lane and the
//     registered byte counter — emits the correct byte on the same
//     cycle that out_valid is observed, no off-by-one.
// -----------------------------------------------------------------------------

`default_nettype none

module sha3_256 (
    input  wire        clk,
    input  wire        rst_n,

    // Control + byte input
    input  wire        start,
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
    // FIPS 202 §B.1 lane traversal
    // ---------------------------------------------------------------------
    function automatic [4:0] lane_xy(input [4:0] i);
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
    // Keccak permutation instance
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
    // Registers
    // ---------------------------------------------------------------------
    logic [RATE_LANES*64-1:0] absorb_buf;

    logic [4:0]   abs_lane_idx;     // 0..16 lane currently being filled
    logic [2:0]   abs_byte_idx;     // 0..7  byte within current lane
    logic [4:0]   merge_idx;        // 0..16 lane being XORed into state
    logic [5:0]   out_idx;          // 0..31 squeeze byte counter
    logic [63:0]  squeeze_lane;     // latched lane during squeeze
    logic         seen_last;        // last byte already absorbed — final padded block

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

    // Helpers
    logic full_block_filled;
    assign full_block_filled = (abs_lane_idx == 5'(RATE_LANES - 1)) &&
                               (abs_byte_idx == 3'd7);

    logic [10:0] buf_byte_bit;
    assign buf_byte_bit = ({6'd0, abs_lane_idx} * 11'd64) +
                          ({8'd0, abs_byte_idx} * 11'd8);

    localparam int unsigned LAST_BIT = (RATE_BYTES - 1) * 8;

    logic [10:0] merge_bit;
    assign merge_bit = {6'd0, merge_idx} * 11'd64;

    always_comb begin
        state_next = state;
        unique case (state)
            S_IDLE          : if (start)              state_next = S_ABSORB;
            S_ABSORB        : begin
                if (in_valid && in_last)              state_next = S_PAD;
                else if (in_valid && full_block_filled) state_next = S_XOR_READ;
            end
            S_PAD           :                          state_next = S_XOR_READ;
            S_XOR_READ      :                          state_next = S_XOR_WAIT;
            S_XOR_WAIT      :                          state_next = S_XOR_LOAD;
            S_XOR_LOAD      : begin
                if (merge_idx == 5'(RATE_LANES - 1)) state_next = S_PERMUTE_START;
                else                                  state_next = S_XOR_READ;
            end
            S_PERMUTE_START :                          state_next = S_PERMUTE_WAIT;
            S_PERMUTE_WAIT  : if (kf_done) begin
                if (seen_last) state_next = S_SQ_READ;
                else           state_next = S_ABSORB;
            end
            S_SQ_READ       :                          state_next = S_SQ_WAIT;
            S_SQ_WAIT       :                          state_next = S_SQ_LATCH;
            S_SQ_LATCH      :                          state_next = S_SQ_EMIT;
            S_SQ_EMIT       : begin
                if (out_idx == 6'(OUT_BYTES - 1))     state_next = S_DONE;
                else if (out_idx[2:0] == 3'd7)        state_next = S_SQ_READ;
            end
            S_DONE          :                          state_next = S_IDLE;
            default         :                          state_next = S_IDLE;
        endcase
    end

    // ---------------------------------------------------------------------
    // Combinational outputs
    // ---------------------------------------------------------------------
    assign in_ready  = (state == S_ABSORB);
    assign out_valid = (state == S_SQ_EMIT);
    assign done      = (state == S_DONE);
    assign out_byte  = squeeze_lane[{out_idx[2:0], 3'b000} +: 8];

    // ---------------------------------------------------------------------
    // Datapath registers
    // ---------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            absorb_buf   <= '0;
            abs_lane_idx <= '0;
            abs_byte_idx <= '0;
            merge_idx    <= '0;
            out_idx      <= '0;
            squeeze_lane <= '0;
            seen_last    <= 1'b0;
            kf_start     <= 1'b0;
            kf_load_en   <= 1'b0;
            kf_load_addr <= '0;
            kf_load_data <= '0;
            kf_read_addr <= '0;
        end else begin
            // Default pulse-high signals
            kf_start   <= 1'b0;
            kf_load_en <= 1'b0;

            unique case (state)
                // -------------------------------------------------------
                S_IDLE: begin
                    // On start: clear buffers + counters in preparation
                    // for the absorb phase that begins next cycle.
                    if (start) begin
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
                        // Absorb byte at current (lane, byte) position.
                        absorb_buf[buf_byte_bit +: 8] <= in_byte;
                        // Advance counters: byte first, then lane.
                        if (abs_byte_idx == 3'd7) begin
                            abs_byte_idx <= 3'd0;
                            abs_lane_idx <= abs_lane_idx + 5'd1;
                        end else begin
                            abs_byte_idx <= abs_byte_idx + 3'd1;
                        end
                        if (in_last) seen_last <= 1'b1;
                    end
                end

                // -------------------------------------------------------
                S_PAD: begin
                    // Place 0x06 at the NEXT free byte position (the one
                    // just past the last input byte). Counters were
                    // already advanced in S_ABSORB so (abs_lane_idx,
                    // abs_byte_idx) point to the right slot.
                    absorb_buf[buf_byte_bit +: 8] <= DOMAIN;
                    // OR 0x80 into the last byte of the rate block.
                    // Two assignments to the same buf word in the same
                    // cycle: SV NBA semantics pick the last; we do the
                    // domain write first via `<= DOMAIN` and then the
                    // 0x80 overlay via an XOR-with-current of the
                    // current absorb_buf value at that position. If the
                    // domain byte happens to be at the same position
                    // as 0x80 (single-byte-short-of-rate input), the
                    // two operations XOR-combine correctly.
                    absorb_buf[LAST_BIT +: 8]
                        <= absorb_buf[LAST_BIT +: 8] ^ 8'h80;
                    // For the rare edge case where buf_byte_bit ==
                    // LAST_BIT (input fills 135 bytes), both writes
                    // target the same byte. SV semantics: the last
                    // procedural assignment wins, so the 0x80 overlay
                    // (XOR of 0 ^ 0x80) overwrites the 0x06. That's
                    // wrong — but in that case the standard says the
                    // result should be 0x86 (0x06 | 0x80). Force the
                    // explicit combination below.
                    if (buf_byte_bit == 11'(LAST_BIT)) begin
                        absorb_buf[LAST_BIT +: 8] <= DOMAIN | 8'h80;
                    end
                    merge_idx <= '0;
                end

                // -------------------------------------------------------
                S_XOR_READ: kf_read_addr <= lane_xy(merge_idx);
                S_XOR_WAIT: ;  // wait one cycle for registered read

                S_XOR_LOAD: begin
                    kf_load_en   <= 1'b1;
                    kf_load_addr <= lane_xy(merge_idx);
                    kf_load_data <= kf_read_data ^ absorb_buf[merge_bit +: 64];
                    if (merge_idx != 5'(RATE_LANES - 1)) begin
                        merge_idx <= merge_idx + 5'd1;
                    end
                end

                S_PERMUTE_START: kf_start <= 1'b1;

                S_PERMUTE_WAIT: begin
                    if (kf_done) begin
                        absorb_buf   <= '0;
                        abs_lane_idx <= '0;
                        abs_byte_idx <= '0;
                        merge_idx    <= '0;
                        out_idx      <= '0;
                    end
                end

                // -------------------------------------------------------
                S_SQ_READ : kf_read_addr <= lane_xy({2'd0, out_idx[5:3]});
                S_SQ_WAIT : ;
                S_SQ_LATCH: squeeze_lane <= kf_read_data;
                S_SQ_EMIT : begin
                    if (out_idx != 6'(OUT_BYTES - 1)) begin
                        out_idx <= out_idx + 6'd1;
                    end
                end

                S_DONE: ;

                default: ;
            endcase
        end
    end

endmodule

`default_nettype wire
