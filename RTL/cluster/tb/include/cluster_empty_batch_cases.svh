// Drive the next batch at the earliest ready edge, including zero-output batches.
task automatic empty_boundary_frame(input int precision_id, input bit empty);
  int macro_count;
  while (!cmd_ready_o) @(negedge clock);
  macro_count = wbits(precision_id);
  cmd_i = '0;
  cmd_i.cim_os_cnt = 1;
  cmd_i.cim_ws_cnt = 1;
  cmd_i.cim_as_cnt = 1;
  cmd_i.cim_precision = 3'(precision_id);
  cmd_i.cim_signed_en = 1;
  cmd_i.cim_macro_en_mask = 8'((1 << macro_count) - 1);
  cmd_i.cim_macro_oc_mask = empty ? 0 : 32'hffffffff;
  cmd_i.cim_reduce_split_mask = macro_count == 2 ? 7 : macro_count == 4 ? 1 : 0;
  cmd_i.cim_act_slot_sel = macro_count == 2 ? 24'h8 : macro_count == 4 ? 24'h688 : 24'hfac688;
  cmd_valid_i = 1;
  act_data_i = {256{4'h1}};
  @(negedge clock);
  cmd_valid_i = 0;
  act_data_i = 0;
  repeat (abits(precision_id) / 4 - 1) @(negedge clock);
  while (!cmd_ready_o) @(negedge clock);
endtask

task automatic run_empty_batch_suite();
  int outputs;
  bit driver_done;
  outputs = 0;
  driver_done = 0;
  if (!ENABLE_REQUANT) $fatal(1, "Empty batch test requires Requant");
  for (int m = 0; m < 8; m++) load_weight_row(m, 0, {128{8'd1}});
  requant_cfg_i = '0;
  requant_cfg_i.requant_multiplier[31:0] = 1;
  requant_cfg_i.requant_shift[9:0] = 10'(-2);
  fork
    begin
      @(negedge clock);
      empty_boundary_frame(6, 0);
      for (int p = 0; p < 7; p++) begin
        $display("[CASE_START] time=%0.3f ns suite=empty_batch description=empty-to-live-earliest-ready precision=%0d", $realtime, p);
        empty_boundary_frame(p, 1);
        empty_boundary_frame(6, 0);
      end
      driver_done = 1;
    end
    begin
      for (int timeout = 0; timeout < 300; timeout++) begin
        @(posedge clock);
        #1;
        if (requant_valid_o != 0) begin
          if (requant_valid_o !== 32'hf) $fatal(1, "Empty boundary output mask mismatch");
          for (int c = 0; c < 4; c++)
            if (requant_data_o[8*c+:8] !== 8'd64) $fatal(1, "Empty boundary numeric mismatch");
          outputs++;
        end
        if (driver_done && !dut.batch_active && requant_valid_o == 0) break;
        if (timeout == 299) $fatal(1, "Empty boundary timeout");
      end
    end
  join
  if (outputs != 8) $fatal(1, "Empty batch lost or generated an output");
  $display("PASS empty_batch cases=7 valid_outputs=%0d tmp_capture_request_match=1", outputs);
endtask
