// One compute case: build the weights/ACT and the independent dot-product expectation,
// drive the whole task and check completion.
// This file is included inside the parent TB module scope and is not a stand-alone
// compilation unit.
// Shared signals/counters are declared in the parent TB; do not add a module or any
// extra begin/end scope.

function automatic string pattern_name(input int pattern);
  case (pattern)
    0: return "random";
    1: return "all-zero";
    2: return "maximum";
    3: return "minimum";
    4: return "alternating-extremes";
    default: return "opposite-weight-ACT-extremes";
  endcase
endfunction
function automatic string cluster_suite();
  if ($test$plusargs("REQUANT_CHANNEL_TEST")) return "four-channel-fixed-OC-scale-mapping";
  if ($test$plusargs("REQUANT_TEST")) return "per-tensor-combinational-requant";
  if ($test$plusargs("INPUT_OVERLAP_TEST")) return "same-packet-input-issue-overlap";
  if ($test$plusargs("CONTEXT_STRESS_TEST")) return "OS1-WS64-AS16/OS2-WS8-AS8";
  if ($test$plusargs("OC_MERGE_TEST")) return "leftmost-OC-mask";
  if ($test$plusargs("ACT_BUFFER_TEST")) return "full-plane-ACT-capacity";
  if ($test$plusargs("FULL_ACT_TEST")) return "W8A16-K256-full-ACT";
  if ($test$plusargs("MIXED_CONTEXT_TEST")) return "mixed-endpoint-contexts";
  return standard_case != 0 ? "standard-cycle-timing" : "split-numeric-fusion-Psum";
