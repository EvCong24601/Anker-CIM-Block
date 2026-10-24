// Integration-only golden uses bounded configuration profiles, so its INT64
// arithmetic is exact. Full INT32 parameter extremes use Python vector golden.
function automatic logic signed [7:0] requant_expected(input longint signed psum, input int lane = 0);
  longint signed value, magnitude, divisor, quotient, remainder;
  int shift_amount, entry_id;
  entry_id = expected_requant_cfg.requant_mode ? lane % 4 : 0;
  value = psum * longint'($signed(expected_requant_cfg.requant_multiplier[32*entry_id+:32]));
  shift_amount = int'($signed(expected_requant_cfg.requant_shift[10*entry_id+:10]));
  if (shift_amount >= 0) value *= 64'sd1 << shift_amount;
  else begin
    divisor   = 64'sd1 << (-shift_amount);
    magnitude = value < 0 ? -value : value;
    quotient  = magnitude / divisor;
    remainder = magnitude % divisor;
    if (remainder >= divisor / 2) quotient++;
    value = value < 0 ? -quotient : quotient;
  end
  value += longint'($signed(expected_requant_cfg.requant_zp[32*(lane%4)+:32]));
  if (value > 127) return 8'sd127;
  if (value < -128) return -8'sd128;
  return 8'(value);
endfunction

task automatic configure_requant(input int profile);
  expected_requant_cfg = '0;
  case (profile % 8)
    0: begin
      expected_requant_cfg.requant_multiplier = 1;
    end
    1: begin
      expected_requant_cfg.requant_multiplier = 1;
      expected_requant_cfg.requant_shift = -7;
      expected_requant_cfg.requant_zp = 3;
    end
    2: begin
      expected_requant_cfg.requant_multiplier = -3;
      expected_requant_cfg.requant_shift = -11;
      expected_requant_cfg.requant_zp = -23;
    end
    3: begin
      expected_requant_cfg.requant_multiplier = 0;
      expected_requant_cfg.requant_zp = 97;
    end
    4: begin
      expected_requant_cfg.requant_multiplier = 13;
      expected_requant_cfg.requant_shift = 5;
      expected_requant_cfg.requant_zp = -128;
    end
    5: begin
      expected_requant_cfg.requant_multiplier = -1;
      expected_requant_cfg.requant_shift = -31;
      expected_requant_cfg.requant_zp = 127;
    end
    6: begin
      expected_requant_cfg.requant_multiplier = 65537;
      expected_requant_cfg.requant_shift = -23;
      expected_requant_cfg.requant_zp = -17;
    end
    7: begin
      expected_requant_cfg.requant_multiplier = 1;
      expected_requant_cfg.requant_shift = -1;
      expected_requant_cfg.requant_zp = 1;
    end
  endcase
  // Existing profiles use a common zp; GEMM independently exercises unequal
  // zero points across lanes while retaining one per-tensor multiplier/shift.
  expected_requant_cfg.requant_zp = {4{expected_requant_cfg.requant_zp[31:0]}};
  if ($test$plusargs("REQUANT_CHANNEL_TEST")) begin
    expected_requant_cfg.conv_mode = 1;
    expected_requant_cfg.requant_mode = 1;
    expected_requant_cfg.requant_multiplier = {32'sd0, 32'sd7, -32'sd3, 32'sd1};
    expected_requant_cfg.requant_shift = {10'sd0, -10'sd19, -10'sd15, -10'sd13};
    for (int lane = 0; lane < 4; lane++)
    case (lane % 4)
      0: expected_requant_cfg.requant_zp[32*lane+:32] = -32'sd11;
      1: expected_requant_cfg.requant_zp[32*lane+:32] = 32'sd23;
      2: expected_requant_cfg.requant_zp[32*lane+:32] = -32'sd7;
      3: expected_requant_cfg.requant_zp[32*lane+:32] = 32'sd97;
    endcase
  end
  requant_cfg_i = expected_requant_cfg;
endtask

