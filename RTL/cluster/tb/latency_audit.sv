`timescale 1ns / 1ps
// Independent observation module; no changes to the DUT or its external pins.
module latency_audit;
  integer fd;
  int tick = 0, origin, precision_code, sign_mode, os, ws, as_count, case_id, last_case = -1;
  int final_input[0:15];
  bit [31:0] lane_seen[0:15];
  bit logged[0:15];
  int ctx;
  bit selected;
  initial begin
    string data_dir;
    data_dir = ".";
    if ($value$plusargs("DATA_DIR=%s", data_dir)) begin
    end
    fd = $fopen($sformatf("%s/latency_audit.csv", data_dir), "w");
    if (!fd) $fatal(1, "Cannot create audit trace");
    $fdisplay(fd, "case,precision,signed_en,os,ws,as,context,last_input,raw_output,delta");
  end
  always @(posedge tb_Cluster.clock) begin
    tick++;
    if (tb_Cluster.monitoring && tb_Cluster.cmd_valid_i && tb_Cluster.cmd_ready_o) begin
      if (tb_Cluster.cases_run != last_case) begin
        last_case = tb_Cluster.cases_run;
        origin = tick;
        selected = tb_Cluster.exact_ii && tb_Cluster.standard_case != 0;
        case_id = tb_Cluster.standard_case;
        precision_code = int'(tb_Cluster.cmd_i.precision);
        sign_mode = int'(tb_Cluster.cmd_i.signed_en);
        os = tb_Cluster.case_os;
        ws = tb_Cluster.case_ws;
        as_count = tb_Cluster.case_as;
        for (int c = 0; c < 16; c++) begin
          lane_seen[c] = '0;
          logged[c] = 0;
        end
      end
    end
    if (selected && tb_Cluster.monitoring && tb_Cluster.dut.issue && tb_Cluster.dut.final_issue)
      final_input[tb_Cluster.dut.context_idx] = tick - origin;
    #2;
    // Per-OC publication pulses out_valid_o per lane. Log one row per
    // Context once its LAST reserved lane has pulsed: the tick still marks
    // the whole-Context terminal latency 3T/4T/5T.
    if (selected && tb_Cluster.monitoring && tb_Cluster.dut.raw_valid != 0) begin
      for (int l = 0; l < 32; l++)
      if (tb_Cluster.out_valid_o[l]) begin
        ctx = tb_Cluster.dut.raw_context[l];
        if (ctx < 0 || ctx >= 16 || lane_seen[ctx][l]) $fatal(1, "Invalid/duplicate audit lane Context tag");
        lane_seen[ctx][l] = 1;
      end
      for (int c = 0; c < tb_Cluster.case_r; c++)
      if (!logged[c] && lane_seen[c] == tb_Cluster.expected_mask) begin
        logged[c] = 1;
        $fdisplay(fd, "%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d", case_id, precision_code, sign_mode, os, ws, as_count,
                  c, final_input[c], tick - origin, tick - origin - final_input[c]);
        $fflush(fd);
      end
    end
  end
endmodule
