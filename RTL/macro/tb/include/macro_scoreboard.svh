// Per-OC write mirror, hold tracking and two-cycle result checks; sample the
// request on the rising edge and compare outputs after NBA.
// This file is included inside the parent TB module scope and is not a stand-alone
// compilation unit.
// Shared signals/counters are declared in the parent TB; do not add a module or any
// extra begin/end scope.

always @(posedge clock or negedge reset_n) begin : scoreboard
  logic [1023:0] row;
  if (!reset_n) begin
    for (int i = 0; i < EXPECTED_LATENCY; i++) if (expected_valid[i] === 1'b1) cancelled_count++;
    expected_valid = '0;
    for (int i = 0; i <= EXPECTED_LATENCY; i++) begin
      expected_data[i]  = '0;
      expected_mask[i]  = '0;
      expected_phase[i] = '0;
    end
    last_data = 0;
    last_mask = 0;
    last_phase = 0;
    reference_hold_valid = 0;
    pending_refresh = 0;
  end else if (!negative_mode) begin
    cycle_count++;
    // Commit a previous refresh at its completion edge, BEFORE checking
    // this edge's new reuse. Reset cancels a pending refresh above.
    if (pending_refresh) begin
      reference_hold = pending_hold_row;
      reference_hold_address = pending_hold_address;
      reference_hold_valid = 1;
    end
    pending_refresh = 0;
    for (int i = EXPECTED_LATENCY; i > 0; i--) begin
      expected_valid[i] = expected_valid[i-1];
      expected_data[i]  = expected_data[i-1];
      expected_mask[i]  = expected_mask[i-1];
      expected_phase[i] = expected_phase[i-1];
    end
    expected_valid[0] = cim_ren && (|cim_oc_mask);
    if (sram_wen) begin
      for (int b = 0; b < 128; b++) if (!sram_wmask[b/32]) reference_memory[sram_waddr][8*b+:8] = sram_wdata[8*b+:8];
      if (!(&sram_wmask)) reference_hold_valid = 0;
    end
    if (sram_ren) begin
      reference_hold = reference_memory[sram_raddr];
      reference_hold_address = sram_raddr;
      reference_hold_valid = 1;
    end
    if (expected_valid[0]) begin
      accepted_count++;
      if (cim_station) begin
        row = reference_memory[cim_raddr];
        pending_hold_row = row;
        pending_hold_address = cim_raddr;
        pending_refresh = 1;
      end else begin
        if (!reference_hold_valid || cim_raddr != reference_hold_address)
          $fatal(1, "TB: legal stimulus reused invalid reference hold");
        row = reference_hold;
      end
      expected_data[0]  = golden_phase(row, cim_idata, cim_precision, cim_signed_en, cim_phase, cim_oc_mask);
      expected_mask[0]  = cim_oc_mask;
      expected_phase[0] = cim_phase;
    end else if (cim_ren) zero_mask_count++;
    else bubble_count++;
    #1;
    if (cim_odata_valid !== expected_valid[EXPECTED_LATENCY])
      $fatal(
        1,
        "TB: latency/valid mismatch cycle=%0d expected=%b got=%b",
        cycle_count,
        expected_valid[EXPECTED_LATENCY],
        cim_odata_valid
      );
    if (expected_valid[EXPECTED_LATENCY]) begin
      result_count++;
      for (int c = 0; c < 4; c++)
      if (expected_mask[EXPECTED_LATENCY][c]) last_data[18*c+:18] = expected_data[EXPECTED_LATENCY][18*c+:18];
      last_mask  = expected_mask[EXPECTED_LATENCY];
      last_phase = expected_phase[EXPECTED_LATENCY];
    end
    if (cim_odata !== last_data || cim_odata_oc_mask !== last_mask || cim_odata_phase !== last_phase)
      $fatal(
        1,
        "TB: data/tag/hold mismatch cycle=%0d expected=%h/%h/%h got=%h/%h/%h",
        cycle_count,
        last_data,
        last_mask,
        last_phase,
        cim_odata,
        cim_odata_oc_mask,
        cim_odata_phase
      );
  end
end

// Four shared mode bits cross the SAME n+1 edge as the CSA rows. Check
// capture/hold and independently derive the CPA-cycle correction formula.
always @(posedge clock) begin : shared_correction_check
  bit capture;
  logic [3:0] saved, incoming;
  logic [17:0] expected_correction;
  int width, pairs, pair_offset;
  if (reset_n && !negative_mode) begin
    capture = dut.in_valid && (|(dut.mask_in & dut.result_mask_in));
    saved = {dut.weight_mode_cpa, dut.signed_en_cpa,
             dut.activation_signed_cpa};
    incoming = {dut.weight_mode_in, dut.signed_en_in,
                dut.activation_signed_in};
    if (capture) begin
      width = 2 << int'(dut.weight_mode_in);
      pairs = 128/width;
      pair_offset = 15*(1 << width)*int'(dut.signed_en_in) +
                    8*((1 << (width+1))-1)*int'(dut.activation_signed_in) -
                    16*(1 << width)*int'(dut.signed_en_in)*int'(dut.activation_signed_in);
      expected_correction = 18'(-pairs*pair_offset);
    end
    #0.002;
    if (reset_n) begin
      if ({dut.weight_mode_cpa, dut.signed_en_cpa,
           dut.activation_signed_cpa} !== (capture ? incoming : saved))
        $fatal(1, "Shared CPA mode capture/hold mismatch");
      if (capture && dut.correction_cpa !== expected_correction)
        $fatal(1, "CPA correction formula mismatch expected=%h got=%h",
               expected_correction, dut.correction_cpa);
    end
  end
end

for (genvar oc = 0; oc < 4; oc++) begin : g_csa_zero_correction_check
  always @(posedge clock)
    if (dut.g_oc[oc].u_compute.u_main_tree.u_csa.correction !== 18'b0)
      $fatal(1, "Fixed CSA correction must be tied to zero OC=%0d", oc);
end

// Incoming W precision controls ACT capture on this edge. Check real clocks,
// exact captured data and retained inactive bits, independently of RTL decode.
for (genvar bank = 0; bank < 3; bank++) begin : g_act_capture_check
  localparam int FIRST = bank == 0 ? 0 : bank == 1 ? 128 : 256;
  localparam int WIDTH = bank == 2 ? 256 : 128;
  always @(posedge clock or negedge reset_n) begin
    bit want;
    logic [WIDTH - 1:0] saved, expected_act;
    if (!reset_n) begin
      #0.002;
      if (dut.activation_in[FIRST +: WIDTH] !== '0)
        $fatal(1, "ACT bank asynchronous reset_n failed bank=%0d", bank);
    end else if (!negative_mode) begin
      want = cim_ren && (|cim_oc_mask) &&
             (bank == 0 || (bank == 1 ? cim_precision <= 4 : cim_precision <= 1));
      saved = dut.activation_in[FIRST +: WIDTH];
      expected_act = cim_idata[FIRST +: WIDTH];
      #0.002;
      if (reset_n) begin
        if (dut.act_clock[bank] !== (CLOCK_GATING ? want : 1'b1))
          $fatal(1, "ACT bank clock mismatch bank=%0d precision=%0d", bank, cim_precision);
        if (dut.activation_in[FIRST +: WIDTH] !== (want ? expected_act : saved))
          $fatal(1, "ACT bank capture/hold mismatch bank=%0d precision=%0d", bank, cim_precision);
      end
    end
  end
end