endfunction
task automatic run_case(input int precision, input bit sign_en, input logic [6:0] split, input logic [7:0] en,
                        input logic [31:0] oc, input logic [23:0] slots, input int pattern, input int os,
                        input int ws, input int as_count, input bit bubbles);
  cluster_ctrl_t d;
  logic [1023:0] plane, row;
  logic [4095:0] full_act;
  int wb, ab, kr, l, slot, a_ctx, c, p, t, groups, used_digits, requant_checks_before;
  int unsigned raw;
  longint signed w, a;
  // 1. Record the case intent and configuration; every later scoreboard uses this fixed
  // configuration.
  $display(
    string'({"[CASE_START] time=%0.3f ns suite=cluster case=%0d standard_case=%0d ",
             "description=%s/%s mode=%s W%0dA%0d signed=%0d pattern=%0d os=%0d ws=%0d as=%0d ",
             "split=%02h en=%02h oc=%08h slots=%06h bubbles=%0d depth=%0d seed=%08h"}),
    $realtime, cases_run, standard_case, cluster_suite(), pattern_name(pattern),
    ws > 1 ? "WS" : as_count > 1 ? "AS" : "SINGLE", wbits(precision), abits(precision), sign_en, pattern, os, ws,
    as_count, split, en, oc, slots, bubbles, OUTPUT_BUFFER_DEPTH, SEED);
  wb = wbits(precision);
  ab = abits(precision);
  kr = 256 / wb;
  configure_requant(cases_run);
  requant_checks_before = requant_checks;
  case_os = os;
  case_ws = ws;
  case_as = as_count;
  case_pattern = pattern;
  case_bubbles = bubbles;
  if (os < 1 || os > 255 || ws < 1 || ws > 255 || as_count < 1 || as_count > 255 || (ws > 1 && as_count > 1))
    $fatal(1, "Counts must be 1..255; simultaneous WS/AS reuse is not defined");
  case_r = ws > 1 ? ws : as_count;
  case_p = ab / 4;
  d = '0;
  d.cim_os_cnt = 8'(os);
  d.cim_ws_cnt = 8'(ws);
  d.cim_as_cnt = 8'(as_count);
  d.cim_precision = 3'(precision);
  d.cim_signed_en = sign_en;
  d.cim_reduce_split_mask = split;
  d.cim_macro_en_mask = en;
  d.cim_macro_oc_mask = oc;
  d.cim_act_slot_sel = slots;
  used_digits = 0;
  for (int m = 0; m < 8; m++)
    if (en[m] && (int'(slots[3*m+:3]) + 1) * kr > used_digits) used_digits = (int'(slots[3*m+:3]) + 1) * kr;
  case_used_digits = used_digits;
  groups = 0;
  decode_groups(split, 0, 0, 8, groups);
  expected_mask = '0;
  for (int cx = 0; cx < case_r; cx++) begin
    for (int l = 0; l < 32; l++) raw_seen[cx][l] = 0;
    for (int i = 0; i < 32; i++) begin
      expected[cx][i] = 0;
      lane_due[cx][i] = -1;
    end
  end
  // 2. Generate the full integer ACT: AS reuses one copy, WS gives each Context its own
  // input.
  for (int kt = 0; kt < os; kt++)
    for (int cx = 0; cx < case_r; cx++)
      for (int k = 0; k < 256; k++) begin
        a_ctx = as_count > 1 ? 0 : cx;
        if (cx == 0 || as_count <= 1) activation[kt][cx][k] = sample_bits(ab, pattern, k + 7 * cx + kt, sign_en, 0);
        else activation[kt][cx][k] = activation[kt][0][k];
        // Keep all positive W8A16 OS extrema within signed32; no saturation.
        if (!sign_en && wb == 8 && ab == 16) activation[kt][cx][k] %= (32768 / os);
      end
  // 3. Preload the real SRAM while accumulating the golden with integer w*a; DUT
  // outputs are never read.
  // Write/read every tile/context row through the regular WLC port before compute.
  for (int kt = 0; kt < os; kt++) begin
    for (int wc = 0; wc < (as_count > 1 ? case_r : 1); wc++) begin
      for (int m = 0; m < 8; m++) begin
        row = '0;
        for (int ocid = 0; ocid < 4; ocid++)
        for (int j = 0; j < kr; j++) begin
          raw = sample_bits(wb, pattern, j + m * 7 + ocid * 3 + kt + wc * 11, sign_en, 1);
          for (int b = 0; b < wb; b++) row[256*ocid+wb*j+b] = (raw >> b) & 1;
          if (en[m] && golden_oc_path(m, ocid, oc)) begin
            l = 4 * golden_group[m] + ocid;
            slot = int'(slots[3*m+:3]);
            for (int cx = 0; cx < case_r; cx++)
            if (as_count <= 1 || cx == wc) begin
              w = number(raw, wb, sign_en);
              a = number(activation[kt][cx][slot*kr+j], ab, sign_en);
              expected[cx][l] += w * a;
              expected_mask[l] = 1;
            end
          end
        end
        load_weight_row(m, 8'('h20 + 16 * kt + wc), row);
      end
    end
  end
  for (int cx = 0; cx < case_r; cx++)
    for (int ch = 0; ch < 32; ch++)
      if (expected[cx][ch] < -64'sd2147483648 || expected[cx][ch] > 64'sd2147483647)
        $fatal(1, "Golden overflow: selected OS/pattern exceeds signed32");
  issue_count = 0;
  raw_count = 0;
  first_issue = -1;
  last_issue = -1;
  first_external = -1;
  input_commands = 0;
  act_planes_received = 0;
  exact_ii = !bubbles;
  act_issue_overlap = 0;
  address_issue_overlap = 0;
  address_wait_cycles = 0;
  late_address_wait = 0;
  held_cmd = 0;
  held_act_for_cmd = 0;
  // 4. Open the compute check window; the driver owns handshake/plane timing and the
  // scoreboard owns the verdict.
  monitoring = 1;
  for (int kt = 0; kt < os; kt++)
    for (int cx = 0; cx < (as_count > 1 ? 1 : case_r); cx++) begin
      d.cim_weight_raddr = 8'('h20 + 16 * kt);
      full_act = '0;
      for (int ph = 0; ph < case_p; ph++)
      for (int k = 0; k < used_digits; k++) full_act[1024*ph+4*k+:4] = 4'(activation[kt][cx][k] >> (4 * ph));
      send_act_frame(d, full_act, kt, bubbles ? (kt + cx) % 3 : 0, bubbles);
    end
  // 5. Poison the external ACT and wait for completion, proving the internals use the
  // saved full ACT.
  // Internal distribution must use the saved ACT, not these external pins.
  @(negedge clock);
  act_data_i = ~full_act[0+:1024];
  for (int wait_cycles = 0; wait_cycles < TIMEOUT_CYCLES; wait_cycles++) begin
    @(negedge clock);
    if (raw_count == case_r * $countones(expected_mask) && issue_count == os * case_r * case_p && !dut.batch_active)
      break;
    if (wait_cycles == TIMEOUT_CYCLES - 1) $fatal(1, "Output timeout");
  end
  if (raw_count != case_r * $countones(
      expected_mask
    ) || issue_count != os * case_r * case_p || input_commands != os * case_r)
    $fatal(1, "Lost/duplicate compute or result");
  if (act_planes_received != os * (as_count > 1 ? 1 : case_r) * case_p) $fatal(1, "ACT frame slice count mismatch");
  if (first_issue != first_external + 1) $fatal(1, "First issue did not follow the first registered Plane/address");
  if (case_p > 1 && act_issue_overlap == 0) $fatal(1, "Missing same-packet ACT load/issue overlap");
  if (as_count > 1 && !bubbles && address_issue_overlap == 0)
    $fatal(1, "Missing same-packet AS address/issue overlap");
  if (as_count > 1 && bubbles && (case_p == 1 || $test$plusargs("INPUT_OVERLAP_TEST")) && address_wait_cycles == 0)
    $fatal(1, "Missing wait for delayed AS Context address");
  if ($test$plusargs("INPUT_OVERLAP_TEST") && as_count > 1 && bubbles && late_address_wait == 0)
    $fatal(1, "Missing address wait after the full ACT stream was received");
  // 6. After draining, check that no extra output appears, so duplicate results cannot
  // leak into the next case.
  repeat (6) @(negedge clock);
  if (dut.raw_valid != 0 || dut.batch_active || requant_valid_o != 0)
    $fatal(1, "Unexpected output after the final Context published");
  if (requant_checks - requant_checks_before != (ENABLE_REQUANT ? raw_count : 0))
    $fatal(1, "Missing/duplicate Requant result after drain");
  monitoring = 0;
  cases_run++;
endtask
