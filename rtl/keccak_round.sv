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
    // Rotation offsets r[x][y]
    localparam int RHO_OFFSET [0:24] = '{
        // x = 0:        y=0  y=1  y=2  y=3  y=4
        /* x=0 */         0,   36,   3,  41,  18,
        /* x=1 */         1,   44,  10,  45,   2,
        /* x=2 */        62,    6,  43,  15,  61,
        /* x=3 */        28,   55,  25,  21,  56,
        /* x=4 */        27,   20,  39,   8,  14
    };

    logic [63:0] B [0:24];

    function automatic [63:0] rotl64 (input [63:0] x, input int n);
        return (n == 0) ? x : ({x, x} >> (64 - n));
    endfunction

    generate
        for (gx = 0; gx < 5; gx++) begin : g_pi_x
            for (gy = 0; gy < 5; gy++) begin : g_pi_y
                assign B[5*gy + ((2*gx + 3*gy) % 5)] =
                    rotl64(A_theta[5*gx + gy], RHO_OFFSET[5*gx + gy]);
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
            if (gx == 0) begin
                assign state_out[gx] = A_chi[gx] ^ round_const;
            end else begin
                assign state_out[gx] = A_chi[gx];
            end
        end
    endgenerate

endmodule

`default_nettype wire
