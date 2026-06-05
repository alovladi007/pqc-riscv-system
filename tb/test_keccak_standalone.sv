// -----------------------------------------------------------------------------
// test_keccak_standalone.sv
//
// Plain SV testbench (no cocotb) for diagnosing the Icarus X-on-read issue.
// Drives keccak_f1600 with the all-zero state and the expected result is the
// well-known Keccak-Team published vector:
//   f^24(0) lane 0 = 0xF1258F7940E1DDE7
//
// $display calls print the state at three points:
//   1. After reset (state should be zero from `initial` block)
//   2. After load    (state should be zero from the load port)
//   3. After done    (state should be the f^24(0) permutation)
//
// Compile: iverilog -g2012 -o /tmp/keccak_sim tb/test_keccak_standalone.sv \
//                   rtl/keccak_round.sv rtl/keccak_f1600.sv
// Run:     vvp /tmp/keccak_sim
// -----------------------------------------------------------------------------

`timescale 1ns/1ps

module test_keccak_standalone;
    logic clk = 0;
    always #5 clk = ~clk;

    logic        rst_n      = 0;
    logic        start      = 0;
    logic        load_en    = 0;
    logic [4:0]  load_addr  = 0;
    logic [63:0] load_data  = 0;
    logic [4:0]  read_addr  = 0;
    logic [63:0] read_data;
    logic        busy, done;

    keccak_f1600 dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .start     (start),
        .busy      (busy),
        .done      (done),
        .load_en   (load_en),
        .load_addr (load_addr),
        .load_data (load_data),
        .read_addr (read_addr),
        .read_data (read_data)
    );

    task dump_state(input string label);
        begin
            $display("=== %s ===", label);
            for (int i = 0; i < 25; i++) begin
                read_addr = i[4:0];
                #1;
                $display("  state[%0d] = 0x%016h", i, read_data);
            end
        end
    endtask

    initial begin
        // Reset
        rst_n = 0;
        #20;
        rst_n = 1;
        @(posedge clk);

        dump_state("after reset");

        // Load 25 lanes of zero
        for (int i = 0; i < 25; i++) begin
            load_en   = 1;
            load_addr = i[4:0];
            load_data = 64'd0;
            @(posedge clk);
        end
        load_en = 0;
        @(posedge clk);

        dump_state("after load (all zero)");

        // Start permutation
        start = 1;
        @(posedge clk);
        start = 0;

        // Wait for done (with a generous cap)
        for (int cyc = 0; cyc < 100; cyc++) begin
            @(posedge clk);
            if (done) begin
                $display("done asserted at cycle %0d", cyc);
                break;
            end
        end
        if (!done) $display("FAIL: done never asserted");

        // Wait one more cycle for state to settle
        @(posedge clk);

        dump_state("after f^24(0)");

        // Check the canonical value
        read_addr = 0;
        #1;
        if (read_data == 64'hF1258F7940E1DDE7)
            $display("PASS: lane 0 matches published 0xF1258F7940E1DDE7");
        else
            $display("FAIL: lane 0 = 0x%016h (expected 0xF1258F7940E1DDE7)", read_data);

        $finish;
    end

    initial begin
        #5000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
