`timescale 1ns/1ps
`default_nettype none
// File-driven, one-row experiment. Python owns generation and independent golden.
module tb_VisualSingleMacro;
    parameter bit CLOCK_GATING = 1'b1;
    logic clock = 0;
    always #5 clock = ~clock;
    logic reset = 0;
    logic cim_ren = 0, cim_station = 1, cim_signed_en = 0, sram_wen = 0;
    logic [511:0] cim_idata = '0;
    logic [7:0] cim_raddr = 0, sram_waddr = 0;
    logic [3:0] cim_oc_mask = 0;
    logic [2:0] cim_precision = 0;
    logic [1:0] cim_phase = 0;
    logic [1023:0] sram_wdata = '0;
    wire [71:0] cim_odata;
    wire cim_odata_valid;
    wire [3:0] cim_odata_oc_mask;
    wire [1:0] cim_odata_phase;
    logic [3:0] sram_wmask = 0, cim_result_mask = 15;
    logic sram_ren = 0;
    logic [7:0] sram_raddr = 0;
    wire [1023:0] sram_rdata;
    SingleMacro #(.USE_CLOCK_GATING(CLOCK_GATING)) dut (.*);

    // Useful internal signals in a compact VCD; do not dump the SRAM array.
    wire observed_in_valid = dut.in_valid;
    wire observed_activation_signed = dut.activation_signed_in;
    wire [17:0] observed_correction = dut.correction_in;
    wire [71:0] observed_phase_sum = {dut.phase_sum[3], dut.phase_sum[2],
                                    dut.phase_sum[1], dut.phase_sum[0]};
    wire [43:0] observed_digit_sum_oc0 = {
        dut.g_oc[0].u_fusion.digit_sum[3], dut.g_oc[0].u_fusion.digit_sum[2],
        dut.g_oc[0].u_fusion.digit_sum[1], dut.g_oc[0].u_fusion.digit_sum[0]};

    // Six 1024-bit words: control, SRAM row, four zero-padded ACT buses.
    logic [1023:0] stimulus [0:5];
    string stimulus_path, result_path, trace_path, wave_path;
    integer results_fd, trace_fd;
    integer phase_count, issued = 0, received = 0, cycle = 0;
    integer issued_cycle [0:3];
    logic [3:0] seen = 0;

    always @(posedge clock) begin
        cycle = cycle + 1;
        if (!reset && cim_ren && (|cim_oc_mask)) begin
            if (issued >= phase_count || cim_phase != issued)
                $fatal(1, "VIS: unexpected issue phase");
            issued_cycle[cim_phase] = cycle;
            issued = issued + 1;
        end
        // Observe registered values after nonblocking assignments settle.
        #1;
        $fdisplay(trace_fd, "%0d,%0t,%b,%b,%b,%b,%0d,%b,%b,%0d,%018h",
            cycle, $time, reset, sram_wen, cim_ren, cim_oc_mask, cim_phase,
            observed_in_valid, cim_odata_valid, cim_odata_phase, cim_odata);
        if (!reset && cim_odata_valid === 1'b1) begin
            if ((^{cim_odata, cim_odata_phase, cim_odata_oc_mask}) === 1'bx)
                $fatal(1, "VIS: unknown output");
            if (cim_odata_phase >= phase_count || seen[cim_odata_phase])
                $fatal(1, "VIS: duplicate or unexpected result phase");
            if (cycle - issued_cycle[cim_odata_phase] != 1)
                $fatal(1, "VIS: output latency is not one cycle");
            if (cim_odata_oc_mask !== stimulus[0][7:4])
                $fatal(1, "VIS: output mask mismatch");
            seen[cim_odata_phase] = 1;
            received = received + 1;
            $fdisplay(results_fd, "%0d,%0d,%0t,%0d,%b,%018h,%072b,%0d,%0d,%0d,%0d",
                cim_odata_phase, cycle, $time, issued_cycle[cim_odata_phase],
                cim_odata_oc_mask, cim_odata, cim_odata,
                $signed(cim_odata[0 +: 18]), $signed(cim_odata[18 +: 18]),
                $signed(cim_odata[36 +: 18]), $signed(cim_odata[54 +: 18]));
        end
    end

    initial begin
        $timeformat(-9, 0, "", 0);
        if (!$value$plusargs("STIMULUS=%s", stimulus_path) ||
            !$value$plusargs("RESULTS=%s", result_path) ||
            !$value$plusargs("TRACE=%s", trace_path) ||
            !$value$plusargs("WAVE=%s", wave_path))
            $fatal(1, "VIS: missing file arguments");
        $readmemh(stimulus_path, stimulus);
        phase_count = stimulus[0][10:8];
        if (phase_count < 1 || phase_count > 4 || stimulus[0][7:4] == 0)
            $fatal(1, "VIS: invalid control word");
        results_fd = $fopen(result_path, "w");
        trace_fd = $fopen(trace_path, "w");
        if (!results_fd || !trace_fd) $fatal(1, "VIS: cannot open output files");
        $fdisplay(results_fd, "phase,output_cycle,time_ns,issue_cycle,mask,odata_hex,odata_binary,oc0_decimal,oc1_decimal,oc2_decimal,oc3_decimal");
        $fdisplay(trace_fd, "cycle,time_ns,reset,wen,ren,mask,issue_phase,in_valid,out_valid,out_phase,odata_hex");
        $dumpfile(wave_path);
        $dumpvars(1, tb_VisualSingleMacro);

        #1 reset = 1;
        repeat (2) @(negedge clock);
        reset = 0;
        @(negedge clock);
        sram_wen = 1;
        sram_wdata = stimulus[1];
        @(negedge clock);
        sram_wen = 0;
        cim_precision = stimulus[0][2:0];
        cim_signed_en = stimulus[0][3];
        cim_oc_mask = stimulus[0][7:4];
        for (integer p = 0; p < phase_count; p++) begin
            @(negedge clock);
            cim_ren = 1;
            cim_phase = p;
            cim_idata = stimulus[2+p][511:0];
        end
        @(negedge clock);
        cim_ren = 0;
        repeat (3) @(negedge clock);
        if (issued != phase_count || received != phase_count)
            $fatal(1, "VIS: missing requests/results issued=%0d received=%0d", issued, received);
        $fclose(results_fd);
        $fclose(trace_fd);
        $display("PASS visual_single issued=%0d received=%0d latency=1", issued, received);
        $finish;
    end
    initial begin
        #2000;
        $fatal(1, "VIS: timeout");
    end
endmodule
`default_nettype wire
