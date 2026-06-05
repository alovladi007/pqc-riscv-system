// -----------------------------------------------------------------------------
// keccak_round.sv
//
// One round of Keccak-f[1600]. The full 24-round pipeline is built by either
// instantiating 24 of these (fully unrolled, large area) or iterating one
// instance over 24 cycles (small area, slow). Phase 3 will pick a 3- or
// 4-round folded variant as the area/throughput trade-off for Kyber's needs
// (each KEM operation calls SHA3-256 / SHAKE-128 / SHAKE-256 several times).
//
// State layout: 25 × 64-bit lanes, indexed [x][y] for x,y in [0,4].
// Round constants (RC[i]) come from a separate ROM (round_constants.sv).
// -----------------------------------------------------------------------------

`default_nettype none

module keccak_round (
    input  wire [63:0] state_in   [0:24],
    input  wire [63:0] round_const,
    output logic [63:0] state_out [0:24]
);

    // -----------------------------------------------------------------------
    // theta step
    //   C[x]    = A[x,0] ^ A[x,1] ^ A[x,2] ^ A[x,3] ^ A[x,4]
    //   D[x]    = C[x-1] ^ rotl(C[x+1], 1)
    //   A'[x,y] = A[x,y] ^ D[x]
    // -----------------------------------------------------------------------
    logic [63:0] C [0:4];
    logic [63:0] D [0:4];
    logic [63:0] A_theta [0:24];

    genvar gx, gy;
    generate
        for (gx = 0; gx < 5; gx++) begin : g_theta_C
            assign C[gx] = state_in[5*gx + 0] ^ state_in[5*gx + 1] ^
                           state_in[5*gx + 2] ^ state_in[5*gx + 3] ^
                           state_in[5*gx + 4];
        end
        for (gx = 0; gx < 5; gx++) begin : g_theta_D
            assign D[gx] = C[(gx + 4) % 5] ^ {C[(gx + 1) % 5][62:0], C[(gx + 1) % 5][63]};
        end
        for (gx = 0; gx < 5; gx++) begin : g_theta_x
            for (gy = 0; gy < 5; gy++) begin : g_theta_y
                assign A_theta[5*gx + gy] = state_in[5*gx + gy] ^ D[gx];
            end
        end
    endgenerate

    // -----------------------------------------------------------------------
    // rho + pi step
    //   B[y, 2x+3y] = rotl(A_theta[x,y], r[x,y])
    // -----------------------------------------------------------------------
    // Rotation offsets r[x][y].
    // Written as a function (case statement) rather than a localparam array
    // literal so Icarus Verilog accepts it — Icarus -g2012 mode rejects the
    // SystemVerilog '{...} array initializer that Verilator accepts.
    function automatic [6:0] rho_offset (input int unsigned xy);
        unique case (xy)
            // x=0
             0:  rho_offset = 7'd0;   1:  rho_offset = 7'd36;
             2:  rho_offset = 7'd3;   3:  rho_offset = 7'd41;
             4:  rho_offset = 7'd18;
            // x=1
             5:  rho_offset = 7'd1;   6:  rho_offset = 7'd44;
             7:  rho_offset = 7'd10;  8:  rho_offset = 7'd45;
             9:  rho_offset = 7'd2;
            // x=2
            10:  rho_offset = 7'd62; 11:  rho_offset = 7'd6;
            12:  rho_offset = 7'd43; 13:  rho_offset = 7'd15;
            14:  rho_offset = 7'd61;
            // x=3
            15:  rho_offset = 7'd28; 16:  rho_offset = 7'd55;
            17:  rho_offset = 7'd25; 18:  rho_offset = 7'd21;
            19:  rho_offset = 7'd56;
            // x=4
            20:  rho_offset = 7'd27; 21:  rho_offset = 7'd20;
            22:  rho_offset = 7'd39; 23:  rho_offset = 7'd8;
            24:  rho_offset = 7'd14;
            default: rho_offset = 7'd0;
        endcase
    endfunction

    logic [63:0] B [0:24];

    function automatic [63:0] rotl64 (input [63:0] x, input int unsigned n);
        logic [127:0] dup;
        dup = {x, x};
        return (n == 0) ? x : dup[127-n -: 64];
    endfunction

    generate
        for (gx = 0; gx < 5; gx++) begin : g_pi_x
            for (gy = 0; gy < 5; gy++) begin : g_pi_y
                // Widen the 7-bit rho_offset return to the 32-bit int unsigned
                // rotl64 expects, otherwise Verilator emits WIDTHEXPAND.
                assign B[5*gy + ((2*gx + 3*gy) % 5)] =
                    rotl64(A_theta[5*gx + gy], 32'(rho_offset(5*gx + gy)));
            end
        end
    endgenerate

    // -----------------------------------------------------------------------
    // chi step
    //   A''[x,y] = B[x,y] ^ ((~B[x+1,y]) & B[x+2,y])
    // -----------------------------------------------------------------------
    logic [63:0] A_chi [0:24];
    generate
        for (gx = 0; gx < 5; gx++) begin : g_chi_x
            for (gy = 0; gy < 5; gy++) begin : g_chi_y
                assign A_chi[5*gx + gy] =
                    B[5*gx + gy] ^ ((~B[5*((gx + 1) % 5) + gy]) & B[5*((gx + 2) % 5) + gy]);
            end
        end
    endgenerate

    // -----------------------------------------------------------------------
    // iota step (only state[0,0] gets XORed with the round constant)
    // -----------------------------------------------------------------------
    generate
        for (gx = 0; gx < 25; gx++) begin : g_iota
            if (gx == 0) begin : g_iota_xor
                assign state_out[gx] = A_chi[gx] ^ round_const;
            end else begin : g_iota_passthrough
                assign state_out[gx] = A_chi[gx];
            end
        end
    endgenerate

endmodule

`default_nettype wire
