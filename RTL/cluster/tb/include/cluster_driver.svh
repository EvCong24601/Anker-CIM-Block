// Input drivers and command logging: drive on falling edges, handshake on rising
// edges; the trailing ACT planes are supplied back-to-back.
// This file is included inside the parent TB module scope and is not a stand-alone
// compilation unit.
// Shared signals/counters are declared in the parent TB; do not add a module or any
// extra begin/end scope.

// Log external descriptors, not the later internal Macro compute issues.
// cases_run and input_commands are zero-based and match the scoreboard.
task automatic display_command(input string event_name, input cluster_ctrl_t d);
  $display(string'({"[CMD_%s] time=%0.3f ns cycle=%0d case=%0d standard_case=%0d cmd=%0d ",
                    "mode=%0s precision=%0d W%0dA%0d signed_en=%0d pattern=%0d bubbles=%0d ",
                    "os_cnt=%0d ws_cnt=%0d as_cnt=%0d reduce_split_mask=0x%02h macro_en_mask=0x%02h ",
                    "macro_oc_mask=0x%08h act_slot_sel=0x%06h depth=%0d seed=0x%08h"}),
             event_name, $realtime, cycle, cases_run, standard_case, input_commands,
             d.cim_as_cnt > 1 ? "AS" : d.cim_ws_cnt > 1 ? "WS" : "SINGLE", d.cim_precision, wbits(
             int'(d.cim_precision)), abits(int'(d.cim_precision)), d.cim_signed_en, case_pattern, case_bubbles,
             d.cim_os_cnt, d.cim_ws_cnt, d.cim_as_cnt, d.cim_reduce_split_mask, d.cim_macro_en_mask,
             d.cim_macro_oc_mask, d.cim_act_slot_sel, OUTPUT_BUFFER_DEPTH, SEED);
endtask

`include "include/cluster_channel_driver.svh"
task automatic send_act_frame(input cluster_ctrl_t descriptor, input logic [4095:0] data, input int kt, input int cx,
                              input int gap, input bit bubbles);
  fork
    begin
      for (int ph = 0; ph < abits(int'(descriptor.cim_precision)) / 4; ph++)
      channel_act(data[1024*ph+:1024], ph == 0 ? gap : 0);
    end
    begin
      if (descriptor.cim_as_cnt > 1)
        for (int c = 0; c < int'(descriptor.cim_as_cnt); c++)
        channel_weight(8'('h20 + 16 * kt + c), bubbles ? (($test$plusargs("INPUT_OVERLAP_TEST") && c == 1) ? abits(
                       int'(descriptor.cim_precision)) / 4 : c % 3) : 0);
      else if (cx == 0) channel_weight(8'('h20 + 16 * kt), gap);
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
