`timescale 1ns/1ps

// The standalone SRAM template's detect -> repair -> retest flow, issued
// through cluster_top one Macro at a time. Each Macro contains two 512-bit
// SRAM wrappers and therefore reports eight repair bytes.
module tb_ClusterMbistSerial #(parameter bit USE_CLOCK_GATING = 1);
  import cluster_pkg::*;

  logic clock = 0, reset_n = 0;
  always #5 clock = !clock;
  cluster_ctrl_t cmd_i = '0;
  logic cmd_valid_i = 0, act_valid_i = 0, weight_valid_i = 0;
  wire cmd_ready_o, act_ready_o, weight_ready_o;
  logic [1023:0] act_data_i = '0;
  logic [7:0] weight_raddr_i = '0;
  logic sram_cs_en = 0, sram_wr_en = 0, sram_macro_group = 0;
  logic [1:0] sram_bank_sel = 0;
  logic [7:0] sram_row_addr = 37;
  logic [3:0] sram_wmask = 0;
  logic [1023:0] sram_wrdata = 0;
  wire [1023:0] sram_rd_data, raw_psum;
  wire sram_rd_valid;
  wire [31:0] psum_valid;
  logic [2:0] mbist_macro_id_i = 0;
  logic [63:0] mbist_test_red_sbk_i = 0;
  logic mbist_test_memory_start_i = 0;
  wire [63:0] mbist_test_error_sbk_o;
  wire mbist_test_busy_o, mbist_test_done_o;
  wire mbist_test_memory_valid_o, mbist_out_of_repair_o;

  cluster_top #(.USE_CLOCK_GATING(USE_CLOCK_GATING)) dut (.*);

  // One stuck-low physical column in each 128-column subbank of every Macro.
  // Keep the fault asserted after repair to test the functional remap too.
  logic [7:0] inject_fault = '1;
  for (genvar m = 0; m < 8; m++) begin : g_fault_macro
    for (genvar bank = 0; bank < 2; bank++) begin : g_fault_bank
      for (genvar sbk = 0; sbk < 4; sbk++) begin : g_fault_subbank
        localparam int COLUMN = 12 + 7*(4*bank + sbk);
        always @(negedge clock)
          if (inject_fault[m])
            dut.g_macro[m].u_macro.u_weight_sram.g_bank[bank].u_wrapper.u_sram
                .physical_mem[256*sbk+37][COLUMN] = 0;
      end
    end
  end

  localparam logic [63:0] REPAIR = 64'hbdb6afa8_a19a938c;
  localparam logic [1023:0] ONES = '1;
  logic [63:0] expected_bank [0:7];

  task automatic run_pass(input int id, input logic [63:0] repair_map,
                          input bit expected_valid, input logic [63:0] expected_errors);
    int cycles;
    @(negedge clock);
    mbist_macro_id_i = 3'(id);
    mbist_test_red_sbk_i = repair_map;
    mbist_test_memory_start_i = 1;
    @(negedge clock);
    mbist_test_memory_start_i = 0;
    // The selected repair input remains active independently of start.
    @(negedge clock);
    if ({mbist_test_busy_o, mbist_test_done_o} !== 2'b10)
      $fatal(1, "Macro%0d did not accept MBIST", id);
    cycles = 0;
    while (mbist_test_busy_o && cycles < 9600) begin
      if (cmd_ready_o !== 0 || mbist_test_done_o !== 0)
        $fatal(1, "Macro%0d functional command accepted during MBIST", id);
      if ($countones(dut.bist_busy) > 1 ||
          (dut.bist_busy & ~(8'b1 << id)) !== 8'b0)
        $fatal(1, "Macro%0d overlapping MBIST busy=%b", id, dut.bist_busy);
      if (cycles == 10) begin
        if (dut.bist_busy !== (8'b1 << id))
          $fatal(1, "Macro%0d not selected, busy=%b", id, dut.bist_busy);
        for (int byte_idx = 0; byte_idx < 8; byte_idx++)
          if (dut.bist_error_reg[id][byte_idx] !== expected_bank[id][8*byte_idx+:8])
            $fatal(1, "Macro%0d error register changed before retest completed", id);
      end
      @(negedge clock);
      cycles++;
    end
    if (cycles < 9400 || mbist_test_busy_o !== 0 || mbist_test_done_o !== 1)
      $fatal(1, "Macro%0d MBIST timeout/premature done, cycles=%0d", id, cycles);
    if ({mbist_test_memory_valid_o, mbist_out_of_repair_o, mbist_test_error_sbk_o}
        !== {expected_valid, 1'b0, expected_errors})
      $fatal(1, "Macro%0d MBIST report valid=%b out=%b errors=%h expected=%h",
             id, mbist_test_memory_valid_o, mbist_out_of_repair_o,
             mbist_test_error_sbk_o, expected_errors);
    expected_bank[id] = expected_errors;
    for (int m = 0; m < 8; m++)
      for (int byte_idx = 0; byte_idx < 8; byte_idx++)
        if (dut.bist_error_reg[m][byte_idx] !== expected_bank[m][8*byte_idx+:8])
          $fatal(1, "Macro%0d byte%0d top-level error register changed: got=%h expected=%h",
                 m, byte_idx, dut.bist_error_reg[m][byte_idx],
                 expected_bank[m][8*byte_idx+:8]);
    $display("MBIST Macro%0d %s cycles=%0d valid=%b errors=%h", id,
             expected_valid ? "retest" : "detect", cycles,
             mbist_test_memory_valid_o, mbist_test_error_sbk_o);
  endtask

  task automatic check_functional_repair(input int id);
    {sram_macro_group, sram_bank_sel} = 3'(id);
    sram_wr_en = 1;
    sram_wmask = 0;
    sram_wrdata = ONES;
    sram_cs_en = 1;
    @(negedge clock);
    sram_cs_en = 0;
    sram_wr_en = 0;
    @(negedge clock);
    sram_cs_en = 1;
    @(negedge clock);
    if (sram_rd_valid !== 1 || sram_rd_data !== ONES)
      $fatal(1, "Macro%0d functional read after repair failed", id);
    sram_cs_en = 0;
    @(negedge clock);
  endtask

  initial begin
    repeat (3) @(negedge clock);
    reset_n = 1;
    for (int id = 0; id < 8; id++) expected_bank[id] = 0;
    // Keep all eight detected error maps while testing later Macros, then
    // clear each bank only when that Macro's repair retest completes.
    for (int id = 0; id < 8; id++) run_pass(id, 0, 0, REPAIR);
    for (int id = 0; id < 8; id++) begin
      run_pass(id, REPAIR, 1, 0);
      check_functional_repair(id);
    end
    $display("PASS cluster serial MBIST macros=8 passes=16 gating=%0d", USE_CLOCK_GATING);
    $finish;
  end

`ifdef CLUSTER_FSDB
  initial begin
    string fsdb_file;
    if (!$value$plusargs("FSDB_FILE=%s", fsdb_file)) fsdb_file = "tb_ClusterMbistSerial.fsdb";
    $fsdbDumpfile(fsdb_file);
    $fsdbDumpvars(0, tb_ClusterMbistSerial, "+all");
  end
`endif
endmodule
