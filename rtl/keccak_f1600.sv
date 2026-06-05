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

    // Combinational read via a fully decoded case statement.
    //
    // Background: a `assign read_data = state[read_addr];` style read
    // (selecting from an unpacked array by variable index) is correct
    // semantically and works in pure-SV testbenches under Icarus
    // (proved by tb/test_keccak_standalone.sv: lane 0 after f^24(0)
    // matches 0xF1258F7940E1DDE7). But cocotb's VPI binding under
    // Icarus reads X across that path — including with `always_ff
    // read_data <= state[read_addr]` registered version. Decoding
    // read_addr explicitly through a unique case statement avoids the
    // unpacked-array-by-variable-index path entirely.
    always_comb begin
        unique case (read_addr)
            5'd0:  read_data = state[0];   5'd1:  read_data = state[1];
            5'd2:  read_data = state[2];   5'd3:  read_data = state[3];
            5'd4:  read_data = state[4];   5'd5:  read_data = state[5];
            5'd6:  read_data = state[6];   5'd7:  read_data = state[7];
            5'd8:  read_data = state[8];   5'd9:  read_data = state[9];
            5'd10: read_data = state[10];  5'd11: read_data = state[11];
            5'd12: read_data = state[12];  5'd13: read_data = state[13];
            5'd14: read_data = state[14];  5'd15: read_data = state[15];
            5'd16: read_data = state[16];  5'd17: read_data = state[17];
            5'd18: read_data = state[18];  5'd19: read_data = state[19];
            5'd20: read_data = state[20];  5'd21: read_data = state[21];
            5'd22: read_data = state[22];  5'd23: read_data = state[23];
            5'd24: read_data = state[24];
            default: read_data = 64'd0;
        endcase
    end

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
    //
    // keccak_round uses PACKED 1600-bit bit-vector ports (not
    // unpacked arrays) because cocotb's VPI binding under Icarus
    // doesn't propagate unpacked array module ports — state_in
    // arrived as all-X in cocotb sim, causing round_out to be X.
    // Pack/unpack here, transparent to the algorithm.
    // -----------------------------------------------------------------
    logic [63:0]   round_out [0:24];
    logic [1599:0] state_packed;
    logic [1599:0] round_out_packed;

    genvar gp;
    generate
        for (gp = 0; gp < 25; gp++) begin : g_pack_state
            assign state_packed[gp*64 +: 64]    = state[gp];
            assign round_out[gp]                = round_out_packed[gp*64 +: 64];
        end
    endgenerate

    keccak_round u_round (
        .state_in_packed  (state_packed),
        .round_const      (rc_rom[round_idx]),
        .state_out_packed (round_out_packed)
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
    // Power-on init for the state array. Icarus -g2012 mishandles
    // `for (int i = 0; i < 25; i++) state[i] <= 64'd0;` inside an
    // always_ff reset branch — the array stays X. Initializing via
    // `initial` at elaboration is universally supported and gives the
    // same behaviour (X cannot occur on the simulator since state is
    // zeroed at time 0). On real silicon, the user is expected to
    // hold rst_n low briefly and then drive the load port; either way
    // the array is overwritten before the first round runs.
    // -----------------------------------------------------------------
    initial begin
        for (int i = 0; i < 25; i++) state[i] = 64'd0;
    end

    // -----------------------------------------------------------------
    // State register + load port + round commit
    // -----------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            round_idx <= 5'd0;
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