// Load the next batch configuration on the exact edge that captures the old
// batch's last INT8 output. The old result must use the old configuration.
task automatic run_requant_boundary_suite();
  $display("[CASE_START] time=%0.3f ns suite=requant_boundary description=new-config-on-previous-quant-capture-edge",
           $realtime);
  @(negedge clock);
  weight_wen_i   = 8'h01;
  weight_waddr_i = 8'h20;
  weight_wdata_i = '0;
  for (int k = 0; k < 128; k++) weight_wdata_i[2*k+:2] = 2'd1;
  @(negedge clock);
  weight_wen_i = 0;
  cmd_i = '0;
  cmd_i.os_cnt = 1;
  cmd_i.ws_cnt = 1;
  cmd_i.as_cnt = 1;
  cmd_i.macro_en_mask = 3;
  cmd_i.reduce_split_mask = 7'h07;
  cmd_i.act_slot_sel = 24'h000008;
  cmd_i.macro_oc_mask = 1;
  cmd_i.weight_cim_raddr = 8'h20;
  act_data_i = '0;
  for (int k = 0; k < 128; k++) act_data_i[4*k+:4] = 4'd1;
  requant_cfg_i = '{
    requant_mode: 1'b0,
    requant_multiplier: 32'sd1,
    requant_shift: -10'sd1,
    requant_zp: 32'sd0,
    default: '0
  };
  cmd_valid_i = 1;
  @(posedge clock);
  if (!cmd_ready_o) $fatal(1, "Boundary first command not accepted");
  @(negedge clock);
  cmd_valid_i = 0;
  wait (out_valid_o[0]);
  #1;
  if (psum_data_o[31:0] !== 32'd128 || requant_valid_o !== 0) $fatal(1, "Boundary first raw or Requant delay mismatch");
  @(negedge clock);
  requant_cfg_i = '{
    requant_mode: 1'b0,
    requant_multiplier: 32'sd3,
    requant_shift: -10'sd2,
    requant_zp: 32'sd0,
    default: '0
  };
  cmd_valid_i = 1;
  @(posedge clock);
  if (!cmd_ready_o) $fatal(1, "Boundary next batch not accepted at earliest edge");
  #1;
  if (requant_valid_o !== 32'd1 || requant_data_o[7:0] !== 8'd64)
    $fatal(1, "New batch configuration corrupted previous Requant result");
  @(negedge clock);
  cmd_valid_i = 0;
  wait (out_valid_o[0]);
  #1;
  if (requant_data_o[7:0] !== 8'd64) $fatal(1, "Requant output did not hold across configuration reload");
  @(posedge clock);
  #1;
  if (requant_valid_o !== 32'd1 || requant_data_o[7:0] !== 8'd96)
    $fatal(1, "Next batch did not use its own Requant configuration");
  repeat (3) @(negedge clock);
  if (requant_valid_o !== 0 || requant_data_o[7:0] !== 8'd96) $fatal(1, "Boundary output drain/hold mismatch");
  $display("PASS requant_boundary batches=2 earliest_reload=1 latency=1");
endtask

// Change the live input after batch acceptance, including to an unsupported
// mode. Only the first accepted Command is allowed to load configuration.
always @(negedge clock)
  if (!reset && monitoring && dut.batch_active)
    requant_cfg_i = '{
      requant_mode: 1'b1,
      requant_multiplier: 32'sd7,
      requant_shift: 10'sd1,
      requant_zp: 32'sd99,
      default: '0
    };

// All aligned groups, every OC mask (including holes), seven precisions,
// signed/unsigned, OS1/2 and Single/WS/AS. No masked-channel compaction.
task automatic run_requant_channel_suite();
  logic [7:0] en;
  logic [6:0] split;
  logic [23:0] slots;
  int count;
  count = 0;
  for (int p = 0; p < 7; p++)
    for (int first = 0; first < 8; first += wbits(p)) begin
      en = 8'(((1 << wbits(p)) - 1) << first);
      split = wbits(p) == 8 ? 7'h00 : wbits(p) == 4 ? 7'h01 : 7'h07;
      slots = '0;
      for (int m = first; m < first + wbits(p); m++) slots[3*m+:3] = 3'(m - first);
      for (int mask = 0; mask < 16; mask++)
      for (int os = 1; os <= 2; os++)
      for (int mode = 0; mode < 3; mode++) begin
        run_case(p, 1'(mask % 2), split, en, {8{4'(mask)}}, slots, 0, os, mode == 1 ? 2 : 1, mode == 2 ? 2 : 1,
                 1'(mask % 2));
        count++;
      end
    end
  if (count != 1536 || requant_checks == 0) $fatal(1, "Missing four-channel mapping coverage");
  $display("PASS requant_channel cases=%0d masks=16 groups=7 precisions=7 checks=%0d latency=1", count, requant_checks);
endtask

