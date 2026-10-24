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

// Independent AS2 parameter mapping. Each batch is fully drained before the
// next one; no buffering or scheduler changes are required for this contract.
function automatic requant_cfg_t context_test_cfg(input int mode, cx);
  requant_cfg_t cfg;
  cfg = '0;
  cfg.conv_mode = 1'(mode);
  cfg.requant_mode = 1'(mode);
  for (int c = 0; c < 4; c++) begin
    cfg.requant_multiplier[32*c+:32] = mode ? 32'(1 + 4 * cx + c) : 32'(1 + 2 * cx);
    cfg.requant_shift[10*c+:10] = mode ? 10'(-5 - cx) : 10'(-4 - cx);
    cfg.requant_zp[32*c+:32] = 32'(1 + 10 * cx + c);
  end
  return cfg;
endfunction

task automatic run_requant_context_suite();
  int received, wanted, cx, shift_bits, mult;
  if (!ENABLE_REQUANT || REQUANT_CONTEXT_DEPTH < 2)
    $fatal(1, "AS parameter test requires Requant and two Context entries");
  for (int m = 0; m < 2; m++) begin
    load_weight_row(m, 8'h20, {512{2'b01}});
    load_weight_row(m, 8'h21, {512{2'b01}});
  end
  for (int mode = 0; mode < 2; mode++)
    for (int os = 1; os <= 2; os++) begin
      $display(
        "[CASE_START] time=%0.3f ns suite=requant_context description=independent-AS2-scale-and-zp/serial-batches mode=%0d os=%0d",
        $realtime, mode, os);
      cmd_i = '0;
      cmd_i.cim_os_cnt = 8'(os);
      cmd_i.cim_ws_cnt = 1;
      cmd_i.cim_as_cnt = 2;
      cmd_i.cim_macro_en_mask = 3;
      cmd_i.cim_macro_oc_mask = 32'hff;
      cmd_i.cim_reduce_split_mask = 7;
      cmd_i.cim_act_slot_sel = 24'h8;
      act_data_i = {256{4'h1}};
      received = 0;
      fork
        begin
          for (int tile = 0; tile < os; tile++)
          for (int context_id = 0; context_id < 2; context_id++) begin
            @(negedge clock);
            cmd_i.cim_weight_raddr = 8'('h20 + context_id);
            requant_cfg_i = context_test_cfg(mode, context_id);
            cmd_valid_i = 1;
            do @(posedge clock); while (!cmd_ready_o);
            @(negedge clock);
            cmd_valid_i = 0;
          end
        end
        begin
          for (int timeout = 0; timeout < 40; timeout++) begin
            @(negedge clock);
            if (requant_valid_o != 0) begin
              if (requant_valid_o !== 32'hf || received >= 8)
                $fatal(1, "AS parameter test: unexpected lane mask or duplicate result");
              cx = received / 4;
              for (int c = 0; c < 4; c++) begin
                mult = mode ? 1 + 4 * cx + c : 1 + 2 * cx;
                shift_bits = mode ? 5 + cx : 4 + cx;
                // Two Macros, each with 128 unit weights and unit ACT values.
                wanted = ((256 * os * mult) >> shift_bits) + 1 + 10 * cx + c;
                if ($signed(requant_data_o[8*c+:8]) != wanted)
                  $fatal(
                    1,
                    "AS parameter mapping mismatch mode=%0d os=%0d ctx=%0d OC=%0d got=%0d expected=%0d",
                    mode,
                    os,
                    cx,
                    c,
                    $signed(
                      requant_data_o[8*c+:8]
                    ),
                    wanted
                  );
                received++;
              end
            end
            if (received == 8 && !dut.batch_active && requant_valid_o == 0) break;
            if (timeout == 39) $fatal(1, "AS parameter test output timeout");
          end
        end
      join
      repeat (5) @(negedge clock);
      if (requant_valid_o != 0 || dut.batch_active) $fatal(1, "AS parameter test: batch did not drain");
    end
  $display("PASS requant_context cases=4 quant_checks=32 independent_scale_zp=1 serial_batches=1");
endtask

// Load the next batch configuration on the exact edge that captures the old
// batch's last INT8 output. The old result must use the old configuration.
task automatic run_requant_boundary_suite();
  logic [1023:0] weight_row;
  $display("[CASE_START] time=%0.3f ns suite=requant_boundary description=new-config-on-previous-quant-capture-edge",
           $realtime);
  weight_row = '0;
  for (int k = 0; k < 128; k++) weight_row[2*k+:2] = 2'd1;
  load_weight_row(0, 8'h20, weight_row);
  cmd_i = '0;
  cmd_i.cim_os_cnt = 1;
  cmd_i.cim_ws_cnt = 1;
  cmd_i.cim_as_cnt = 1;
  cmd_i.cim_macro_en_mask = 3;
  cmd_i.cim_reduce_split_mask = 7'h07;
  cmd_i.cim_act_slot_sel = 24'h000008;
  cmd_i.cim_macro_oc_mask = 1;
  cmd_i.cim_weight_raddr = 8'h20;
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
// mode. WS/single-Context latch once; AS supplies parameters on each Command.
always @(negedge clock)
  if (!reset && monitoring && dut.batch_active && dut.batch_command.cim_as_cnt <= 1)
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
  if (ENABLE_REQUANT && monitoring && dut.batch_active) begin
    if (dut.batch_requant_cfg.conv_mode !== expected_requant_cfg.conv_mode ||
        dut.batch_requant_cfg.requant_mode !== expected_requant_cfg.requant_mode ||
        dut.batch_requant_cfg.requant_zp !== expected_requant_cfg.requant_zp ||
        dut.batch_requant_cfg.requant_multiplier[31:0] !== expected_requant_cfg.requant_multiplier[31:0] ||
        dut.batch_requant_cfg.requant_shift[9:0] !== expected_requant_cfg.requant_shift[9:0] ||
        (expected_requant_cfg.requant_mode &&
         (dut.batch_requant_cfg.requant_multiplier !== expected_requant_cfg.requant_multiplier ||
          dut.batch_requant_cfg.requant_shift !== expected_requant_cfg.requant_shift)))
      $fatal(1, "Requant configuration changed within a batch");
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
      sram_cs_en = 0;
      sram_wr_en = 0;
      disable interrupted_case;
    end
  join
  repeat (2) @(negedge clock);
  if (requant_valid_o !== 0 || requant_data_o !== 0) $fatal(1, "Pending Requant output survived reset");
  reset = 0;
  repeat (3) @(negedge clock);
  if (requant_valid_o !== 0) $fatal(1, "Stale Requant valid after reset release");

  // Publish an actual quantized result, then assert and release reset entirely
  // between two rising edges. A synchronous-only output reset fails here.
  $display("[CASE_START] time=%0.3f ns suite=requant_reset description=async-short-reset-between-clock-edges",
           $realtime);
  fork : short_reset_case
    run_case(1, 1'b1, 7'h07, 8'h03, 32'hffffffff, 24'h000008, 0, 1, 1, 1, 0);
    begin
      wait (|requant_valid_o);
      #1;
      reset = 1;
      monitoring = 0;
      cmd_valid_i = 0;
      sram_cs_en = 0;
      sram_wr_en = 0;
      #0.002;
      if (requant_valid_o !== 0 || requant_data_o !== 0)
        $fatal(1, "Requant output did not clear asynchronously without a clock edge");
      #1;
      reset = 0;
      disable short_reset_case;
    end
  join
  repeat (3) @(negedge clock);
  if (requant_valid_o !== 0 || requant_data_o !== 0)
    $fatal(1, "Requant output survived a short asynchronous reset pulse");
  $display("PASS requant_reset cancelled_pending=1 registers_cleared=1 short_async_pulse=1");
endtask
