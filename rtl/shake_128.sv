// -----------------------------------------------------------------------------
// shake_128.sv
//
// SHAKE-128 sponge wrapped around keccak_f1600. Produces an arbitrary
// (caller-specified) number of output bytes from a byte-streamed input.
//
//   rate     = 168 bytes (21 lanes × 64 bits)
//   capacity =  32 bytes ( 4 lanes × 64 bits)
//   domain   = 0x1F
//   output   = `out_bytes_req` (configured at start, up to 65535)
//
// Caller workflow:
//   1. Assert `start` with `out_bytes_req` valid.
//   2. Stream input bytes via in_valid/in_byte/in_last. Throttle on in_ready.
//   3. After in_last, the FSM permutes the absorbed state and begins
//      squeezing.
//   4. Collect bytes from `out_byte` while `out_valid` is high. When the
//      rate is exhausted mid-output, the FSM permutes again and continues.
//   5. `done` pulses high one cycle after the last output byte.
//
// FIPS 202 §B.1 lane traversal extended to 21 lanes for the SHAKE-128 rate.
// State-clear + first-block / rate-boundary / register-port-Icarus-VPI
// considerations all carry over from sha3_256.sv.
// -----------------------------------------------------------------------------

`default_nettype none

module shake_128 (
    input  wire        clk,
    input  wire        rst_n,

    // Control + byte input
    input  wire        start,
    input  wire [15:0] out_bytes_req,   // captured at start
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
    // FIPS 202 §B.1 lane traversal (extended to 21 lanes for SHAKE-128's rate)
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
            5'd16: lane_xy = 5'd8;  5'd17: lane_xy = 5'd13;
            5'd18: lane_xy = 5'd18; 5'd19: lane_xy = 5'd23;
            5'd20: lane_xy = 5'd4;
            default: lane_xy = 5'd0;
        endcase
    endfunction

    // Constants
    localparam int unsigned RATE_BYTES = 168;
    localparam int unsigned RATE_LANES =  21;
    localparam logic [7:0]  DOMAIN     = 8'h1F;

    // Keccak permutation instance
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

    // Absorb buffer — packed 21 × 64
    logic [RATE_LANES*64-1:0] absorb_buf;

    logic [4:0]   abs_lane_idx;     // 0..20 lane being filled
    logic [2:0]   abs_byte_idx;     // 0..7 byte within lane
    logic [4:0]   merge_idx;        // 0..20 lane being XORed/written
    logic [4:0]   clear_idx;        // 0..24 lane being cleared
    logic         seen_last;
    logic         last_block_padded;

    // Squeeze counters
    logic [15:0]  out_bytes_total;  // captured at start
    logic [15:0]  out_idx_total;    // 0..out_bytes_total-1
    logic [4:0]   sq_lane_idx;      // 0..20 byte block within current rate
    logic [2:0]   sq_byte_in_lane;  // 0..7
    logic [63:0]  squeeze_lane;     // latched lane

    // FSM
    typedef enum logic [3:0] {
        S_IDLE          = 4'd0,
        S_INIT_CLEAR    = 4'd1,
        S_ABSORB        = 4'd2,
        S_PAD           = 4'd3,
        S_XOR_READ      = 4'd4,
        S_XOR_WAIT      = 4'd5,
        S_XOR_LOAD      = 4'd6,
        S_PERMUTE_START = 4'd7,
        S_PERMUTE_WAIT  = 4'd8,
        S_SQ_READ       = 4'd9,
        S_SQ_WAIT       = 4'd10,
        S_SQ_LATCH      = 4'd11,
        S_SQ_EMIT       = 4'd12,
        S_SQ_PERMUTE_START = 4'd13,
        S_SQ_PERMUTE_WAIT  = 4'd14,
        S_DONE          = 4'd15
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

    // Last-byte-of-output detector
    logic last_byte;
    assign last_byte = (out_idx_total == out_bytes_total - 16'd1);

    // Rate exhausted detector: emitting the last byte of lane RATE_LANES-1
    logic rate_exhausted;
    assign rate_exhausted = (sq_lane_idx == 5'(RATE_LANES - 1)) &&
                            (sq_byte_in_lane == 3'd7);

    always_comb begin
        state_next = state;
        unique case (state)
            S_IDLE          : if (start)              state_next = S_INIT_CLEAR;
            S_INIT_CLEAR    : if (clear_idx == 5'd24) state_next = S_ABSORB;
            S_ABSORB        : begin
                if (in_valid && full_block_filled)    state_next = S_XOR_READ;
                else if (in_valid && in_last)         state_next = S_PAD;
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
                if (seen_last && last_block_padded)    state_next = S_SQ_READ;
                else if (seen_last)                    state_next = S_PAD;
                else                                   state_next = S_ABSORB;
            end
            S_SQ_READ       :                          state_next = S_SQ_WAIT;
            S_SQ_WAIT       :                          state_next = S_SQ_LATCH;
            S_SQ_LATCH      :                          state_next = S_SQ_EMIT;
            S_SQ_EMIT       : begin
                if (last_byte)                         state_next = S_DONE;
                else if (rate_exhausted)               state_next = S_SQ_PERMUTE_START;
                else if (sq_byte_in_lane == 3'd7)      state_next = S_SQ_READ;
            end
            S_SQ_PERMUTE_START:                       state_next = S_SQ_PERMUTE_WAIT;
            S_SQ_PERMUTE_WAIT : if (kf_done)          state_next = S_SQ_READ;
            S_DONE          :                          state_next = S_IDLE;
            default         :                          state_next = S_IDLE;
        endcase
    end

    // Combinational outputs
    assign in_ready  = (state == S_ABSORB);
    assign out_valid = (state == S_SQ_EMIT);
    assign done      = (state == S_DONE);
    assign out_byte  = squeeze_lane[{sq_byte_in_lane, 3'b000} +: 8];

    // ---------------------------------------------------------------------
    // Datapath
    // ---------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            absorb_buf        <= '0;
            abs_lane_idx      <= '0;
            abs_byte_idx      <= '0;
            merge_idx         <= '0;
            clear_idx         <= '0;
            squeeze_lane      <= '0;
            sq_lane_idx       <= '0;
            sq_byte_in_lane   <= '0;
            out_idx_total     <= '0;
            out_bytes_total   <= '0;
            seen_last         <= 1'b0;
            last_block_padded <= 1'b0;
            kf_start          <= 1'b0;
            kf_load_en        <= 1'b0;
            kf_load_addr      <= '0;
            kf_load_data      <= '0;
            kf_read_addr      <= '0;
        end else begin
            kf_start   <= 1'b0;
            kf_load_en <= 1'b0;

            unique case (state)
                S_IDLE: begin
                    if (start) begin
                        absorb_buf        <= '0;
                        abs_lane_idx      <= '0;
                        abs_byte_idx      <= '0;
                        merge_idx         <= '0;
                        clear_idx         <= '0;
                        sq_lane_idx       <= '0;
                        sq_byte_in_lane   <= '0;
                        out_idx_total     <= '0;
                        out_bytes_total   <= out_bytes_req;
                        seen_last         <= 1'b0;
                        last_block_padded <= 1'b0;
                    end
                end

                S_INIT_CLEAR: begin
                    kf_load_en   <= 1'b1;
                    kf_load_addr <= clear_idx;
                    kf_load_data <= 64'd0;
                    if (clear_idx != 5'd24) clear_idx <= clear_idx + 5'd1;
                end

                S_ABSORB: begin
                    if (in_valid) begin
                        absorb_buf[buf_byte_bit +: 8] <= in_byte;
                        if (abs_byte_idx == 3'd7) begin
                            abs_byte_idx <= 3'd0;
                            abs_lane_idx <= abs_lane_idx + 5'd1;
                        end else begin
                            abs_byte_idx <= abs_byte_idx + 3'd1;
                        end
                        if (in_last) seen_last <= 1'b1;
                    end
                end

                S_PAD: begin
                    absorb_buf[buf_byte_bit +: 8] <= DOMAIN;
                    absorb_buf[LAST_BIT +: 8]
                        <= absorb_buf[LAST_BIT +: 8] ^ 8'h80;
                    if (buf_byte_bit == 11'(LAST_BIT)) begin
                        absorb_buf[LAST_BIT +: 8] <= DOMAIN | 8'h80;
                    end
                    merge_idx         <= '0;
                    last_block_padded <= 1'b1;
                end

                S_XOR_READ : kf_read_addr <= lane_xy(merge_idx);
                S_XOR_WAIT : ;
                S_XOR_LOAD : begin
                    kf_load_en   <= 1'b1;
                    kf_load_addr <= lane_xy(merge_idx);
                    kf_load_data <= kf_read_data ^ absorb_buf[merge_bit +: 64];
                    if (merge_idx != 5'(RATE_LANES - 1)) merge_idx <= merge_idx + 5'd1;
                end

                S_PERMUTE_START: kf_start <= 1'b1;
                S_PERMUTE_WAIT : begin
                    if (kf_done) begin
                        absorb_buf   <= '0;
                        abs_lane_idx <= '0;
                        abs_byte_idx <= '0;
                        merge_idx    <= '0;
                        sq_lane_idx  <= '0;
                        sq_byte_in_lane <= '0;
                    end
                end

                S_SQ_READ : kf_read_addr <= lane_xy(sq_lane_idx);
                S_SQ_WAIT : ;
                S_SQ_LATCH: squeeze_lane <= kf_read_data;
                S_SQ_EMIT : begin
                    // out_byte is combinational; advance counters at end of cycle
                    if (!last_byte) begin
                        out_idx_total <= out_idx_total + 16'd1;
                    end
                    if (sq_byte_in_lane == 3'd7) begin
                        sq_byte_in_lane <= 3'd0;
                        if (sq_lane_idx == 5'(RATE_LANES - 1)) begin
                            sq_lane_idx <= '0;  // wrap; permute next
                        end else begin
                            sq_lane_idx <= sq_lane_idx + 5'd1;
                        end
                    end else begin
                        sq_byte_in_lane <= sq_byte_in_lane + 3'd1;
                    end
                end

                S_SQ_PERMUTE_START: kf_start <= 1'b1;
                S_SQ_PERMUTE_WAIT : ;  // sq_lane_idx + sq_byte_in_lane already reset to 0

                S_DONE: ;
                default: ;
            endcase
        end
    end

endmodule

`default_nettype wire
