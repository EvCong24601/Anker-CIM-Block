`timescale 1ns/1ps

// Testbench for SRAM_MBIST/hdsram256w512b_mbist_top and the actual
// hdsram256w512btop behavioral SRAM model.
//
// Compile using hdsram256w512b_readmask.f with VCS_HOME/VERDI_HOME set:
//   vcs -full64 -f hdsram256w512b_readmask.f -o simv_readmask
//   ./simv_readmask -no_save
//
// This testbench always writes hdsram256w512b_mbist_top.fsdb.  Compile with the
// VCS/Verdi environment enabled so the FSDB system tasks are linked.
//
// Set RUN_FAULT_TEST=1 to additionally run the legacy physical-bit fault
// detection check after the two-pass repair-return and read-mask checks.
module tb_hdsram256w512b_mbist_top #(
    parameter bit RUN_FAULT_TEST = 1'b0
);
    reg clk;
    reg rst_n;
    // Normal single-port SRAM interface.  Keep the port inactive during
    // MBIST; hdsram256w512b_mbist_top muxes in the MBIST-generated pins.
    reg sram_cen;
    reg sram_wen;
    reg [7:0] sram_addr;
    reg [511:0] sram_din;
    reg [1:0] read_mask;
    reg [1:0] write_mask;
    reg test_memory_start;
    reg [7:0] timing_config;
    reg [7:0] test_red_sbk3;
    reg [7:0] test_red_sbk2;
    reg [7:0] test_red_sbk1;
    reg [7:0] test_red_sbk0;
    reg waen;
    reg raen;

    wire test_done;
    wire test_busy;
    wire test_memory_valid;
    wire out_of_repair;
    wire [515:0] test_error_BL;
    wire [7:0] test_error_sbk0_BL, test_error_sbk1_BL;
    wire [7:0] test_error_sbk2_BL, test_error_sbk3_BL;
    wire redsbk0OUT, redsbk1OUT, redsbk2OUT, redsbk3OUT;
    wire [511:0] sram_dout;
    integer cycles;
    bit timed_out;
    // Keep expected/previous values in the FSDB for direct waveform comparison.
    reg [511:0] mask_expected;
    reg [511:0] mask_previous_dout;
    integer mask_checks;

    hdsram256w512b_mbist_top dut (
        .CK                (clk),
        .rst_n             (rst_n),
        .CEN               (sram_cen),
        .WEN               (sram_wen),
        .ADDR              (sram_addr),
        .DIN               (sram_din),
        .read_mask         (read_mask),
        .write_mask        (write_mask),
        .DOUT              (sram_dout),
        .test_memory_start (test_memory_start),
        .timing_config     (timing_config),
        .test_red_sbk3     (test_red_sbk3),
        .test_red_sbk2     (test_red_sbk2),
        .test_red_sbk1     (test_red_sbk1),
        .test_red_sbk0     (test_red_sbk0),
        .waen              (waen),
        .raen              (raen),
        .test_done         (test_done),
        .test_busy         (test_busy),
        .test_memory_valid (test_memory_valid),
        .out_of_repair     (out_of_repair),
        .test_error_BL     (test_error_BL),
        .test_error_sbk0_BL(test_error_sbk0_BL),
        .test_error_sbk1_BL(test_error_sbk1_BL),
        .test_error_sbk2_BL(test_error_sbk2_BL),
        .test_error_sbk3_BL(test_error_sbk3_BL),
        .redsbk0OUT        (redsbk0OUT),
        .redsbk1OUT        (redsbk1OUT),
        .redsbk2OUT        (redsbk2OUT),
        .redsbk3OUT        (redsbk3OUT)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    // The external write_mask is deliberately set to 01 during MBIST in the
    // main sequence.  The wrapper must override it with a full-word write.
    always @(posedge clk) begin
        if (dut.mbist_select && dut.macro_write_mask !== 2'b11)
            $fatal(1, "MBIST write mask was not forced to 11: %b",
                   dut.macro_write_mask);
    end
`ifdef DEBUG
    always @(posedge clk) begin
        #2;
        if (dut.u_mbist.testMemory && dut.u_mbist.test_ren)
            $display("READ t=%0t case=%0d addr=%0d step=%0d dout=%h exp=%h err=%h", $time,
                     dut.u_mbist.case_id, dut.u_mbist.address, dut.u_mbist.step,
                     dut.u_sram.DOUT, dut.u_mbist.expected_data, dut.u_mbist.compare_error);
        if (dut.u_mbist.testMemory && dut.u_mbist.test_wen)
            $display("WRITE t=%0t case=%0d addr=%0d step=%0d din=%h", $time,
                     dut.u_mbist.case_id, dut.u_mbist.address, dut.u_mbist.step,
                     dut.u_sram.DIN);
    end
