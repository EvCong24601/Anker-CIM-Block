// Drive on falling edges and sample each independent ready before NBA.
task automatic channel_cmd(input cluster_ctrl_t cfg);
  if (clock !== 0) @(negedge clock);
  cmd_i = cfg;
  cmd_valid_i = 1;
  do @(posedge clock); while (!cmd_ready_o);
  @(negedge clock);
  cmd_valid_i = 0;
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
