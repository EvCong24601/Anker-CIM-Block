// Coarse table clocks and fixed-slot AS parameters. A4 bypasses address storage only.
bit a4_probe_active = 0;
always @(posedge clock) begin : context_table_clock_check
  bit want0, want_weight, want_quant;
  want0 = dut.cmd_accept && cmd_i.cim_as_cnt > 1 && abits(int'(cmd_i.cim_precision)) == 4;
  want_weight = (dut.batch_active && dut.batch_command.cim_as_cnt > 1 && abits(int'(dut.batch_command.cim_precision)) >
                 4) || (dut.cmd_accept && cmd_i.cim_as_cnt > 1 && abits(int'(cmd_i.cim_precision)) > 4);
  want_quant = ENABLE_REQUANT && ((dut.batch_active && dut.batch_command.cim_as_cnt > 1) ||
    (dut.cmd_accept && cmd_i.cim_as_cnt > 1));
  if (!reset) begin
    if (a4_probe_active && want_weight) $fatal(1, "A4 bypass requested the weight-table clock");
    #0.002;
    if (!reset && (dut.entry0_clock !== want0 || dut.deep_weight_clock !== want_weight ||
                   dut.deep_requant_clock !== want_quant))
      $fatal(1, "Context table batch-clock mismatch");
  end
end

function automatic requant_cfg_t context_buffer_cfg(input int mode, input int cx, input int precision);
  requant_cfg_t cfg;
  cfg = '0;
  cfg.conv_mode = 1'(mode);
  cfg.requant_mode = 1'(mode);
  for (int c = 0; c < 4; c++) begin
    cfg.requant_multiplier[32*c+:32] = 32'(1 + cx % 3 + (mode ? c : 0));
    cfg.requant_shift[10*c+:10] = 10'(-(abits(precision) + 3 + cx % 3));
    cfg.requant_zp[32*c+:32] = 32'(-32 + (3 * cx + c) % 64);
  end
  if ($test$plusargs("FULL_SHIFT_TEST")) begin
    for (int c = 0; c < 4; c++) begin
      unique case ((cx + c) % 8)
        0: cfg.requant_shift[10*c+:10] = 10'(-512);
        1: cfg.requant_shift[10*c+:10] = 10'(-64);
        2: cfg.requant_shift[10*c+:10] = 10'(-63);
        3: cfg.requant_shift[10*c+:10] = 10'(-32);
        4: cfg.requant_shift[10*c+:10] = 10'(31);
        5: cfg.requant_shift[10*c+:10] = 10'(32);
        6: cfg.requant_shift[10*c+:10] = 10'(63);
        7: cfg.requant_shift[10*c+:10] = 10'(511);
      endcase
      cfg.requant_multiplier[32*c+:32] = 32'(c == 2 ? 0 : (cx % 2 ? -1 : 1));
    end
  end
  return cfg;
endfunction

task automatic run_context_buffer_suite();
  int p, macro_count, os, count, raw_checks, quant_checks, cases;
  int raw_received, quant_received, target, cx, wanted, overlap_checks;
  bit send_done, empty_mask;
  logic [1023:0] row;
  logic [3:0] local_mask;
  cases = 0;
  raw_checks = 0;
  quant_checks = 0;
  if (!ENABLE_REQUANT || REQUANT_CONTEXT_DEPTH != OUTPUT_BUFFER_DEPTH)
    $fatal(1, "A4 bypass test requires matching Requant/output depths");
  for (int precision_case = 0; precision_case < 7; precision_case++) begin
    p = precision_case;
    if ($test$plusargs("A4_ONLY") && abits(p) != 4) continue;
    macro_count = wbits(p);
    row = '0;
    for (int j = 0; j < 1024 / wbits(p); j++) row[wbits(p)*j+:2] = 2'b01;
    for (int shape = 0; shape < 6; shape++)
    for (int mode = 0; mode < (shape == 3 ? 1 : 2); mode++) begin
      os = shape == 0 || shape == 3 || shape == 4 ? 1 : 2;
      count = shape == 0 || shape == 2 || shape >= 4 ? 16 : 8;
      empty_mask = shape == 3;
      local_mask = empty_mask ? 0 : shape == 4 ? 4'ha : shape == 5 ? 4'h4 : 4'hf;
      $display(
        string'({"[CASE_START] time=%0.3f ns suite=context_buffers ",
                 "description=fixed-Context-slots/AS-limit16 W%0dA%0d os=%0d as=%0d ",
                 "mode=%0d empty_mask=%0d"}),
        $realtime, macro_count, abits(p), os, count, mode, empty_mask);
      for (int context_id = 0; context_id < count; context_id++)
      for (int m = 0; m < macro_count; m++) load_weight_row(m, 8'('h20 + context_id), row);
      cmd_i = '0;
      cmd_i.cim_precision = 3'(p);
      cmd_i.cim_os_cnt = 8'(os);
      cmd_i.cim_ws_cnt = 1;
      cmd_i.cim_as_cnt = 8'(count);
      cmd_i.cim_macro_en_mask = 8'((1 << macro_count) - 1);
      cmd_i.cim_macro_oc_mask = {8{local_mask}};
      cmd_i.cim_reduce_split_mask = macro_count == 2 ? 7 : macro_count == 4 ? 1 : 0;
      cmd_i.cim_act_slot_sel = macro_count == 2 ? 24'h8 : macro_count == 4 ? 24'h688 : 24'hfac688;
      act_data_i = {256{4'h1}};
      raw_received = 0;
      quant_received = 0;
      target = $countones(local_mask) * count;
      send_done = 0;
      overlap_checks = 0;
      a4_probe_active = abits(p) == 4;
      fork
        begin
          for (int tile = 0; tile < os; tile++) begin
            for (int context_id = 0; context_id < count; context_id++) begin
              @(negedge clock);
              cmd_i.cim_weight_raddr = 8'('h20 + context_id);
              requant_cfg_i = context_buffer_cfg(mode, context_id, p);
              cmd_valid_i = 1;
              do @(posedge clock); while (!cmd_ready_o);
              @(negedge clock);
              cmd_valid_i = 0;
            end
          end
          send_done = 1;
        end
        begin
          while (!send_done) begin
            @(posedge clock);
            if (dut.issue && dut.packet_active && dut.command_count < count) overlap_checks++;
          end
        end
        begin
          for (int timeout = 0; timeout < 2500; timeout++) begin
            @(negedge clock);
            if (abits(p) == 4 && dut.deep_weight_clock !== 0)
              $fatal(1, "A4 bypass unexpectedly clocked the weight table");
            if (out_valid_o != 0) begin
              if (out_valid_o !== {28'b0, local_mask} || raw_received >= target)
                $fatal(1, "A4 bypass unexpected raw lane mask/count");
              for (int c = 0; c < 4; c++)
              if (local_mask[c])
                if ($signed(psum_data_o[32*c+:32]) != 256 * os * ((1 << abits(p)) - 1) / 15)
                  $fatal(1, "A4 bypass raw mismatch");
              raw_received += $countones(local_mask);
              raw_checks += $countones(local_mask);
            end
            if (requant_valid_o != 0) begin
              if (requant_valid_o !== {28'b0, local_mask} || quant_received >= target)
                $fatal(1, "A4 bypass unexpected quant lane mask/count");
              cx = quant_received / $countones(local_mask);
              for (int c = 0; c < 4; c++)
              if (local_mask[c]) begin
                expected_requant_cfg = context_buffer_cfg(mode, cx, p);
                wanted = int'(requant_expected(256 * os * ((1 << abits(p)) - 1) / 15, c));
                if ($signed(requant_data_o[8*c+:8]) != wanted)
                  $fatal(1, "A4 bypass parameter mismatch ctx=%0d OC=%0d", cx, c);
              end
              quant_received += $countones(local_mask);
              quant_checks += $countones(local_mask);
            end
            if (send_done && raw_received == target && quant_received == target &&
              !dut.batch_active && out_valid_o == 0 && requant_valid_o == 0)
              break;
            if (timeout == 2499) $fatal(1, "A4 bypass timeout");
          end
        end
      join
      if (overlap_checks == 0) $fatal(1, "AS waited for all Context parameters before issuing");
      repeat (4) @(negedge clock);
      a4_probe_active = 0;
      cases++;
    end
  end
  if (cases != ($test$plusargs(
      "A4_ONLY"
    ) ? 22 : 77) || raw_checks != cases / 11 * 416 || quant_checks != cases / 11 * 416)
    $fatal(1, "A4 bypass coverage mismatch");
  $display(
    string'({"PASS context_buffers cases=%0d raw_checks=%0d quant_checks=%0d fixed_slots=16 ",
             "A4_weight_bypass=1 input_issue_overlap=1"}),
    cases, raw_checks, quant_checks);
endtask
