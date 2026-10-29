// AS8 end-to-end clock/storage checks. Clock expectations come from the
// external handshake and batch lifetime, not the DUT's table_enable signals.
int gate_on_checks = 0, gate_off_checks = 0, table_hold_checks = 0;
int overlap_checks = 0, invalid_switch_checks = 0, reload_checks = 0;
generate if (CHECK_SWITCH) begin : g_as_switch_checks
  always @(posedge clock) begin : check_tables
    logic [5:0] expected_clocks;
    logic [7:0] saved_address[16];
    logic [127:0] saved_multiplier[16], saved_zp[16];
    logic [39:0] saved_shift[16];
    requant_cfg_t accepted_cfg;
    logic [7:0] accepted_address;
    bit accept, active, channel, load_cfg;
    int slot;
    if (!reset) begin
      accept = cmd_valid_i && cmd_ready_o;
      active = dut.batch_active || accept;
      channel = dut.batch_active ? dut.batch_requant_cfg.requant_mode : requant_cfg_i.requant_mode;
      load_cfg = accept && !dut.batch_active;
      expected_clocks = {load_cfg && channel, load_cfg, active && channel, active, active, 1'b0};
      slot = dut.write_context_slot;
      accepted_address = cmd_i.cim_weight_raddr;
      accepted_cfg = requant_cfg_i;
      for (int d = 0; d < 16; d++) begin
        saved_address[d] = dut.context_address[d];
        saved_multiplier[d] = dut.requant_context_multiplier[d];
        saved_shift[d] = dut.requant_context_shift[d];
        saved_zp[d] = dut.requant_context_zp[d];
      end
      if (monitoring && accept && dut.issue) overlap_checks++;
      if (monitoring && !cmd_valid_i && dut.batch_active) invalid_switch_checks++;
      if (accept && active_m > 0) reload_checks++;
      #0.002;
      if (dut.table_clock !== expected_clocks)
        $fatal(1, "AS8 GEMM: table clock gate mismatch expected=%b actual=%b", expected_clocks, dut.table_clock);
      if (active) gate_on_checks++;
      else gate_off_checks++;
      #0.998;
      for (int d = 0; d < 16; d++) begin
        if (accept && d == slot) begin
          if (dut.context_address[d] !== accepted_address ||
              dut.requant_context_multiplier[d][31:0] !== accepted_cfg.requant_multiplier[31:0] ||
              dut.requant_context_shift[d][9:0] !== accepted_cfg.requant_shift[9:0])
            $fatal(1, "AS8 GEMM: accepted address/shared scale not stored in Context %0d", d);
          if (channel && (dut.requant_context_multiplier[d] !== accepted_cfg.requant_multiplier ||
                          dut.requant_context_shift[d] !== accepted_cfg.requant_shift ||
                          dut.requant_context_zp[d] !== accepted_cfg.requant_zp))
            $fatal(1, "AS8 GEMM: accepted channel parameters not stored in Context %0d", d);
        end else begin
          if (dut.context_address[d] !== saved_address[d] ||
              dut.requant_context_multiplier[d] !== saved_multiplier[d] ||
              dut.requant_context_shift[d] !== saved_shift[d] || dut.requant_context_zp[d] !== saved_zp[d])
            $fatal(1, "AS8 GEMM: Context %0d changed without an accepted write", d);
          table_hold_checks++;
        end
        if (!channel && (dut.requant_context_multiplier[d][127:32] !== saved_multiplier[d][127:32] ||
                         dut.requant_context_shift[d][39:10] !== saved_shift[d][39:10] ||
                         dut.requant_context_zp[d] !== saved_zp[d]))
          $fatal(1, "AS8 GEMM: tensor-mode unused channel/ZP storage toggled");
      end
    end
  end
end endgenerate

task automatic report_as_gate_coverage();
  if (!gate_on_checks || !gate_off_checks || !table_hold_checks ||
      !overlap_checks || !invalid_switch_checks || reload_checks != (M - 1) * AS)
    $fatal(1, "AS8 GEMM: missing gate/hold/command-switch coverage");
  $display("PASS as8_gate_switch active=%0d idle=%0d hold=%0d overlap=%0d invalid_switch=%0d reload=%0d",
           gate_on_checks, gate_off_checks, table_hold_checks, overlap_checks, invalid_switch_checks, reload_checks);
endtask
