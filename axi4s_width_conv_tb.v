`timescale 1ns/1ps

module axi4s_width_conv_tb;

    reg         clk, rst_n;
    reg  [31:0] s_axis_tdata;
    reg         s_axis_tvalid;
    reg         s_axis_tlast;
    wire        s_axis_tready;
    wire [63:0] m_axis_tdata;
    wire        m_axis_tvalid;
    wire        m_axis_tlast;
    reg         m_axis_tready;

    integer pass_cnt;
    integer fail_cnt;

    // Instantiate DUT
    axi4s_width_conv dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .s_axis_tdata   (s_axis_tdata),
        .s_axis_tvalid  (s_axis_tvalid),
        .s_axis_tlast   (s_axis_tlast),
        .s_axis_tready  (s_axis_tready),
        .m_axis_tdata   (m_axis_tdata),
        .m_axis_tvalid  (m_axis_tvalid),
        .m_axis_tlast   (m_axis_tlast),
        .m_axis_tready  (m_axis_tready)
    );

    // Clock: 10ns period
    initial clk = 0;
    always #5 clk = ~clk;

    // Watchdog: a hang can never be silent
    initial begin
        #100000;
        $display("TIMEOUT: simulation hung");
        $finish;
    end

    // Count gated clock edges (for clock gating test)
    integer gclk_edges;
    initial gclk_edges = 0;
    always @(posedge dut.gated_clk) gclk_edges = gclk_edges + 1;

    // Task: drive one word onto the input (changes at negedge)
    task send_word;
        input [31:0] data;
        input        last;
        begin
            @(negedge clk);
            while (!s_axis_tready) @(negedge clk);

            s_axis_tdata  = data;
            s_axis_tvalid = 1'b1;
            s_axis_tlast  = last;

            // Hold for one clock
            @(posedge clk); #1;

            // Deassert
            s_axis_tvalid = 1'b0;
            s_axis_tlast  = 1'b0;
            s_axis_tdata  = 32'b0;
        end
    endtask

    // Task: wait for a valid && ready handshake and check the output
    task wait_and_check;
        input [63:0] expected;
        input        exp_last;
        input integer test_num;
        reg [63:0] got_data;
        reg        got_last;
        begin
            // Sample AT the clock edge, before the DUT's
            // nonblocking updates take effect
            @(posedge clk);
            while (!(m_axis_tvalid && m_axis_tready))
                @(posedge clk);

            got_data = m_axis_tdata;
            got_last = m_axis_tlast;

            $display("Output:   0x%016h | LAST=%b", got_data, got_last);
            $display("Expected: 0x%016h | LAST=%b", expected, exp_last);

            if (got_data === expected && got_last === exp_last) begin
                $display("TEST %0d: PASS\n", test_num);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("TEST %0d: FAIL\n", test_num);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    // Main test sequence
    initial begin
        pass_cnt = 0;
        fail_cnt = 0;

        $display("=== AXI4-Stream Width Converter Test ===");
        $display("32-bit Input to 64-bit Output");
        $display("=========================================");

        // Initialize
        rst_n         = 1'b0;
        s_axis_tdata  = 32'b0;
        s_axis_tvalid = 1'b0;
        s_axis_tlast  = 1'b0;
        m_axis_tready = 1'b1;
        repeat(4) @(posedge clk);

        // Release reset away from the clock edge
        @(negedge clk);
        rst_n = 1'b1;
        repeat(2) @(posedge clk);

        // ---------------------------------------------
        // TEST 1: Normal 2-word packet
        // ---------------------------------------------
        $display("--- TEST 1: Normal 2-word packet ---");
        $display("Word 0: 0xAAAA0001");
        $display("Word 1: 0xBBBB0002 (LAST)");

        send_word(32'hAAAA_0001, 1'b0);
        send_word(32'hBBBB_0002, 1'b1);
        wait_and_check(64'hBBBB_0002_AAAA_0001, 1'b1, 1);

        repeat(5) @(posedge clk);

        // ---------------------------------------------
        // TEST 2: Second 2-word packet
        // ---------------------------------------------
        $display("--- TEST 2: Second 2-word packet ---");
        $display("Word 0: 0x12345678");
        $display("Word 1: 0x9ABCDEF0 (LAST)");

        send_word(32'h1234_5678, 1'b0);
        send_word(32'h9ABC_DEF0, 1'b1);
        wait_and_check(64'h9ABC_DEF0_1234_5678, 1'b1, 2);

        repeat(5) @(posedge clk);

        // ---------------------------------------------
        // TEST 3: Odd-length packet (1 word + LAST)
        // ---------------------------------------------
        $display("--- TEST 3: Odd-length packet (1 word) ---");
        $display("Word 0: 0xDEADBEEF (LAST on first word)");

        send_word(32'hDEAD_BEEF, 1'b1);
        wait_and_check(64'h0000_0000_DEAD_BEEF, 1'b1, 3);

        repeat(5) @(posedge clk);

        // ---------------------------------------------
        // TEST 4: Backpressure
        // ---------------------------------------------
        $display("--- TEST 4: Backpressure test ---");
        $display("Downstream NOT ready initially...");

        @(negedge clk);
        m_axis_tready = 1'b0;           // block downstream

        send_word(32'hCAFE_0001, 1'b0);
        send_word(32'hCAFE_0002, 1'b1);

        repeat(5) @(posedge clk);
        #1;
        if (m_axis_tvalid && !m_axis_tready && !s_axis_tready &&
            m_axis_tdata === 64'hCAFE_0002_CAFE_0001) begin
            $display("Output correctly held, input stalled (backpressure OK)");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("Backpressure issue");
            fail_cnt = fail_cnt + 1;
        end

        // Release downstream away from the clock edge
        $display("Releasing downstream ready...");
        @(negedge clk);
        m_axis_tready = 1'b1;

        wait_and_check(64'hCAFE_0002_CAFE_0001, 1'b1, 4);

        repeat(5) @(posedge clk);

        // ---------------------------------------------
        // TEST 5: Back-to-back packets
        // ---------------------------------------------
        $display("--- TEST 5: Back-to-back packets (first packet) ---");

        send_word(32'hAAAA_AAAA, 1'b0);
        send_word(32'hBBBB_BBBB, 1'b1);
        wait_and_check(64'hBBBB_BBBB_AAAA_AAAA, 1'b1, 5);

        repeat(3) @(posedge clk);
        $display("--- TEST 6: Back-to-back packets (second packet) ---");
        send_word(32'hCCCC_CCCC, 1'b0);
        send_word(32'hDDDD_DDDD, 1'b1);
        wait_and_check(64'hDDDD_DDDD_CCCC_CCCC, 1'b1, 6);

        // ---------------------------------------------
        // TEST 7: Clock gating when idle
        // ---------------------------------------------
        $display("--- TEST 7: Clock gating when idle ---");
        repeat(3) @(posedge clk);       // let FSM settle in IDLE
        begin : gating_check
            integer before_cnt;
            before_cnt = gclk_edges;
            repeat(20) @(posedge clk);
            if (gclk_edges == before_cnt) begin
                $display("TEST 7: PASS (gated clock stopped while idle)\n");
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("TEST 7: FAIL (%0d gated edges while idle)\n",
                          gclk_edges - before_cnt);
                fail_cnt = fail_cnt + 1;
            end
        end

        // ---------------------------------------------
        // Done
        // ---------------------------------------------
        repeat(5) @(posedge clk);

        $display("=== ALL TESTS COMPLETE ===");
        $display("PASSED: %0d   FAILED: %0d", pass_cnt, fail_cnt);
        if (fail_cnt == 0)
            $display("RESULT: ALL PASS");
        else
            $display("RESULT: FAILURES PRESENT");

        $finish;
    end

    // Waveform dump
    initial begin
        $dumpfile("axi4s_conv.vcd");
        $dumpvars(0, axi4s_width_conv_tb);
    end

endmodule