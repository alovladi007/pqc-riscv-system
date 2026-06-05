// -----------------------------------------------------------------------------
// keccak_f1600.sv
//
// Iterative 24-round controller around the combinational keccak_round module.
//
//   - One keccak_round instance applied 24 times, one round per cycle
//   - Round-constant ROM (24 × 64 bits) baked in at elaboration
//   - State register: 25 × 64-bit lanes per FIPS 202
//   - Load port: testbench writes 25 lanes by index before pulsing start
//   - Read port: combinational, valid after `done`
//
// Pure permutation only. The sponge layer (absorb / squeeze / padding)
// belongs above this in software for the Kyber use case; this module is
// the Keccak-f[1600] permutation that those layers iterate.
//
// Verified against python/keccak_ref.py:keccak_f1600() in tb/test_keccak.py.
// -----------------------------------------------------------------------------

`default_nettype none

module keccak_f1600 (
    input  wire        clk,
    input  wire        rst_n,

    // Control
    input  wire        start,    // pulse to begin permutation
    output logic       busy,
    output logic       done,     // pulses high one cycle when permutation completes

    // Load port (testbench writes 25 lanes before `start`)
    input  wire        load_en,
    input  wire [4:0]  load_addr,
    input  wire [63:0] load_data,

    // Read port (combinational; valid after `done`)
    input  wire [4:0]  read_addr,
    output logic [63:0] read_data
);

    // -----------------------------------------------------------------
    // Round-constant ROM
    // -----------------------------------------------------------------
    logic [63:0] rc_rom [0:23];
    initial begin
        rc_rom[ 0] = 64'h0000000000000001; rc_rom[ 1] = 64'h0000000000008082;
        rc_rom[ 2] = 64'h800000000000808A; rc_rom[ 3] = 64'h8000000080008000;
        rc_rom[ 4] = 64'h000000000000808B; rc_rom[ 5] = 64'h0000000080000001;
        rc_rom[ 6] = 64'h8000000080008081; rc_rom[ 7] = 64'h8000000000008009;
        rc_rom[ 8] = 64'h000000000000008A; rc_rom[ 9] = 64'h0000000000000088;
        rc_rom[10] = 64'h0000000080008009; rc_rom[11] = 64'h000000008000000A;
        rc_rom[12] = 64'h000000008000808B; rc_rom[13] = 64'h800000000000008B;
        rc_rom[14] = 64'h8000000000008089; rc_rom[15] = 64'h8000000000008003;
        rc_rom[16] = 64'h8000000000008002; rc_rom[17] = 64'h8000000000000080;
        rc_rom[18] = 64'h000000000000800A; rc_rom[19] = 64'h800000008000000A;
        rc_rom[20] = 64'h8000000080008081; rc_rom[21] = 64'h8000000000008080;
        rc_rom[22] = 64'h0000000080000001; rc_rom[23] = 64'h8000000080008008;
    end

    // -----------------------------------------------------------------
    // Permutation state: 25 × 64-bit lanes
    // -----------------------------------------------------------------
    logic [63:0] state [0:24];
    assign read_data = state[read_addr];

    // -----------------------------------------------------------------
    // FSM declarations (declared before the keccak_round instance so
    // round_idx is visible when used as an index into rc_rom — Icarus
    // is strict about "declaration after use" while Verilator wasn't).
    //
    //   S_IDLE : wait for start
    //   S_RUN  : apply one round per cycle until round_idx reaches 23
    //   S_DONE : pulse done, return to IDLE
    // -----------------------------------------------------------------
    typedef enum logic [1:0] {
        S_IDLE = 2'd0,
        S_RUN  = 2'd1,
        S_DONE = 2'd2
    } state_e;

    state_e fsm, fsm_next;
    logic [4:0] round_idx;     // 0..23

    // -----------------------------------------------------------------
    // Round combinational instance
    // -----------------------------------------------------------------
    logic [63:0] round_out [0:24];

    keccak_round u_round (
        .state_in    (state),
        .round_const (rc_rom[round_idx]),
        .state_out   (round_out)
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) fsm <= S_IDLE;
        else        fsm <= fsm_next;
    end

    always_comb begin
        fsm_next = fsm;
        unique case (fsm)
            S_IDLE: if (start)              fsm_next = S_RUN;
            S_RUN:  if (round_idx == 5'd23) fsm_next = S_DONE;
            S_DONE:                          fsm_next = S_IDLE;
            default:                         fsm_next = S_IDLE;
        endcase
    end

    assign busy = (fsm != S_IDLE);
    assign done = (fsm == S_DONE);

    // -----------------------------------------------------------------
    // State register + load port + round commit
    // -----------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            round_idx <= 5'd0;
            for (int i = 0; i < 25; i++) state[i] <= 64'd0;
        end else begin
            // Load port — accepted any time IDLE
            if (load_en && fsm == S_IDLE) begin
                state[load_addr] <= load_data;
            end

            // Start: reset round counter
            if (fsm == S_IDLE && start) begin
                round_idx <= 5'd0;
            end

            // Each cycle in S_RUN: commit round_out into state, bump round
            if (fsm == S_RUN) begin
                for (int i = 0; i < 25; i++) state[i] <= round_out[i];
                round_idx <= round_idx + 5'd1;
            end
        end
    end

endmodule

`default_nettype wire
