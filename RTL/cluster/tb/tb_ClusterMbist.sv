`timescale 1ns/1ps
module tb_ClusterMbist #(parameter bit USE_CLOCK_GATING = 1);
  import cluster_pkg::*;
  logic clock = 0, reset_n = 0;
  always #5 clock = !clock;
  cluster_ctrl_t cmd_i = '0;
  logic cmd_valid_i = 0, act_valid_i = 0, weight_valid_i = 0;
  wire cmd_ready_o, act_ready_o, weight_ready_o;
  logic [1023:0] act_data_i = {256{4'h1}};
  logic [7:0] weight_raddr_i = 37;
  logic sram_cs_en = 0, sram_wr_en = 0, sram_macro_group = 0;
  logic [1:0] sram_bank_sel = 0;
  logic [7:0] sram_row_addr = 37;
  logic [3:0] sram_wmask = 0;
  logic [1023:0] sram_wrdata = 0;
  logic [7:0] timing_config_i = 0;
  logic waen_i = 0, raen_i = 0;
  wire [1023:0] sram_rd_data, raw_psum;
  wire sram_rd_valid;
  wire [31:0] psum_valid;

  logic [2:0] mbist_macro_id_i = 0;
  logic [63:0] mbist_test_red_sbk_i = 0;
  logic mbist_test_memory_start_i = 0;
  wire [63:0] mbist_test_error_sbk_o;
  wire mbist_test_busy_o, mbist_test_done_o, mbist_test_memory_valid_o, mbist_out_of_repair_o;
  cluster_top #(.USE_CLOCK_GATING(USE_CLOCK_GATING)) dut (.*);

  for (genvar m = 0; m < 8; m++) begin : g_timing_broadcast_check
    for (genvar bank = 0; bank < 2; bank++) begin : g_bank
      always @(negedge clock) if (reset_n) begin
        if (dut.g_macro[m].u_macro.u_weight_sram.g_bank[bank].u_wrapper.timing_config !== dut.timing_config_q ||
            dut.g_macro[m].u_macro.u_weight_sram.g_bank[bank].u_wrapper.waen !== dut.waen_q ||
            dut.g_macro[m].u_macro.u_weight_sram.g_bank[bank].u_wrapper.raen !== dut.raen_q)
          $fatal(1, "SRAM timing control broadcast failed macro=%0d bank=%0d", m, bank);
      end
    end
  end

  // Hold physical cells stuck low between write and read edges. Repair
  // bypasses the same physical fault during both retest and functional use.
  bit inject_single, inject_double;
  for (genvar bank = 0; bank < 2; bank++) begin : g_bank_fault
    for (genvar sbk = 0; sbk < 4; sbk++) begin : g_subbank_fault
      // Distinct column numbers expose swapped bytes in either direction.
      localparam int COLUMN = 12 + 7*(4*bank + sbk);
      always @(negedge clock)
        if (inject_single)
          dut.g_macro[5].u_macro.u_weight_sram.g_bank[bank].u_wrapper.u_sram.physical_mem[256*sbk+37][COLUMN] = 0;
    end
  end
  always @(negedge clock) begin
    if (inject_double)
      dut.g_macro[2].u_macro.u_weight_sram.g_bank[1].u_wrapper.u_sram.physical_mem[37][19:18] = 0;
  end

  task automatic launch(input logic [2:0] id, input logic [63:0] cfg);
    mbist_macro_id_i = id;
    mbist_test_red_sbk_i = cfg;
    mbist_test_memory_start_i = 1;
    @(negedge clock);
    mbist_test_memory_start_i = 0;
    // Repair input remains independently applied while this Macro is selected.
    // Cluster accepts the sampled start pulse one edge later.
    @(negedge clock);
    if ({mbist_test_busy_o, mbist_test_done_o} !== 2'b10) $fatal(1, "launch status");
  endtask

  task automatic finish_test(input logic [2:0] id);
    int cycles;
    cycles = 0;
    while (mbist_test_busy_o && cycles < 9600) begin
      if (mbist_test_done_o !== 0 || cmd_ready_o !== 0) $fatal(1, "busy protocol");
      if (cycles == 10 && dut.bist_busy !== (8'b1 << id)) $fatal(1, "wrong Macro active");
      @(negedge clock);
      cycles++;
    end
    if (cycles < 9400 || {mbist_test_busy_o,mbist_test_done_o} !== 2'b01)
      $fatal(1, "premature completion or timeout id=%d cycles=%d", id, cycles);
  endtask

  task automatic access_row(input logic [2:0] id, input bit write_access,
                            input logic [3:0] mask, input logic [1023:0] data);
    {sram_macro_group,sram_bank_sel} = id;
    sram_wr_en = write_access;
    sram_wrdata = data;
    sram_wmask = mask;
    sram_cs_en = 1;
    @(negedge clock);
    if (!write_access && (sram_rd_valid !== 1 || sram_rd_data !== data))
      $fatal(1, "functional read failed id=%d", id);
    sram_cs_en = 0;
    sram_wr_en = 0;
    @(negedge clock);
  endtask

  // One W4A4 dot product on OC0 of Macro 5, all 64 activations equal 1.
  task automatic compute(input int expected, output int latency);
    cmd_i.cim_os_cnt = 1;
    cmd_i.cim_as_cnt = 1;
    cmd_i.cim_ws_cnt = 1;
    cmd_i.cim_reduce_split_mask = '1;
    cmd_i.cim_macro_en_mask = 8'h20;
    cmd_i.cim_macro_oc_mask = 32'h0010_0000;
    cmd_i.cim_precision = 2;
    {cmd_valid_i, act_valid_i, weight_valid_i} = 3'b111;
    @(posedge clock);
    if ({cmd_ready_o,act_ready_o,weight_ready_o} !== 3'b111) $fatal(1, "compute handshake");
    @(negedge clock);
    {cmd_valid_i, act_valid_i, weight_valid_i} = 0;
    latency = 0;
    while (!psum_valid && latency < 12) begin
      @(negedge clock);
      latency++;
    end
    if (psum_valid !== 32'h0010_0000 || raw_psum[32*20+:32] !== expected)
      $fatal(1, "compute result mask=%h lane20=%d expected=%d", psum_valid, raw_psum[32*20+:32], expected);
    repeat (8) @(negedge clock);
  endtask

  localparam logic [63:0] REPAIR5 = 64'hbdb6afa8_a19a938c;
  localparam logic [1023:0] ONES = {256{4'h1}};
  // Corrupt only the final read in the entire sequence. Earlier reads of
  // this cell pass, so the error must survive the final compare-to-result edge.
  wire final_read = dut.g_macro[7].u_macro.u_weight_sram.g_bank[0].u_wrapper.mbist_test_ren &&
                    dut.g_macro[7].u_macro.u_weight_sram.g_bank[0].u_wrapper.u_mbist.case_id == 17 &&
                    dut.g_macro[7].u_macro.u_weight_sram.g_bank[0].u_wrapper.macro_addr == 255;
  bit inject_final_read;
  // Observe the issued read after CK's NBA updates and inject before clk_d.
  always @(posedge clock)
    #1ps if (inject_final_read && final_read)
      dut.g_macro[7].u_macro.u_weight_sram.g_bank[0].u_wrapper.u_sram.physical_mem[255][5] = 0;

  int before_latency, after_latency;
  initial begin
    repeat (3) @(negedge clock);
    reset_n = 1;
    timing_config_i = 8'hA5;
    waen_i = 1;
    raen_i = 0;
    if ({dut.timing_config_q, dut.waen_q, dut.raen_q} !== 10'b0)
      $fatal(1, "timing control changed before sampling edge");
    @(negedge clock);
    if ({dut.timing_config_q, dut.waen_q, dut.raen_q} !== {8'hA5, 1'b1, 1'b0})
      $fatal(1, "timing control sample failed");
    timing_config_i = 8'h3C;
    waen_i = 0;
    raen_i = 1;
    @(negedge clock);
    if ({dut.timing_config_q, dut.waen_q, dut.raen_q} !== {8'h3C, 1'b0, 1'b1})
      $fatal(1, "timing control resample failed");
    access_row(3, 1, 0, ~ONES);
    access_row(5, 1, 0, ONES);
    compute(64, before_latency);
    inject_single = 1;
    launch(5, 0);
    finish_test(5);
    if ({mbist_test_memory_valid_o, mbist_out_of_repair_o} !== 2'b00 ||
        mbist_test_error_sbk_o !== REPAIR5) $fatal(1, "repairable report %h", mbist_test_error_sbk_o);
    if (dut.hold_valid[5] !== 0 || dut.g_macro[5].u_macro.hold_valid !== 0)
      $fatal(1, "stale functional hold");

    // Return the repair code while start remains low, as in the standalone
    // SRAM template. It must take effect before the second MBIST run.
    mbist_macro_id_i = 5;
    mbist_test_red_sbk_i = REPAIR5;
    repeat (2) @(negedge clock);
    if (mbist_test_busy_o !== 0 || dut.g_macro[5].u_macro.repair_config !== REPAIR5)
      $fatal(1, "repair input did not update independently of start");
    access_row(5, 1, 0, ONES);
    access_row(5, 0, 0, ONES);

    launch(5, REPAIR5);
    finish_test(5);
    if ({mbist_test_memory_valid_o, mbist_out_of_repair_o, mbist_test_error_sbk_o} !== {2'b10,64'd0})
      $fatal(1, "repair retest");

    inject_double = 1;
    launch(2, 0);
    // An unrelated start pulse while busy must leave the active request alone.
    repeat (4) @(negedge clock);
    mbist_test_memory_start_i = 1;
    @(negedge clock);
    mbist_test_memory_start_i = 0;
    finish_test(2);
    if ({mbist_test_memory_valid_o, mbist_out_of_repair_o} !== 2'b01 ||
        mbist_test_error_sbk_o[39] !== 1 || (mbist_test_error_sbk_o & ~64'hff00000000) !== 0)
      $fatal(1, "unrepairable report %h", mbist_test_error_sbk_o);
    if (dut.g_macro[5].u_macro.repair_config !== REPAIR5) $fatal(1, "lost repair configuration");
    access_row(3, 0, 0, ~ONES);
    access_row(5, 0, 0, '0);
    access_row(5, 1, 0, ONES);
    access_row(5, 1, 4'b1110, {256{4'hf}});
    access_row(5, 0, 0, {{192{4'h1}},{64{4'hf}}});
    compute(960, after_latency);
    if (before_latency != after_latency) $fatal(1, "compute latency changed");

    launch(7, '1);
    repeat (20) @(negedge clock);
    reset_n = 0;
    @(negedge clock);
    if ({mbist_test_busy_o, mbist_test_done_o, dut.bist_busy, dut.g_macro[5].u_macro.repair_config} !== '0)
      $fatal(1, "reset during MBIST");
    reset_n = 1;
    launch(7, 0);
    finish_test(7);
    if ({mbist_test_memory_valid_o,mbist_out_of_repair_o,mbist_test_error_sbk_o} !== {2'b10,64'd0})
      $fatal(1, "restart after reset");
    inject_final_read = 1;
    launch(7, 0);
    finish_test(7);
    if ({mbist_test_memory_valid_o,mbist_out_of_repair_o,mbist_test_error_sbk_o} !== {2'b00,64'h85})
      $fatal(1, "last read missing from final result");
    $display("PASS cluster MBIST gating=%d compute latency=%d", USE_CLOCK_GATING, after_latency);
    $finish;
  end
`ifdef CLUSTER_FSDB
  initial begin
    string fsdb_file;
    if (!$value$plusargs("FSDB_FILE=%s", fsdb_file)) fsdb_file = "tb_ClusterMbist.fsdb";
    $fsdbDumpfile(fsdb_file);
    $fsdbDumpvars(0, tb_ClusterMbist, "+all");
  end
`endif
endmodule
