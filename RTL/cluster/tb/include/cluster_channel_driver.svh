// Stage the descriptor off-port until both the current bus and the next
// configuration can use this slot. Ready is qualified by the payload in
// cluster_top, so the ready for the old descriptor alone is insufficient.
`ifndef TB_COMMAND_DUT
`define TB_COMMAND_DUT dut
`endif
bit command_pending;
function automatic bit candidate_can_enter(input cluster_ctrl_t cfg);
  pipeline_cfg_t candidate;
  if (!cmd_ready_o) return 0;
  if (!`TB_COMMAND_DUT.batch_active || `TB_COMMAND_DUT.drain_safe || cfg == cmd_i) return 1;
  candidate = `TB_COMMAND_DUT.pipeline_config(cfg);
  if (!`TB_COMMAND_DUT.compatible_pipeline(candidate, `TB_COMMAND_DUT.pipeline_config(`TB_COMMAND_DUT.batch_command))) return 0;
  for (int s = 0; s < 5; s++)
    if (`TB_COMMAND_DUT.pipe_live[s] && !`TB_COMMAND_DUT.compatible_pipeline(candidate, `TB_COMMAND_DUT.pipe_meta[s].cfg)) return 0;
  for (int path = 0; path < 3; path++)
    if (`TB_COMMAND_DUT.tmp_path_valid[path] && `TB_COMMAND_DUT.tmp_path_meta[path].cfg.accum_mode != 0 &&
        !`TB_COMMAND_DUT.compatible_pipeline(candidate, `TB_COMMAND_DUT.tmp_path_meta[path].cfg)) return 0;
  return 1;
endfunction
`undef TB_COMMAND_DUT

cluster_ctrl_t sampled_command;
always @(posedge clock) begin
  if (reset_n && (cmd_valid_i || cmd_i !== sampled_command) &&
      {cmd_valid_i, cmd_ready_o} !== 2'b11)
    $fatal(1, "TB_CMD: command changed or asserted outside a handshake");
  sampled_command <= cmd_i;
end

task automatic channel_cmd(input cluster_ctrl_t cfg);
  if (clock !== 0) @(negedge clock);
  command_pending = 1;
  #1ps; // Let concurrent ACT/weight offers and combinational ready settle.
  while (!candidate_can_enter(cfg)) begin
    @(negedge clock);
    #1ps;
  end
  cmd_i = cfg;
  cmd_valid_i = 1;
  @(posedge clock);
  if (cmd_ready_o !== 1) $fatal(1, "TB_CMD: receiver declined the presented command");
  @(negedge clock);
  cmd_valid_i = 0;
  command_pending = 0;
endtask
task automatic channel_weight(input logic [7:0] address, input int gap = 0);
  repeat (gap) @(negedge clock);
  weight_raddr_i = address;
  weight_valid_i = 1;
  do @(posedge clock); while (!weight_ready_o);
  @(negedge clock);
  weight_valid_i = 0;
endtask
task automatic channel_act(input logic [1023:0] data, input int gap = 0);
  repeat (gap) @(negedge clock);
  act_data_i  = data;
  act_valid_i = 1;
  do @(posedge clock); while (!act_ready_o);
  @(negedge clock);
  act_valid_i = 0;
endtask