// Sample raw before the edge; quantization is published AFTER that edge.
// This checks exactly one cycle, not merely matching eventual values.
always @(posedge clock) begin : requant_protocol_scoreboard
  logic [255:0] previous_data;
  logic [255:0] wanted_data;
  logic [ 31:0] previous_raw_valid;
  previous_data = requant_data_o;
  previous_raw_valid = out_valid_o;
  for (int lane = 0; lane < 32; lane++)
  if (monitoring && previous_raw_valid[lane])
    wanted_data[8*lane+:8] = requant_expected(expected[dut.raw_context[lane]][lane], lane);
  #1;
  if (!reset && requant_valid_o !== (ENABLE_REQUANT ? previous_raw_valid : 32'b0))
    $fatal(1, "Requant valid must follow raw valid by exactly one cycle");
  if (reset && requant_valid_o !== 0) $fatal(1, "Requant valid during reset");
  if (reset && requant_data_o !== 0) $fatal(1, "Requant output register did not reset");
  if (!reset)
    for (int lane = 0; lane < 32; lane++)
    if (!requant_valid_o[lane] && requant_data_o[8*lane+:8] !== previous_data[8*lane+:8])
      $fatal(1, "Requant output register changed without lane valid lane=%0d", lane);
  if (monitoring && dut.batch_active) begin
    if (dut.batch_requant_cfg !== expected_requant_cfg) $fatal(1, "Requant configuration changed within a batch");
    requant_config_hold_checks++;
  end
  if (monitoring)
    for (int lane = 0; lane < 32; lane++)
    if (requant_valid_o[lane]) begin
      if (requant_data_o[8*lane+:8] !== wanted_data[8*lane+:8])
        $fatal(
          1,
          "Requant mismatch case=%0d lane=%0d got=%0d expected=%0d",
          cases_run,
          lane,
          $signed(
            requant_data_o[8*lane+:8]
          ),
          $signed(
            wanted_data[8*lane+:8]
          )
        );
      requant_checks++;
    end
end

task automatic run_requant_suite();
  logic [ 7:0] en;
  logic [23:0] slots;
  for (int p = 0; p < 7; p++) begin
    case (wbits(
      p
    ))
      2: begin
        en = 8'h03;
        slots = 24'h000008;
      end
      4: begin
        en = 8'h0f;
        slots = 24'h000688;
      end
      default: begin
        en = 8'hff;
        slots = 24'hfac688;
      end
    endcase
    for (int sign_mode = 0; sign_mode < 2; sign_mode++)
    for (int os = 1; os <= 2; os++)
    for (int mode = 0; mode < 3; mode++)
    for (int gap = 0; gap < 2; gap++)
    run_case(p, 1'(sign_mode), wbits(p) == 8 ? 7'h00 : wbits(p) == 4 ? 7'h01 : 7'h07, en, 32'hdb6db6db, slots, 0, os,
             mode == 1 ? 2 : 1, mode == 2 ? 2 : 1, 1'(gap));
  end
  if (cases_run != 168 || requant_checks == 0 || requant_config_hold_checks == 0)
    $fatal(1, "Missing Requant integration coverage");
  $display("PASS requant_integration cases=%0d profiles=8 checks=%0d config_hold_checks=%0d latency=1", cases_run,
           requant_checks, requant_config_hold_checks);
endtask

// Interrupt a real computation after raw publication but before its next-edge
// INT8 capture. Reset must cancel that pending output and clear its registers.
task automatic run_requant_reset_suite();
  $display("[CASE_START] time=%0.3f ns suite=requant_reset description=cancel-pending-quant-output-on-reset",
           $realtime);
  fork : interrupted_case
    run_case(1, 1'b1, 7'h07, 8'h03, 32'hffffffff, 24'h000008, 0, 1, 1, 1, 0);
    begin
      wait (|out_valid_o);
      @(negedge clock);
      reset = 1;
      monitoring = 0;
      cmd_valid_i = 0;
      weight_wen_i = 0;
      disable interrupted_case;
    end
  join
  repeat (2) @(negedge clock);
  if (requant_valid_o !== 0 || requant_data_o !== 0) $fatal(1, "Pending Requant output survived reset");
  reset = 0;
  repeat (3) @(negedge clock);
  if (requant_valid_o !== 0) $fatal(1, "Stale Requant valid after reset release");
  $display("PASS requant_reset cancelled_pending=1 registers_cleared=1");
endtask
