// Regression catalog: each task enumerates one suite; the per-case behaviour lives
// in compute_cases.
// This file is included inside the parent TB module scope and is not a stand-alone
// compilation unit.
// Shared signals/counters are declared in the parent TB; do not add a module or any
// extra begin/end scope.

// Fixed leftmost OC mask: unequal masks, disabled owners, fully masked batches and
// immediate reuse.
task automatic run_oc_merge_suite();
  // Unequal masks at pair/quad/root/mixed endpoints, disabled owners,
  // completely masked batches, and immediate reuse by the next case.
  for (int p = 5; p <= 6; p++)
    for (int sign_mode = 0; sign_mode < 2; sign_mode++)
      for (int tree = 0; tree < 4; tree++)
        for (int em = 0; em < 2; em++)
          for (int om = 0; om < 3; om++)
            for (int mode = 0; mode < 3; mode++)
              run_case(p, 1'(sign_mode), tree == 0 ? 7'h00 : tree == 1 ? 7'h01 : tree == 2 ? 7'h07 : 7'h03,
                       em == 0 ? 8'hff : 8'haa, om == 0 ? 32'h84218421 : om == 1 ? 32'hfffffff0 : 32'h0, 24'hfac688, 0,
                       2, mode == 1 ? 2 : 1, mode == 2 ? 2 : 1, 0);
  $display("PASS oc_merge_leftmost cases=%0d", cases_run);
endtask

