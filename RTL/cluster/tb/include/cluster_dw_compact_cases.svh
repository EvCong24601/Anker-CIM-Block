// Compare the entire Macro input, including the zero padding above bit 127.
wire [511:0] routed_act[8];
for (genvar m = 0; m < 8; m++) begin : g_dw_route_probe
  assign routed_act[m] = dut.g_macro[m].idata;
  always @(posedge clock) begin
    logic [383:0] saved_high;
    if (reset_n && dut.ren[m] && dut.command.cim_dw_compact) begin
      saved_high = dut.g_macro[m].u_macro.activation_in[511:128];
      #0.002;
      if (dut.g_macro[m].u_macro.act_clock !== 3'b001 ||
          dut.g_macro[m].u_macro.activation_in[511:128] !== saved_high)
        $fatal(1, "Compact DW high ACT bank clock/hold mismatch macro=%0d", m);
    end
  end
end
int dw_buffered = 0, dw_forwarded = 0;
bit [7:0] dw_slots_seen[8];
task automatic check_compact_issue(cluster_ctrl_t cfg, logic [1023:0] expected_plane);
  int slot;
  for (int m = 0; m < 8; m++) begin
    if (cfg.cim_macro_en_mask[m]) begin
      slot = int'(cfg.cim_act_slot_sel[3*m+:3]);
      if (routed_act[m] !== {384'b0, expected_plane[128*slot+:128]})
        $fatal(1, "Compact DW ACT mismatch macro=%0d slot=%0d", m, slot);
      dw_slots_seen[m][slot] = 1;
    end
  end
  if (dut.forward_act) dw_forwarded++;
  else dw_buffered++;
endtask

task automatic run_compact_cases(int width);
  cluster_ctrl_t cfg;
  string invalid;
  int first_precision;
  case (width)
    2: first_precision = 0;
    4: first_precision = 2;
    8: first_precision = 5;
    default: $fatal(1, "Unsupported DW weight precision %0d", width);
  endcase
  cfg = config_for(first_precision, 0, 0, 1, 0);
  cfg.cim_dw_compact = 1;
  for (int m = 0; m < 8; m++) begin
    cfg.cim_macro_oc_mask[4*m+:4] = 4'b0001 << (m%4);
    cfg.cim_act_slot_sel[3*m+:3] = 3'(m);
  end
  if ($value$plusargs("DW_INVALID=%s", invalid)) begin
    case (invalid)
      "split":     cfg.cim_reduce_split_mask = 7'h07;
      "no_oc":     cfg.cim_macro_oc_mask[7:4] = 0;
      "multi_oc":  cfg.cim_macro_oc_mask[7:4] = 3;
      "duplicate": cfg.cim_act_slot_sel[5:3] = cfg.cim_act_slot_sel[2:0];
      default: $fatal(1, "Unknown DW negative case");
    endcase
    send_job(cfg, 0, 0);
    $fatal(1, "Invalid compact DW command was accepted");
  end

  // Change only the compact bit in both directions. Inactive Macros may
  // repeat slots and do not need a one-hot OC mask.
  cfg.cim_macro_en_mask = 8'h03;
  cfg.cim_macro_oc_mask[31:8] = '1;
  cfg.cim_act_slot_sel[23:6] = '0;
  cfg.cim_dw_compact = 0;
  send_job(cfg, 0, 0);
  cfg.cim_dw_compact = 1;
  send_job(cfg, 0, 0);
  send_job(cfg, 0, 0);
  cfg.cim_dw_compact = 0;
  send_job(cfg, 0, 0);

  for (int p = 0; p < 7; p++) begin
    if (wb(p) == width) begin
      for (int rotation = 0; rotation < 8; rotation++) begin
        cfg = config_for(p, 0, rotation%3, 1 + rotation%2, 1'(rotation%2));
        cfg.cim_dw_compact = 1;
        for (int m = 0; m < 8; m++) begin
          cfg.cim_act_slot_sel[3*m+:3] = 3'(5*m + rotation);
          cfg.cim_macro_oc_mask[4*m+:4] = 4'b0001 << ((m+rotation)%4);
        end
        send_job(cfg, 0, rotation%2 == 0 ? 0 : 3);
      end
    end
  end
endtask
