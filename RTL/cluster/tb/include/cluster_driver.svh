// Input drivers and command logging: drive on falling edges, handshake on rising
// edges; the trailing ACT planes are supplied back-to-back.
// This file is included inside the parent TB module scope and is not a stand-alone
// compilation unit.
// Shared signals/counters are declared in the parent TB; do not add a module or any
// extra begin/end scope.

// Log external descriptors, not the later internal Macro compute issues.
// cases_run and input_commands are zero-based and match the scoreboard.
task automatic display_command(input string event_name, input cluster_ctrl_t d);
  $display(
    string'({"[CMD_%s] time=%0.3f ns cycle=%0d case=%0d standard_case=%0d cmd=%0d tile=%0d ",
             "context=%0d kind=%0s mode=%0s precision=%0d W%0dA%0d signed_en=%0d pattern=%0d bubbles=%0d ",
             "os_cnt=%0d ws_cnt=%0d as_cnt=%0d reduce_split_mask=0x%02h macro_en_mask=0x%02h ",
             "macro_oc_mask=0x%08h cim_weight_raddr=0x%02h act_slot_sel=0x%06h depth=%0d seed=0x%08h"}),
    event_name, $realtime, cycle, cases_run, standard_case, input_commands, input_commands / case_r,
    input_commands % case_r, (d.cim_as_cnt > 1 && input_commands % case_r != 0) ? "ADDRESS" : "ACT",
    d.cim_as_cnt > 1 ? "AS" : d.cim_ws_cnt > 1 ? "WS" : "SINGLE", d.cim_precision, wbits(int'(d.cim_precision)), abits(
    int'(d.cim_precision)), d.cim_signed_en, case_pattern, case_bubbles, d.cim_os_cnt, d.cim_ws_cnt, d.cim_as_cnt,
    d.cim_reduce_split_mask, d.cim_macro_en_mask, d.cim_macro_oc_mask, d.cim_weight_raddr, d.cim_act_slot_sel,
    OUTPUT_BUFFER_DEPTH, SEED);
endtask

task automatic send_compute(input cluster_ctrl_t d, input logic [1023:0] data, input int gap);
  @(negedge clock);
  repeat (gap) @(negedge clock);
  cmd_i = d;
  cmd_valid_i = 1;
  act_data_i = data;
  display_command("SEND", d);
  for (int t = 0; t < TIMEOUT_CYCLES; t++) begin
    @(posedge clock);
    if (cmd_ready_o) begin
      #1;
      cmd_valid_i = 0;
      return;
    end
  end
  $fatal(1, "Command timeout");
endtask

task automatic send_address(input cluster_ctrl_t d, input int gap);
  @(negedge clock);
  repeat (gap) @(negedge clock);
  cmd_i = d;
  cmd_valid_i = 1;
  display_command("SEND", d);
  for (int q = 0; q < TIMEOUT_CYCLES; q++) begin
    @(posedge clock);
    if (cmd_ready_o) begin
      #1;
      cmd_valid_i = 0;
      return;
    end
  end
  $fatal(1, "AS descriptor timeout");
endtask
task automatic send_act_frame(input cluster_ctrl_t descriptor, input logic [4095:0] data, input int kt,
                              input int gap, input bit bubbles);
  cluster_ctrl_t d;
  int pcount, rcount;
  d = descriptor;
  pcount = abits(int'(d.cim_precision)) / 4;
  rcount = d.cim_as_cnt > 1 ? int'(d.cim_as_cnt) : 1;
  send_compute(d, data[0+:1024], gap);
  fork
    begin
      for (int ph = 1; ph < pcount; ph++) begin
        @(negedge clock);
        act_data_i = data[1024*ph+:1024];
        @(posedge clock);
        #1;
      end
    end
    begin
      for (int cx = 1; cx < rcount; cx++) begin
        d.cim_weight_raddr = 8'('h20 + 16 * kt + cx);
        // The overlap suite deliberately withholds Context1 until after
        // the entire ACT stream, proving that only that Context stalls.
        send_address(d, bubbles ? (($test$plusargs("INPUT_OVERLAP_TEST") && cx == 1) ? pcount : cx % 3) : 0);
      end
    end
  join
endtask

// Load one Macro row through the public WLC port and independently read it back.
// Initialization runs outside the monitored compute interval; one call writes
// one 128 B row, with all four active-high mask bits cleared.
task automatic load_weight_row(input int macro_id, input logic [7:0] address, input logic [1023:0] data);
  @(negedge clock);
  sram_cs_en = 1;
  sram_wr_en = 1;
  sram_macro_group = 1'(macro_id / 4);
  sram_bank_sel = 2'(macro_id % 4);
  sram_row_addr = address;
  sram_wmask = 0;
  sram_wrdata = data;
  @(posedge clock);
  #0.002;
  if (cmd_ready_o !== 0) $fatal(1, "Weight load: Command ready during SRAM write");
  @(negedge clock);
  sram_wr_en = 0;
  @(posedge clock);
  #1;
  if (!sram_rd_valid || sram_rd_data !== data)
    $fatal(1, "Weight load readback mismatch macro=%0d row=%0d", macro_id, address);
  @(negedge clock);
  sram_cs_en = 0;
  #0.002;
  if (!sram_rd_valid || sram_rd_data !== data) $fatal(1, "Weight load: response changed before next edge");
  @(posedge clock);
  #0.002;
  if (sram_rd_valid || sram_rd_data !== 0) $fatal(1, "Weight load: response did not drain");
endtask