// Full plane occupancy: seven precisions, both signs, Tile/Context counts and command
// bubbles.
task automatic run_act_buffer_suite();
  int r;
  logic [7:0] standard_en;
  logic [23:0] standard_slots;
  // Every precision/sign at full 256-digit plane occupancy, single/WS/AS,
  // 1/2/16 Contexts, one/two Tiles, and with/without address-command gaps.
  for (int p = 0; p < 7; p++) begin
    case (wbits(
      p
    ))
      2: begin
        standard_en = 8'h03;
        standard_slots = 24'h000008;
      end
      4: begin
        standard_en = 8'h0f;
        standard_slots = 24'h000688;
      end
      default: begin
        standard_en = 8'hff;
        standard_slots = 24'hfac688;
      end
    endcase
    for (int sign_mode = 0; sign_mode < 2; sign_mode++)
    for (int tiles = 1; tiles <= 2; tiles++)
    for (int mode = 0; mode < 5; mode++) begin
      r = mode >= 3 ? 16 : mode >= 1 ? 2 : 1;
      if (r > OUTPUT_BUFFER_DEPTH) continue;
      for (int gaps = 0; gaps < 2; gaps++)
      run_case(p, 1'(sign_mode), 7'h00, standard_en, 32'hffffffff, standard_slots, 0, tiles,
               (mode == 1 || mode == 3) ? r : 1, (mode == 2 || mode == 4) ? r : 1, 1'(gaps));
    end
  end
  if (max_act_planes != 4 || act_buffer_checks == 0) $fatal(1, "Missing complete ACT bank coverage");
  $display("PASS act_buffer_capacity cases=%0d max_planes=%0d buffer_bits=4096 max_contexts=%0d checks=%0d", cases_run,
           max_act_planes, OUTPUT_BUFFER_DEPTH, act_buffer_checks);
endtask

// W8A16/K256: full 4096-bit ACT with WS/AS/single Context.
task automatic run_full_act_suite();
  for (int sign_mode = 0; sign_mode < 2; sign_mode++)
    for (int tiles = 1; tiles <= 2; tiles++)
      for (int mode = 0; mode < 3; mode++)
        run_case(6, 1'(sign_mode), 7'h00, 8'hff, 32'hffffffff, 24'hfac688, 0, tiles, mode == 1 ? 2 : 1,
                 mode == 2 ? 2 : 1, 0);
  $display("PASS full_act_4096 cases=%0d", cases_run);
endtask

// Mixed pair/quad endpoints: different channels may publish different Contexts in the
// same cycle.
task automatic run_mixed_context_suite();
  for (int p = 2; p <= 4; p++)
    for (int sign_mode = 0; sign_mode < 2; sign_mode++)
      for (int tiles = 1; tiles <= 2; tiles++)
        for (int mode = 0; mode < 2; mode++)
          run_case(p, 1'(sign_mode), 7'h03, 8'h55, 32'hffffffff, 24'h040000, 0, tiles, mode == 0 ? 2 : 1,
                   mode == 1 ? 2 : 1, 0);
  $fclose(manifest);
  $fclose(operation_trace);
  $display("PASS mixed_context cases=%0d", cases_run);
endtask

// In-package overlap suite: seven precisions, both signs, OS1/2, single Context/WS2/AS2.
// run_case must observe multi-slice sample/issue overlap, back-to-back AS address/issue
// overlap, and waiting for the not-yet-arrived address when bubbles are present; the
// numbers and latency still come from the independent checkers.
task automatic run_input_overlap_suite();
  logic [23:0] slots;
  logic [ 7:0] en;
  logic [ 6:0] split;
  for (int p = 0; p < 7; p++) begin
    case (wbits(
      p
    ))
      2: begin
        slots = 24'h208208;
        en = 8'h55;
        split = 7'h07;
      end
      4: begin
        slots = 24'h688688;
        en = 8'h33;
        split = 7'h01;
      end
      default: begin
        slots = 24'hfac688;
        en = 8'h0f;
        split = 0;
      end
    endcase
    for (int sign_mode = 0; sign_mode < 2; sign_mode++)
    for (int tiles = 1; tiles <= 2; tiles++)
    for (int mode = 0; mode < 3; mode++)
    for (int gaps = 0; gaps < 2; gaps++)
    run_case(p, 1'(sign_mode), split, en, 32'hffffffff, slots, 0, tiles, mode == 1 ? 2 : 1, mode == 2 ? 2 : 1,
             1'(gaps));
  end
  if (cases_run != 168) $fatal(1, "Missing input overlap scenario coverage");
  $display("PASS input_overlap cases=%0d registered_input_delay=1", cases_run);
endtask

// OS255 limit: constant extreme weights let wrapped row addresses revisit the same
// content; it checks the 8-bit maximum count, Tile advance, earlier-scheduled AS and
// accumulation, so the test does not only produce zero results.
task automatic run_os_count_limit_suite();
  for (int p = 0; p < 2; p++)
    for (int sign_mode = 0; sign_mode < 2; sign_mode++)
      for (int mode = 0; mode < 3; mode++)
        run_case(p, 1'(sign_mode), 7'h00, 8'h03, 32'hffffffff, 24'h000008, 2, 255, mode == 1 ? 2 : 1,
                 mode == 2 ? 2 : 1, 0);
  if (cases_run != 12) $fatal(1, "Missing OS255 scenario coverage");
  $display("PASS os_count_limit cases=%0d os_max=255 descriptor_bits=%0d", cases_run, $bits(cluster_ctrl_t));
endtask

// Large-Context suite: Psum stays 16 deep, only the tag/address capacity is set to 64.
// WS and AS run separately; OS1 AS16 follows the Slice/Context schedule.
task automatic run_context_stress_suite();
  logic [23:0] slots;
  logic [ 7:0] en;
  logic [ 6:0] split;
  int tiles, ws, as_count;
  int mode_count[0:3];
  if (MAX_CONTEXTS < 64 || OUTPUT_BUFFER_DEPTH != 16)
    $fatal(1, "TB: context stress requires MAX_CONTEXTS>=64 and OUTPUT_BUFFER_DEPTH=16");
  if (WGT_RADDR_BUFFER_DEPTH != 16 || $bits(dut.context_address) != 16 * 8)
    $fatal(1, "TB: weight address buffer must contain exactly 16 eight-bit entries");
  for (int mode = 0; mode < 4; mode++) mode_count[mode] = 0;
  for (int p = 0; p < 7; p++) begin
    case (wbits(
      p
    ))
      2: begin
        slots = 24'h208208;
        en = 8'h55;
        split = 7'h07;
      end
      4: begin
        slots = 24'h688688;
        en = 8'h33;
        split = 7'h01;
      end
      default: begin
        slots = 24'hfac688;
        en = 8'h0f;
        split = 0;
      end
    endcase
    for (int sign_mode = 0; sign_mode < 2; sign_mode++)
    for (int mode = 0; mode < 4; mode++) begin
      tiles = mode < 2 ? 1 : 2;
      ws = (mode == 0) ? 64 : (mode == 2) ? 8 : 1;
      as_count = (mode == 1) ? 16 : (mode == 3) ? 8 : 1;
      for (int pattern = 0; pattern <= 4; pattern += 4)
      for (int gaps = 0; gaps < 2; gaps++) begin
        run_case(p, 1'(sign_mode), split, en, 32'hffffffff, slots, pattern, tiles, ws, as_count, 1'(gaps));
        mode_count[mode]++;
      end
    end
  end
  if (cases_run != 224 || mode_count[0] != 56 || mode_count[1] != 56 || mode_count[2] != 56 || mode_count[3] != 56)
    $fatal(1, "TB: missing large-Context scenario coverage");
  $display(
    string'({"PASS context_stress cases=%0d OS1_WS64=%0d OS1_AS16=%0d OS2_WS8=%0d OS2_AS8=%0d ",
             "psum_depth=%0d max_contexts=%0d weight_address_depth=%0d weight_address_bits=%0d"}),
    cases_run, mode_count[0], mode_count[1], mode_count[2], mode_count[3], OUTPUT_BUFFER_DEPTH, MAX_CONTEXTS,
    WGT_RADDR_BUFFER_DEPTH, $bits(dut.context_address));
endtask

// Default regression: exhaustive legal splits + six standard schedules + multi-Context
// and multi-Tile extremes.
// Every suite shares run_case, so there is no second driver or set of golden values.
task automatic run_default_suite();
  int legal_count, n, r;
  logic [23:0] standard_slots;
  logic [ 7:0] standard_en;
  logic [ 6:0] standard_split;
  for (int p = 0; p < 7; p++) begin
    legal_count = 0;
    for (int mask = 0; mask < 128; mask++)
    if (canonical(7'(mask)) && legal_k(p, 7'(mask))) begin
      legal_count++;
      for (int s = 0; s < 2; s++) begin
        $fwrite(manifest, "%0d,%0d,%02h,%02h,%08h,%06h", p, s, 7'(mask), EN_MASK, OC_MASK, make_slots(7'(mask)));
        for (int g = 0; g < 8; g++) begin
          n = 0;
          for (int m = 0; m < 8; m++) if (EN_MASK[m] && group_of(7'(mask), m) == g) n++;
          $fwrite(manifest, ",%0d", n * (256 / wbits(p)));
        end
        $fwrite(manifest, "\n");
        configurations++;
        for (int pattern = 0; pattern < PATTERNS; pattern++)
        run_case(p, 1'(s), 7'(mask), EN_MASK, OC_MASK, make_slots(7'(mask)), pattern, OS_TILES, 1, 1, pattern == 0);
      end
    end
    $display("precision=%0d W%0dA%0d splits/sign=%0d", p, wbits(p), abits(p), legal_count);
    case (wbits(
      p
    ))
      2: begin
        standard_slots = 24'h208208;
        standard_en = 8'h55;
        standard_split = 7'h07;
      end
      4: begin
        standard_slots = 24'h688688;
        standard_en = 8'h33;
        standard_split = 7'h01;
      end
      default: begin
        standard_slots = 24'hfac688;
        standard_en = 8'h0f;
        standard_split = 0;
      end
    endcase
    // Six chapter-4 schedules, both signs; K=128 per tile, high plane half 0.
    for (int s = 0; s < 2; s++)
    for (int mode = 0; mode < 6; mode++) begin
      standard_case = mode + 1;
      run_case(p, 1'(s), standard_split, standard_en, 32'hffffffff, standard_slots, 0, mode < 3 ? 1 : 2,
               (mode == 2 || mode == 4) ? 2 : 1, (mode == 1 || mode == 5) ? 2 : 1, 0);
    end
    standard_case = 0;
    // Six interleaved Contexts keep several raw vectors in flight at once:
    // check ordered publication with Command gaps, downstream always ready.
    r = 6;
    if (r > MAX_CONTEXTS) r = MAX_CONTEXTS;
    if (r > OUTPUT_BUFFER_DEPTH) r = OUTPUT_BUFFER_DEPTH;
    for (int s = 0; s < 2; s++)
    for (int mode = 0; mode < 2; mode++)
    run_case(p, 1'(s), standard_split, standard_en, 32'hffffffff, standard_slots, 0, 2, mode == 0 ? r : 1,
             mode == 1 ? r : 1, 1);
    // Three Tiles and three interleaved Contexts: catch history overwrite
    // beyond the two-Tile/two-Context examples, with signed extrema too.
    for (int s = 0; s < 2; s++)
    for (int mode = 0; mode < 2; mode++)
    for (int pattern = 4; pattern < 6; pattern++)
    run_case(p, 1'(s), standard_split, standard_en, 32'hffffffff, standard_slots, pattern, 3,
             mode == 0 ? (OUTPUT_BUFFER_DEPTH < 3 ? OUTPUT_BUFFER_DEPTH : 3) : 1,
             mode == 1 ? (OUTPUT_BUFFER_DEPTH < 3 ? OUTPUT_BUFFER_DEPTH : 3) : 1, 1);
  end
endtask