`endif

    initial begin
        $fsdbDumpfile("hdsram256w512b_mbist_top.fsdb");
        // +all is required with the current Verdi dumper to retain signals
        // from optimized SV scopes in the standalone FSDB signal tree.
        $fsdbDumpvars(0, tb_hdsram256w512b_mbist_top, "+all");
        $fsdbDumpMDA();
        $fsdbDumpon();
    end

    task automatic reset_dut;
        begin
            rst_n = 1'b0;
            test_memory_start = 1'b0;
            repeat (4) @(posedge clk);
            #1;
            rst_n = 1'b1;
            repeat (2) @(posedge clk);
            #1;
        end
    endtask

    task automatic start_mbist;
        begin
            @(posedge clk);
            #1 test_memory_start = 1'b1;
            @(posedge clk);
            #1 test_memory_start = 1'b0;
        end
    endtask

    task automatic wait_for_done;
        output bit timed_out;
        begin
            timed_out = 1'b1;
            for (cycles = 0; cycles < 12000; cycles = cycles + 1) begin
                @(posedge clk);
                #1;
                if (test_done) begin
                    timed_out = 1'b0;
                    disable wait_for_done;
                end
            end
        end
    endtask

    // Run one complete MBIST and print the complete result set.  The
    // reference FP4TE testbench uses the same two-pass flow: capture the
    // first report, feed it back as repair data, then run MBIST again.
    task automatic run_mbist_and_report(input integer run_number);
        begin
            start_mbist();
            if (test_busy !== 1'b1)
                $fatal(1, "MBIST%0d did not enter busy state", run_number);
            wait_for_done(timed_out);
            if (timed_out || test_done !== 1'b1)
                $fatal(1, "MBIST%0d timed out", run_number);

            $display("============================================================");
            $display("MBIST%0d RESULT: cycles=%0d done=%b busy=%b valid=%b out_of_repair=%b",
                     run_number, cycles, test_done, test_busy,
                     test_memory_valid, out_of_repair);
            $display("MBIST%0d test_error_BL[515:0] = %h", run_number, test_error_BL);
            $display("MBIST%0d repair reports bank3..0 = %h_%h_%h_%h",
                     run_number, test_error_sbk3_BL, test_error_sbk2_BL,
                     test_error_sbk1_BL, test_error_sbk0_BL);
            $display("MBIST%0d applied repair bank3..0 = %h_%h_%h_%h",
                     run_number, dut.repair3, dut.repair2, dut.repair1, dut.repair0);
            $display("============================================================");
        end
    endtask

    // Both halves must differ between A and B.  Rewrite the array between
    // masked reads so an accidental full read cannot pass as a masked read.
    task automatic check_read_mask_case(
        input integer case_number,
        input [7:0] row,
        input [511:0] pattern_a,
        input [511:0] pattern_b
    );
        reg [511:0] pattern_c, pattern_d;
        begin
            pattern_c = ~pattern_b;
            pattern_d = ~pattern_a;
            if ($isunknown({pattern_a, pattern_b}) ||
                pattern_a[511:256] == pattern_b[511:256] ||
                pattern_a[255:0] == pattern_b[255:0] ||
                pattern_a[511:256] == pattern_c[511:256] ||
                pattern_b[255:0] == pattern_d[255:0])
                $fatal(1, "MASK%0d stimulus must distinguish old/new data in both halves", case_number);

            @(negedge clk);
            sram_cen  = 1'b0;
            sram_wen  = 1'b0;
            sram_addr = row;
            sram_din  = pattern_a;
            read_mask = 2'b11;
            write_mask = 2'b11;
            @(posedge clk); #2;

            @(negedge clk);
            sram_wen  = 1'b1;
            read_mask = 2'b11;
            @(posedge clk); #2;
            mask_expected = pattern_a;
            if (sram_dout !== pattern_a)
                $fatal(1, "MASK%0d initial full read mismatch: got=%h exp=%h",
                       case_number, sram_dout, pattern_a);
            mask_checks = mask_checks + 1;
            $display("MASK%0d row=%0d INITIAL 11: HIGH=%h LOW=%h", case_number, row,
                     sram_dout[511:256], sram_dout[255:0]);

            @(negedge clk);
            sram_wen = 1'b0;
            sram_din = pattern_b;
            write_mask = 2'b01;
            @(posedge clk); #2;
            if (sram_dout !== pattern_a)
                $fatal(1, "MASK%0d write B changed DOUT", case_number);

            @(negedge clk);
            mask_previous_dout = sram_dout;
            sram_wen = 1'b1;
            read_mask = 2'b01;
            @(posedge clk); #2;
            mask_expected = {pattern_a[511:256], pattern_b[255:0]};
            $display("MASK%0d row=%0d mode=01: HIGH=%h (hold A) LOW=%h (new B)",
                     case_number, row, sram_dout[511:256], sram_dout[255:0]);
            if (sram_dout !== mask_expected)
                $fatal(1, "MASK%0d mode=01 got=%h expected=%h", case_number, sram_dout, mask_expected);
            if (sram_dout === pattern_b)
                $fatal(1, "MASK%0d mode=01 incorrectly read the complete new word B", case_number);
            mask_checks = mask_checks + 1;

            // C changes the stored low half too.  A read of C with mask 10
            // must leave the B low half on DOUT, even though memory holds C.
            @(negedge clk);
            sram_wen = 1'b0;
            sram_din = pattern_c;
            write_mask = 2'b10;
            @(posedge clk); #2;
            if (sram_dout !== mask_expected)
                $fatal(1, "MASK%0d write C changed DOUT", case_number);

            @(negedge clk);
            mask_previous_dout = sram_dout;
            sram_wen = 1'b1;
            read_mask = 2'b10;
            @(posedge clk); #2;
            mask_expected = {pattern_c[511:256], pattern_b[255:0]};
            $display("MASK%0d row=%0d mode=10: HIGH=%h (new C) LOW=%h (hold B)",
                     case_number, row, sram_dout[511:256], sram_dout[255:0]);
            if (sram_dout !== mask_expected)
                $fatal(1, "MASK%0d mode=10 got=%h expected=%h", case_number, sram_dout, mask_expected);
            if (sram_dout === pattern_c)
                $fatal(1, "MASK%0d mode=10 incorrectly read the complete new word C", case_number);
            mask_checks = mask_checks + 1;

            @(negedge clk);
            sram_wen = 1'b0;
            sram_din = pattern_d;
            write_mask = 2'b11;
            @(posedge clk); #2;
            if (sram_dout !== mask_expected)
                $fatal(1, "MASK%0d write D changed DOUT", case_number);

            @(negedge clk);
            mask_previous_dout = sram_dout;
            sram_wen = 1'b1;
            read_mask = 2'b11;
            @(posedge clk); #2;
            mask_expected = pattern_d;
            $display("MASK%0d row=%0d mode=11: HIGH=%h (new D) LOW=%h (new D)",
                     case_number, row, sram_dout[511:256], sram_dout[255:0]);
            if (sram_dout !== mask_expected)
                $fatal(1, "MASK%0d final mode=11 mismatch", case_number);
            mask_checks = mask_checks + 1;

            // A zero write mask is a hold/no-op.  Verify that it cannot
            // change either the registered output or the stored word.
            @(negedge clk);
            sram_wen = 1'b0;
            sram_din = ~pattern_d;
            write_mask = 2'b00;
            @(posedge clk); #2;
            if (sram_dout !== mask_expected)
                $fatal(1, "MASK%0d write mask=00 changed DOUT", case_number);

            @(negedge clk);
            sram_wen = 1'b1;
            read_mask = 2'b11;
            @(posedge clk); #2;
            if (sram_dout !== pattern_d)
                $fatal(1, "MASK%0d write mask=00 changed stored data: got=%h exp=%h",
                       case_number, sram_dout, pattern_d);
            mask_checks = mask_checks + 1;

            @(negedge clk);
            mask_previous_dout = sram_dout;
            read_mask = 2'b00;
            @(posedge clk); #2;
            mask_expected = 'x;
            if (sram_dout !== mask_expected)
                $fatal(1, "MASK%0d mode=00 expected X, got=%h", case_number, sram_dout);
            $display("MASK%0d row=%0d mode=00 data=%h (undefined/X)",
                     case_number, row, sram_dout);
            mask_checks = mask_checks + 1;
            @(negedge clk);
            sram_cen = 1'b1;
        end
    endtask

    initial begin
        timing_config = 8'd0;
        sram_cen = 1'b1;
        sram_wen = 1'b1;
        sram_addr = 8'd0;
        sram_din = 512'd0;
        read_mask = 2'b11;
        write_mask = 2'b11;
        test_red_sbk3 = 8'd0;
        test_red_sbk2 = 8'd0;
        test_red_sbk1 = 8'd0;
        test_red_sbk0 = 8'd0;
        waen = 1'b0;
        raen = 1'b0;
        mask_expected = 'x;
        mask_previous_dout = 'x;
        mask_checks = 0;

        reset_dut();

        // First MBIST run.  Keep both external masks at 01 deliberately;
        // the wrapper must force 11 for reads and writes while MBIST owns the
        // SRAM port.
        read_mask = 2'b01;
        write_mask = 2'b01;
        run_mbist_and_report(1);

        // Return all reported error codes to the SRAM repair inputs, exactly
        // as the reference FP4TE testbench returns its four repair reports.
        @(negedge clk);
        test_red_sbk0 = test_error_sbk0_BL;
        test_red_sbk1 = test_error_sbk1_BL;
        test_red_sbk2 = test_error_sbk2_BL;
        test_red_sbk3 = test_error_sbk3_BL;
        $display("RETURN REPAIR TO SRAM bank3..0 = %h_%h_%h_%h",
                 test_red_sbk3, test_red_sbk2, test_red_sbk1, test_red_sbk0);
        repeat (2) @(posedge clk);

        // Second MBIST run after repair-code return.
        run_mbist_and_report(2);
        if (test_memory_valid !== 1'b1 || out_of_repair !== 1'b0)
            $fatal(1, "MBIST2 after repair return failed: valid=%b out_of_repair=%b",
                   test_memory_valid, out_of_repair);
        $display("BIST REPAIR RETURN PASS");

        // Run several read-mask cases with nontrivial data.  This also makes
        // the mask activity visible in both the transcript and the FSDB.
        check_read_mask_case(0, 8'h03,
            {{8{32'hA100_0001}}, 256'h0123_4567_89ab_cdef_0011_2233_4455_6677_8899_aabb_ccdd_eeff_1357_9bdf_2468_ace0},
            {{8{32'hB200_0002}}, 256'hfedc_ba98_7654_3210_f0e1_d2c3_b4a5_9687_7766_5544_3322_1100_eca8_6420_ffff_0001});
        check_read_mask_case(1, 8'h55,
            {{8{32'hC300_0003}}, 256'hffff_0000_aaaa_5555_3333_cccc_9696_6969_5a5a_a5a5_0f0f_f0f0_1234_5678_9abc_def0},
            {{8{32'hD400_0004}}, 256'h0000_ffff_5555_aaaa_cccc_3333_6969_9696_a5a5_5a5a_f0f0_0f0f_0fed_cba9_8765_4321});
        check_read_mask_case(2, 8'ha6,
            {{8{32'hE500_0005}}, 256'h0001_0002_0004_0008_0010_0020_0040_0080_0100_0200_0400_0800_1000_2000_4000_8000},
            {{8{32'hF600_0006}}, 256'h8000_4000_2000_1000_0800_0400_0200_0100_0080_0040_0020_0010_0008_0004_0002_0001});
        check_read_mask_case(3, 8'h00,
            {{8{32'h1122_3344}}, {8{32'h5566_7788}}},
            {{8{32'h9988_7766}}, {8{32'h1234_5678}}});
        check_read_mask_case(4, 8'hff,
            {{8{32'h0102_0304}}, {8{32'hA0B0_C0D0}}},
            {{8{32'h1020_3040}}, {8{32'h0A0B_0C0D}}});
        check_read_mask_case(5, 8'h2a,
            {{8{32'hAAAA_5555}}, {8{32'h3333_CCCC}}},
            {{8{32'h0F0F_F0F0}}, {8{32'h6969_9696}}});
        $display("READ/WRITE_MASK PASS: 6 rows, %0d output checks; 01/10 preserve unselected data", mask_checks);

        if (RUN_FAULT_TEST) begin
            reset_dut();
            start_mbist();
            if (test_busy !== 1'b1)
                $fatal(1, "Fault MBIST did not enter busy state");

            // At case3/address 0x36, expected pattern A has bit 0 = 0.
            wait (dut.u_mbist.case_id == 5'd3 &&
                  dut.u_mbist.address == 8'h36 &&
                  dut.u_mbist.step == 3'd0);
            @(posedge clk);
            #0.1;
            force dut.u_sram.physical_mem[8'h36][0] = 1'b1;
            #3.0;
            release dut.u_sram.physical_mem[8'h36][0];

            wait_for_done(timed_out);
            if (timed_out || test_done !== 1'b1)
                $fatal(1, "Fault MBIST timed out");
            if (test_memory_valid !== 1'b0 || out_of_repair !== 1'b1 || test_error_BL === 516'd0)
                $fatal(1, "Injected fault was not reported: valid=%b out_of_repair=%b error=%h",
                       test_memory_valid, out_of_repair, test_error_BL);
            $display("FAULT MBIST PASS: injected BL fault detected, error=%h", test_error_BL);
        end

        $finish;
    end
endmodule
