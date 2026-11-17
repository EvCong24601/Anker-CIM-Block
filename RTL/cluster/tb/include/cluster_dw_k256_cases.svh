// K=256 always occupies W complete ACT slots: 2/4/8 in W2/W4/W8.
// Check full routed input, active Macro selection, and actual ACT bank clocks.
wire [511:0] routed_act[8];
for (genvar m = 0; m < 8; m++) begin : g_dw_route_probe
  assign routed_act[m] = dut.g_macro[m].idata;
  always @(posedge clock) begin
    logic [511:0] saved_act, expected_act;
    logic [2:0] expected_clocks;
    int width;
    if (reset_n && dw_width != 0) begin
      width = wb(int'(dut.command.cim_precision));
      saved_act = dut.g_macro[m].u_macro.activation_in;
      expected_act = saved_act;
      expected_clocks = 0;
      if (dut.ren[m]) begin
        expected_clocks = width == 2 ? 3'b111 : width == 4 ? 3'b011 : 3'b001;
        case (width)
          2: expected_act = routed_act[m];
          4: expected_act[255:0] = routed_act[m][255:0];
          8: expected_act[127:0] = routed_act[m][127:0];
        endcase
      end
      #0.002;
      if (dut.g_macro[m].u_macro.act_clock !== expected_clocks ||
          dut.g_macro[m].u_macro.activation_in !== expected_act)
        $fatal(1, "K256 DW ACT bank clock/capture/hold mismatch macro=%0d", m);
    end
  end
end
int dw_buffered = 0, dw_forwarded = 0;
bit [7:0] dw_slots_seen[8];
task automatic check_k256_issue(cluster_ctrl_t cfg, logic [1023:0] expected_plane);
  int slot, width;
  logic [511:0] expected_input;
  width = wb(int'(cfg.cim_precision));
  for (int m = 0; m < 8; m++) begin
    if (dut.ren[m] !== (cfg.cim_macro_en_mask[m] && (|cfg.cim_macro_oc_mask[4*m+:4])))
      $fatal(1, "K256 DW Macro enable mismatch macro=%0d", m);
    if (dut.ren[m]) begin
      slot = int'(cfg.cim_act_slot_sel[3*m+:3]);
      case (width)
        2: expected_input = expected_plane[512*slot+:512];
        4: expected_input = {256'b0, expected_plane[256*slot+:256]};
        8: expected_input = {384'b0, expected_plane[128*slot+:128]};
      endcase
      if (routed_act[m] !== expected_input)
        $fatal(1, "K256 DW ACT mismatch macro=%0d slot=%0d W=%0d", m, slot, width);
      dw_slots_seen[m][slot] = 1;
    end
  end
  if (dut.forward_act) dw_forwarded++;
  else dw_buffered++;
endtask

task automatic run_k256_cases(int width);
  cluster_ctrl_t cfg;
  string invalid;
  int first_precision, m;
  bit [7:0] slots;
  case (width)
    2: first_precision = 0;
    4: first_precision = 2;
    8: first_precision = 5;
    default: $fatal(1, "Unsupported DW weight precision %0d", width);
  endcase
  cfg = config_for(first_precision, 3, 0, 1, 0);
  if ($value$plusargs("DW_INVALID=%s", invalid)) begin
    case (invalid)
      "slot": cfg.cim_act_slot_sel[2:0] = 3'(width);
      "duplicate": cfg.cim_act_slot_sel[5:3] = cfg.cim_act_slot_sel[2:0];
      default: $fatal(1, "Unknown DW negative case");
    endcase
    send_job(cfg, 0, 0);
    $fatal(1, "Invalid K256 DW command was accepted");
  end

  // Move the W active Macros over all physical locations and permute every
  // legal slot. Each independent Macro selects one local OC for DW output.
  for (int p = 0; p < 7; p++) begin
    if (wb(p) == width) begin
      for (int placement = 0; placement < 8; placement++)
      for (int rotation = 0; rotation < width; rotation++) begin
        cfg = config_for(p, 0, (placement+rotation)%3, 1 + rotation%2, 1'(placement%2));
        cfg.cim_macro_en_mask = 0;
        cfg.cim_macro_oc_mask = '1;  // Disabled Macro OC masks need no special value.
        cfg.cim_act_slot_sel = 0;
        slots = 0;
        for (int a = 0; a < width; a++) begin
          m = (a+placement)%8;
          cfg.cim_macro_en_mask[m] = 1;
          cfg.cim_act_slot_sel[3*m+:3] = 3'((5*a+rotation)%width);
          cfg.cim_macro_oc_mask[4*m+:4] = 4'b0001 << ((m+rotation)%4);
          slots[(5*a+rotation)%width] = 1;
        end
        if ($countones(cfg.cim_macro_en_mask) != width || $countones(slots) != width)
          $fatal(1, "K256 DW must cover exactly W full ACT slots");
        send_job(cfg, 0, rotation%2 == 0 ? 0 : 3);
        if (rotation == 0) send_job(cfg, 0, 0);  // Same-config turnover.
      end
    end
  end

  // All three masks retain their general meaning. Zero/multiple OC bits
  // and merged groups are legal; the independent oracle checks every lane.
  cfg = config_for(first_precision, 0, 0, 1, 1);
  cfg.cim_macro_en_mask = 8'((1 << width)-1);
  cfg.cim_macro_oc_mask = 32'hffffffff;
  cfg.cim_macro_oc_mask[3:0] = 0;
  send_job(cfg, 0, 0);
  cfg.cim_macro_oc_mask[3:0] = 3;
  send_job(cfg, 0, 3);
  cfg.cim_macro_en_mask[0] = 0;
  send_job(cfg, 0, 0);
  cfg = config_for(first_precision, 3, 0, 1, 1);
  send_job(cfg, 0, 0);  // One K=256 reduction over W full slots.
  cfg.cim_reduce_split_mask = 7'h7f;
  send_job(cfg, 0, 0);  // Same operands, independent output groups.
  cfg.cim_macro_oc_mask = 0;
  send_job(cfg, 0, 0);  // Empty effective work still consumes all operands.
  cfg.cim_macro_oc_mask = '1;
  send_job(cfg, 0, 0);
endtask
