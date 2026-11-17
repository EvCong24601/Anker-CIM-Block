`timescale 1ns / 1ps
// Independent operand/whole-job oracle and cycle assertions for the three ports.
module tb_ClusterChannels;
  import cluster_pkg::*;
  parameter bit CHECK_GATE_EQUIVALENCE = 1;
  logic clock = 0, reset_n = 0;
  always #5 clock = ~clock;
  cluster_ctrl_t cmd_i = '0;
  logic cmd_valid_i = 0, weight_valid_i = 0, act_valid_i = 0;
  logic [7:0] weight_raddr_i = 0;
  logic [1023:0] act_data_i = 0;
  wire cmd_ready_o, weight_ready_o, act_ready_o;
  logic sram_cs_en = 0, sram_wr_en = 0, sram_macro_group = 0;
  logic [1:0] sram_bank_sel = 0;
  logic [7:0] sram_row_addr = 0;
  logic [3:0] sram_wmask = 0;
  logic [1023:0] sram_wrdata = 0;
  wire [1023:0] sram_rd_data, raw_psum;
  wire sram_rd_valid;
  wire [31:0] psum_valid;
  cluster_top dut (.*);
  if (CHECK_GATE_EQUIVALENCE) begin : g_mirror
    wire cr, wr, ar, srv;
    wire [1023:0] sr, raw;
    wire [31:0] pv;
    cluster_top #(
      .USE_CLOCK_GATING(0)
    ) reference (
      .cmd_ready_o(cr),
      .weight_ready_o(wr),
      .act_ready_o(ar),
      .sram_rd_data(sr),
      .sram_rd_valid(srv),
      .raw_psum(raw),
      .psum_valid(pv),
      .*
    );
    always @(posedge clock) begin
      #0.003;
      if({cr,wr,ar,srv,pv,sr,raw} !== {cmd_ready_o,weight_ready_o,act_ready_o,sram_rd_valid,psum_valid,sram_rd_data,raw_psum} ||
          dut.issue!==reference.issue)
        $fatal(1, "CHANNELS: gated/ungated mismatch");
    end
  end
  `include "include/cluster_channel_driver.svh"
  localparam int JOBS = 4096, QUEUE = 4096;
  cluster_ctrl_t configs[JOBS];
  int cmd_cycle[JOBS], cmd_offer_cycle[JOBS], first_issue[JOBS], last_issue[JOBS], last_output[JOBS];
  int prior_drain[JOBS];
  int last_due[JOBS];
  int offered_job = -1, accepted_jobs = 0, issue_job = 0, issue_index = 0, cycle = 0;
  longint signed expected[32][QUEUE];
  int expected_job[32][QUEUE], expected_context[32][QUEUE], due[32][QUEUE];
  int head[32], tail[32], reserved[32];
  int results = 0, overlap = 0, switches = 0, switch_waits = 0, weight_stalls = 0, act_stalls = 0;
  int drain_during_stall = 0, weight_backpressure = 0, act_backpressure = 0, metrics, events;
  int dw_width = 0;
  bit checking = 0, held_cmd = 0, held_weight = 0, held_act = 0;
  cluster_ctrl_t previous_cmd;
  logic [7:0] previous_weight;
  logic [1023:0] previous_act;
  function automatic int wb(int p);
    case (p)
      0, 1: return 2;
      2, 3, 4: return 4;
      default: return 8;
    endcase
  endfunction
  function automatic int ab(int p);
    case (p)
      0, 2: return 4;
      1, 3, 5: return 8;
      default: return 16;
    endcase
  endfunction
  // Independent semantic oracle: do not call the RTL key function.
  function automatic bit compatible(cluster_ctrl_t a, cluster_ctrl_t b);
    return ab(int'(a.cim_precision)) == ab(int'(b.cim_precision)) &&
           (a.cim_as_cnt > 1) == (b.cim_as_cnt > 1) &&
           (a.cim_os_cnt > 1 || a.cim_as_cnt > 1) == (b.cim_os_cnt > 1 || b.cim_as_cnt > 1) &&
           (a.cim_reduce_split_mask == b.cim_reduce_split_mask || channel_route_class(a) == 3 ||
            channel_route_class(b) == 3 || (channel_route_class(a) < 3 && channel_route_class(a) == channel_route_class(b)));
  endfunction
  function automatic int contexts(cluster_ctrl_t c);
    return c.cim_ws_cnt > 1 ? int'(c.cim_ws_cnt) : int'(c.cim_as_cnt);
  endfunction
  function automatic int first_leaf(logic [6:0] split, int m);
    int first, size, node;
    first = 0;
    size  = 8;
    node  = 0;
    while (size > 1 && split[node]) begin
      size /= 2;
      if (m >= first + size) begin
        first += size;
        node = 2 * node + 2;
      end else node = 2 * node + 1;
    end
    return first;
  endfunction
  function automatic int group_of(logic [6:0] split, int m);
    int g;
    g = 0;
    for (int n = 1; n <= m; n++) if (first_leaf(split, n) != first_leaf(split, n - 1)) g++;
    return g;
  endfunction
  function automatic int span(logic [6:0] split, int m);
    int n;
    n = 0;
    for (int j = 0; j < 8; j++) if (first_leaf(split, j) == first_leaf(split, m)) n++;
    return n;
  endfunction
  function automatic bit contributes(cluster_ctrl_t cfg, int m, int c);
    for (int width = 1; width <= span(cfg.cim_reduce_split_mask, m); width *= 2)
    if (!cfg.cim_macro_oc_mask[4*((m/width)*width)+c]) return 0;
    return 1;
  endfunction
  function automatic int address(int job, int kt, int cx);
    return (job + 2 * kt + cx) % 16;
  endfunction
  function automatic int row_byte(int addr, int m, int c, int j);
    return (addr * 17 + m * 13 + c * 7 + j * 3 + 1) & 255;
  endfunction
  function automatic int activation(int job, int kt, int cx, int k, bit sign_en);
    int v, limit;
    if (dw_width != 0) begin
      limit = 1 << ab(int'(configs[job].cim_precision));
      v = (job*43 + kt*17 + cx*31 + (k%32)*13 + (k/32)*7 + k*k*3) % limit;
      return sign_en && v >= limit/2 ? v-limit : v;
    end
    limit = ab(int'(configs[job].cim_precision)) == 4 ? 15 : 63;
    v = (job * 11 + kt * 5 + cx * 13 + k * 3) % limit;
    return sign_en ? v - limit / 2 : v;
  endfunction
  function automatic logic [1023:0] make_plane(int job, int kt, int cx, int ph);
    logic [1023:0] data;
    for (int k = 0; k < 256; k++) data[4*k+:4] = 4'(activation(job, kt, cx, k, configs[job].cim_signed_en) >> (4 * ph));
    return data;
  endfunction
  task automatic expect_job(int job, cluster_ctrl_t cfg);
    longint signed value[32], w, a;
    bit mask[32];
    int width, kr, l, addr, slot;
    width = wb(int'(cfg.cim_precision));
    kr = 256 / width;
    for (int cx = 0; cx < contexts(cfg); cx++) begin
      for (int i = 0; i < 32; i++) begin
        value[i] = 0;
        mask[i]  = 0;
      end
      for (int kt = 0; kt < int'(cfg.cim_os_cnt); kt++)
      for (int m = 0; m < 8; m++)
      for (int c = 0; c < 4; c++)
      if (cfg.cim_macro_en_mask[m] && contributes(cfg, m, c)) begin
        l = 4 * group_of(cfg.cim_reduce_split_mask, m) + c;
        mask[l] = 1;
        addr = address(job, kt, cfg.cim_as_cnt > 1 ? cx : 0);
        slot = int'(cfg.cim_act_slot_sel[3*m+:3]);
        for (int k = 0; k < kr; k++) begin
          w = (row_byte(addr, m, c, k * width / 8) >> ((k * width) % 8)) & ((1 << width) - 1);
          if (cfg.cim_signed_en && w >= (1 << (width - 1))) w -= 1 << width;
          a = activation(job, kt, cfg.cim_as_cnt > 1 ? 0 : cx, slot * kr + k, cfg.cim_signed_en);
          value[l] += w * a;
        end
      end
      for (int l = 0; l < 32; l++)
      if (mask[l]) begin
        if (tail[l] - head[l] >= QUEUE) $fatal(1, "CHANNELS: oracle queue overflow");
        expected[l][tail[l]%QUEUE] = value[l];
        expected_job[l][tail[l]%QUEUE] = job;
        expected_context[l][tail[l]%QUEUE] = cx;
        tail[l]++;
      end
    end
  endtask
  // Two same-control, single-issue jobs. Keep cmd independent of both
  // operand producers, including when their beats belong to different jobs.
  task automatic mixed_live_beats(cluster_ctrl_t cfg, bit late_weight, int next_gap);
    int j;
    j = offered_job + 1;
    offered_job = j;
    configs[j] = cfg;
    fork
      channel_cmd(cfg);
      if (late_weight) channel_act(make_plane(j, 0, 0, 0));
      else channel_weight(8'(address(j, 0, 0)));
    join
    offered_job = j + 1;
    configs[j+1] = cfg;
    fork
      channel_cmd(cfg);
      begin
        if (late_weight) channel_weight(8'(address(j, 0, 0)), 2);
        channel_weight(8'(address(j+1, 0, 0)), late_weight ? 0 : next_gap);
      end
      begin
        if (!late_weight) channel_act(make_plane(j, 0, 0, 0), 2);
        channel_act(make_plane(j+1, 0, 0, 0), late_weight ? next_gap : 0);
      end
    join
    if (last_issue[j] != cmd_cycle[j] + 3 || cmd_cycle[j+1] != last_issue[j] ||
        first_issue[j+1] != (next_gap > 3 ? cmd_cycle[j] + next_gap + 1 : last_issue[j] + 1))
      $fatal(1, "CHANNELS: mixed-owner turnover job=%0d", j);
  endtask
  always @(posedge clock) begin : monitor
    int job, p, cx, kt, phase_count, nctx, latency, lane_job, earliest;
    bit outstanding, missing;
    cycle++;
    if (reset_n && checking) begin
      missing = dut.packet_active && !dut.issue;
      if (cmd_valid_i && cmd_offer_cycle[offered_job] < 0) cmd_offer_cycle[offered_job] = cycle;
      $fdisplay(events, "%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%08h", cycle, cmd_valid_i, cmd_ready_o,
                weight_valid_i, weight_ready_o, act_valid_i, act_ready_o, dut.issue, dut.packet_active, dut.phase,
                dut.context_idx, dut.tile, psum_valid);
      if (held_cmd && (!cmd_valid_i || cmd_i !== previous_cmd)) $fatal(1, "CHANNELS: cmd changed under backpressure");
      if (held_weight && (!weight_valid_i || weight_raddr_i !== previous_weight))
        $fatal(1, "CHANNELS: weight changed under backpressure");
      if (held_act && (!act_valid_i || act_data_i !== previous_act))
        $fatal(1, "CHANNELS: ACT changed under backpressure");
      held_cmd = cmd_valid_i && !cmd_ready_o;
      previous_cmd = cmd_i;
      held_weight = weight_valid_i && !weight_ready_o;
      previous_weight = weight_raddr_i;
      held_act = act_valid_i && !act_ready_o;
      previous_act = act_data_i;
      if (held_cmd) switch_waits++;
      if (held_weight) weight_backpressure++;
      if (held_act) act_backpressure++;
      if (missing && dut.act_slice_valid[dut.phase]) weight_stalls++;
      if (missing && !dut.act_slice_valid[dut.phase]) act_stalls++;
      // Real synchronous consumer: sample pre-NBA, including the final old
      // result on the edge that may install a different active config.
      for (int l = 0; l < 32; l++)
      if (psum_valid[l]) begin
        if (head[l] == tail[l] || head[l] >= reserved[l]) $fatal(1, "CHANNELS: unreserved output lane=%0d", l);
        lane_job = expected_job[l][head[l]%QUEUE];
        if ($signed(
            raw_psum[32*l+:32]
          ) !== 32'(expected[l][head[l]%QUEUE]) || cycle != due[l][head[l]%QUEUE] ||
            dut.raw_context[l] != expected_context[l][head[l]%QUEUE])
          $fatal(
            1,
            "CHANNELS: result mismatch job=%0d lane=%0d cycle=%0d due=%0d got=%0d expected=%0d",
            lane_job,
            l,
            cycle,
            due[l][head[l]%QUEUE],
            $signed(
              raw_psum[32*l+:32]
            ),
            expected[l][head[l]%QUEUE]
          );
        last_output[lane_job] = cycle;
        head[l]++;
        results++;
        if (missing) drain_during_stall++;
      end
      if (dut.issue) begin
        job = issue_job;
        if (job >= accepted_jobs) $fatal(1, "CHANNELS: issue before command");
        phase_count = ab(int'(configs[job].cim_precision)) / 4;
        nctx = contexts(configs[job]);
        kt = issue_index / (phase_count * nctx);
        if (configs[job].cim_as_cnt > 1) begin
          p  = (issue_index / nctx) % phase_count;
          cx = issue_index % nctx;
        end else begin
          p  = issue_index % phase_count;
          cx = (issue_index / phase_count) % nctx;
        end
        if (dut.phase != p || dut.context_idx != cx || dut.tile != kt || dut.issue_weight_address != 8'(address(
            job, kt, configs[job].cim_as_cnt > 1 ? cx : 0
          )) || dut.plane !== make_plane(
            job, kt, configs[job].cim_as_cnt > 1 ? 0 : cx, p
          ))
          $fatal(1, "CHANNELS: issue binding mismatch job=%0d idx=%0d", job, issue_index);
        if (dw_width != 0)
          check_k256_issue(configs[job], make_plane(job, kt, configs[job].cim_as_cnt > 1 ? 0 : cx, p));
        if (first_issue[job] < 0) first_issue[job] = cycle;
        if (p == phase_count - 1 && kt == int'(configs[job].cim_os_cnt) - 1)
          for (int l = 0; l < 32; l++)
          if (dut.issue_mask[l]) begin
            latency = span(configs[job].cim_reduce_split_mask, l / 4);  // overwritten below using physical group
            for (int m = 0; m < 8; m++)
            if (group_of(configs[job].cim_reduce_split_mask, m) == l / 4)
              latency = span(configs[job].cim_reduce_split_mask, m);
            latency = latency <= 2 ? 3 : latency == 4 ? 4 : 5;
            if (configs[job].cim_os_cnt > 1 || configs[job].cim_as_cnt > 1) latency++;
            if (expected_job[l][reserved[l]%QUEUE] != job || expected_context[l][reserved[l]%QUEUE] != cx)
              $fatal(1, "CHANNELS: reservation order mismatch");
            due[l][reserved[l]%QUEUE] = cycle + latency + 1;
            if (cycle + latency + 1 > last_due[job]) last_due[job] = cycle + latency + 1;
            reserved[l]++;
          end
        issue_index++;
        if (issue_index == int'(configs[job].cim_os_cnt) * phase_count * nctx) begin
          last_issue[job] = cycle;
          issue_index = 0;
          issue_job++;
        end
      end
      if (cmd_valid_i && cmd_ready_o) begin
        job = offered_job;
        if (job != accepted_jobs || (job > 0 && last_issue[job-1] < 0)) $fatal(1, "CHANNELS: pending command accepted");
        outstanding = 0;
        for (int l = 0; l < 32; l++) if (head[l] != tail[l]) outstanding = 1;
        if (job > 0 && !compatible(cmd_i,configs[job-1])) begin
          switches++;
        end else if (outstanding) overlap++;
        if (job > 0) begin
          // Check the complete job history, not just the preceding (possibly
          // empty) command. Output due dates come from the independent oracle.
          prior_drain[job] = last_issue[job-1];
          for (int old = 0; old < job; old++)
            if (last_due[old] > prior_drain[job] && !compatible(cmd_i,configs[old]))
              prior_drain[job] = last_due[old];
          if (cycle < prior_drain[job]) $fatal(1,"CHANNELS: incompatible in-flight job not drained");
          earliest = prior_drain[job];
          if (cmd_offer_cycle[job] > earliest) earliest = cmd_offer_cycle[job];
          if (cycle != earliest)
            $fatal(
              1, "CHANNELS: avoidable command switch bubble job=%0d actual=%0d earliest=%0d", job, cycle, earliest
            );
        end
        if (cmd_i !== configs[job]) $fatal(1, "CHANNELS: command payload mismatch job=%0d", job);
        cmd_cycle[job] = cycle;
        accepted_jobs++;
        expect_job(job, cmd_i);
      end
    end
  end
  task automatic send_job(cluster_ctrl_t cfg, int weight_delay, int act_delay);
    int job;
    job = offered_job + 1;
    offered_job = job;
    configs[job] = cfg;
    fork
      channel_cmd(cfg);
      begin
        if (weight_delay > 0) begin
          do @(posedge clock); while (!(cmd_valid_i && cmd_ready_o));
          @(negedge clock);
        end
        for (int kt = 0; kt < int'(cfg.cim_os_cnt); kt++)
        for (int cx = 0; cx < int'(cfg.cim_as_cnt); cx++)
        channel_weight(8'(address(job, kt, cx)),
                       weight_delay == 0 ? 0 : (kt == 0 && cx == 0 ? weight_delay : (cx + kt) % 3));
      end
      begin
        if (act_delay > 0) begin
          do @(posedge clock); while (!(cmd_valid_i && cmd_ready_o));
          @(negedge clock);
        end
        for (int kt = 0; kt < int'(cfg.cim_os_cnt); kt++)
        for (int cx = 0; cx < int'(cfg.cim_ws_cnt); cx++)
        for (int ph = 0; ph < ab(int'(cfg.cim_precision)) / 4; ph++)
        channel_act(make_plane(job, kt, cx, ph),
                    act_delay == 0 ? 0 : (kt == 0 && cx == 0 && ph == 0 ? act_delay : (ph + cx + kt) % 3));
      end
    join
  endtask
  // Keep the second command offered while the first single-issue A4 job
  // is missing both beats. Its final live beats still belong to that job.
  task automatic final_live_beats(cluster_ctrl_t cfg);
    int old_job;
    old_job = offered_job + 1;
    offered_job = old_job;
    configs[old_job] = cfg;
    channel_cmd(cfg);
    offered_job = old_job + 1;
    configs[old_job+1] = cfg;
    fork
      channel_cmd(cfg);
      begin
        channel_weight(8'(address(old_job, 0, 0)), 4);
        channel_weight(8'(address(old_job+1, 0, 0)));
      end
      begin
        channel_act(make_plane(old_job, 0, 0, 0), 4);
        channel_act(make_plane(old_job+1, 0, 0, 0));
      end
    join
    if (last_issue[old_job] != cmd_cycle[old_job] + 5 || cmd_cycle[old_job+1] != last_issue[old_job])
      $fatal(1, "CHANNELS: final live beats lost or assigned to the next command");
  endtask
  // The previous job has a different control word. Accept the new command,
  // hold one operand back, then require issue on the first eligible edge.
  task automatic switch_with_missing_operand(cluster_ctrl_t cfg, bit wait_for_weight);
    int job;
    job = offered_job + 1;
    send_job(cfg, wait_for_weight ? 10 : 0, wait_for_weight ? 0 : 10);
    while (first_issue[job] < 0) @(negedge clock);
    if (first_issue[job] != cmd_cycle[job] + 11)
      $fatal(1, "CHANNELS: config switch with missing operand job=%0d weight_delayed=%0b cmd=%0d issue=%0d",
             job, wait_for_weight, cmd_cycle[job], first_issue[job]);
  endtask
  task automatic check_last_act_bypass();
    logic [4095:0] previous_bank;
    do @(posedge clock); while (!(act_valid_i && act_ready_o && dut.issue && dut.issue_weight_address == 8'h03));
    previous_bank = dut.act_buffer;
    if (!dut.forward_act || dut.act_buffer_we !== 1'b0 || previous_bank[1023:0] === act_data_i)
      $fatal(1, "ACT_WE: expected final live ACT with distinct payload and write disabled");
    #0.002;
    if (cycle != 142 || dut.act_plane_clock !== 4'b0000 || dut.act_buffer !== previous_bank ||
        dut.act_slice_valid !== '0 || dut.act_tiles_left != 0)
      $fatal(1, "ACT_WE: C142 must hold all ACT data while consuming the plane");
    $display("C%0d last-use bypass: act_plane_clock=%b", cycle, dut.act_plane_clock);
  endtask

  // Two W4A4 tiles share one ACT bank slot. Each plane serves three AS contexts.
  task automatic check_as_plane_reuse();
    logic [1023:0] old_plane, new_plane;
    do @(posedge clock); while (!(dut.issue && dut.batch_command.cim_as_cnt == 3));
    old_plane = act_data_i;
    if (dut.context_idx != 0 || !dut.forward_act || dut.act_buffer_we !== 1'b1)
      $fatal(1, "ACT_WE: ctx0 must forward and retain the first AS plane");
    #0.002;
    if (dut.act_plane_clock !== 4'b0001 || dut.act_buffer[1023:0] !== old_plane || dut.act_slice_valid[0] !== 1'b1)
      $fatal(1, "ACT_WE: forwarded AS plane was not retained");
    $display("C%0d AS ctx0 capture: act_plane_clock=%b", cycle, dut.act_plane_clock);
    for (int ctx = 1; ctx <= 2; ctx++) begin
      @(posedge clock);
      if (!dut.issue || dut.tile != 0 || dut.context_idx != ctx || dut.forward_act || dut.plane !== old_plane)
        $fatal(1, "ACT_WE: ctx%0d did not reuse the buffered plane", ctx);
      if (ctx == 1) begin
        #0.002;
        if (dut.act_plane_clock !== 4'b0000) $fatal(1, "ACT_WE: read-only AS reuse clocked a plane");
        $display("C%0d AS ctx1 reuse: act_plane_clock=%b", cycle, dut.act_plane_clock);
      end
    end
    // On ctx2's release edge, the next tile transfers its distinct ACT into the same slot.
    new_plane = act_data_i;
    if (!(act_valid_i && act_ready_o) || !dut.release_plane || dut.act_buffer_we !== 1'b1 ||
        dut.external_phase != 0 || new_plane === old_plane)
      $fatal(1, "ACT_WE: expected old-plane release and new-plane write on the same edge");
    #0.002;
    if (dut.act_plane_clock !== 4'b0001 || dut.act_buffer[1023:0] !== new_plane || dut.act_slice_valid[0] !== 1'b1)
      $fatal(1, "ACT_WE: lost replacement plane on old-plane release");
    $display("C%0d AS ctx2 replace: act_plane_clock=%b", cycle, dut.act_plane_clock);
    @(posedge clock);
    if (!dut.issue || dut.tile != 1 || dut.context_idx != 0 || dut.forward_act || dut.plane !== new_plane)
      $fatal(1, "ACT_WE: next tile did not issue with the replacement plane");
  endtask

  function automatic cluster_ctrl_t config_for(int precision, int split_id, int mode, int os, bit sign_en);
    cluster_ctrl_t cfg;
    cfg = '0;
    cfg.cim_os_cnt = 9'(os);
    cfg.cim_ws_cnt = mode == 1 ? 3 : 1;
    cfg.cim_as_cnt = mode == 2 ? 3 : 1;
    cfg.cim_precision = 3'(precision);
    cfg.cim_signed_en = sign_en;
    case (split_id)
      0: cfg.cim_reduce_split_mask = 7'h7f;
      1: cfg.cim_reduce_split_mask = 7'h07;
      2: cfg.cim_reduce_split_mask = 7'h01;
      3: cfg.cim_reduce_split_mask = 0;
      default: cfg.cim_reduce_split_mask = 7'h0b;
    endcase
    cfg.cim_macro_oc_mask = '1;
    for (int m = 0; m < 8; m++) begin
      // At most W_bits Macros per group can have distinct ACT windows.
      if (m - first_leaf(cfg.cim_reduce_split_mask, m) < wb(precision)) cfg.cim_macro_en_mask[m] = 1;
      cfg.cim_act_slot_sel[3*m+:3] = 3'((m - first_leaf(cfg.cim_reduce_split_mask, m)) % wb(precision));
    end
    return cfg;
  endfunction
  `include "include/cluster_dw_k256_cases.svh"
  `include "include/cluster_pipeline_cases.svh"
  `include "include/cluster_mask_cases.svh"
  `include "include/cluster_path_cases.svh"
  `include "include/cluster_gate_checks.svh"
  initial begin : run
    cluster_ctrl_t cfg;
    string directory;
    directory = ".";
    if ($value$plusargs("DATA_DIR=%s", directory)) begin
    end
    metrics = $fopen({directory, "/channel_cycles.csv"}, "w");
    events  = $fopen({directory, "/channel_events.csv"}, "w");
    if (!metrics || !events) $fatal(1, "CHANNELS: cannot open cycle trace");
    $fdisplay(
      events,
      "cycle,cmd_valid,cmd_ready,weight_valid,weight_ready,act_valid,act_ready,issue,input_active,phase,context,tile,psum_valid_hex");
    for (int l = 0; l < 32; l++) begin
      head[l] = 0;
      tail[l] = 0;
      reserved[l] = 0;
    end
    for (int j = 0; j < JOBS; j++) begin
      cmd_offer_cycle[j] = -1;
      first_issue[j] = -1;
      last_issue[j] = -1;
      last_output[j] = -1;
      last_due[j] = 0;
      prior_drain[j] = 0;
    end
    repeat (4) @(negedge clock);
    reset_n = 1;
    // All weights enter through the real public SRAM write port.
    for (int addr = 0; addr < 16; addr++)
    for (int m = 0; m < 8; m++) begin
      sram_cs_en = 1;
      sram_wr_en = 1;
      sram_macro_group = 1'(m / 4);
      sram_bank_sel = 2'(m % 4);
      sram_row_addr = 8'(addr);
      for (int c = 0; c < 4; c++) for (int j = 0; j < 32; j++) sram_wrdata[256*c+8*j+:8] = 8'(row_byte(addr, m, c, j));
      @(negedge clock);
    end
    sram_cs_en = 0;
    sram_wr_en = 0;
    checking = 1;
    if ($bits(cluster_ctrl_t) != 102) $fatal(1, "CHANNELS: command must be 102 bits");
    if ($value$plusargs("DW_WIDTH=%d", dw_width)) run_k256_cases(dw_width);
    else if ($test$plusargs("PIPELINE_CONFIG_TEST")) run_pipeline_cases();
    else if ($test$plusargs("MASK_PIPELINE_TEST")) run_mask_cases();
    else if ($test$plusargs("PATH_CLASS_TEST")) run_path_cases();
    else if ($test$plusargs("TIMING_FIGURE")) begin
      cfg = config_for(2, 1, 0, 1, 1);
      send_job(cfg, 0, 0);
      send_job(cfg, 0, 0);
      if ($test$plusargs("ACT_BUFFER_WE_TEST")) fork
        mixed_live_beats(cfg, 1, 6);
        check_last_act_bypass();
      join
      else mixed_live_beats(cfg, 1, 6);
      cfg = config_for(2, 2, 0, 2, 1);
      send_job(cfg, 0, 0);
      if ($test$plusargs("ACT_BUFFER_WE_TEST")) begin
        cfg = config_for(2, 1, 2, 2, 1);
        fork
          send_job(cfg, 0, 2);
          check_as_plane_reuse();
        join
        $display("PASS ACT buffer last-use/reuse/replacement");
      end
    end else begin
      cfg = config_for(5, 3, 0, 1, 1);
      send_job(cfg, 0, 0);
      send_job(cfg, 10, 0);
      send_job(cfg, 0, 10);
      cfg = config_for(0, 0, 0, 1, 0);
      switch_with_missing_operand(cfg, 1);
      cfg = config_for(2, 1, 0, 1, 1);
      switch_with_missing_operand(cfg, 0);
      // Single-issue jobs exercise simultaneous retirement, admission, and
      // overwrite of both first-operand slots on consecutive edges.
      repeat (12) send_job(cfg, 0, 0);
      final_live_beats(cfg);
      mixed_live_beats(cfg, 1, 6);
      mixed_live_beats(cfg, 1, 0);
      mixed_live_beats(cfg, 0, 0);
      // Switch short/deep endpoints, precision, signedness and reuse mode.
      for (int p = 0; p < 7; p++)
      for (int split_id = 0; split_id < 5; split_id++)
      for (int mode = 0; mode < 3; mode++)
      for (int os = 1; os <= 2; os++) begin
        cfg = config_for(p, split_id, mode, os, 1'(p % 2));
        send_job(cfg, 0, 0);
        send_job(cfg, 0, 0);
        send_job(cfg, 5, 7);
      end
      // Zero effective work must drain inputs without inventing output events.
      cfg = config_for(6, 0, 0, 1, 0);
      cfg.cim_macro_oc_mask = 0;
      send_job(cfg, 0, 0);
      cfg = config_for(6, 3, 0, 1, 1);
      send_job(cfg, 0, 0);
    end
    repeat (20) @(negedge clock);
    if (issue_job != accepted_jobs || dut.batch_active) $fatal(1, "CHANNELS: jobs did not drain");
    for (int l = 0; l < 32; l++)
    if (head[l] != tail[l] || reserved[l] != tail[l]) $fatal(1, "CHANNELS: missing lane outputs");
    if (dw_width != 0) begin
      if (!dw_buffered || !dw_forwarded || !overlap || switches < 2 || !results)
        $fatal(1, "K256 DW missing buffered, bypass, turnover or output coverage");
      for (int m = 0; m < 8; m++)
        if (dw_slots_seen[m] !== 8'((1 << dw_width)-1)) $fatal(1, "Missing DW slot coverage macro=%0d", m);
      $display("PASS K256 DW W%0d jobs=%0d results=%0d buffered=%0d forwarded=%0d",
               dw_width, accepted_jobs, results, dw_buffered, dw_forwarded);
    end else if ($test$plusargs("PATH_CLASS_TEST")) begin
      if (compatible_pairs < 1000 || !path_split_changes || !path_r1_r2 || !path_r4 || !path_empty_barriers)
        $fatal(1,"PATH: missing uniform-width split/empty-barrier coverage");
      $display("PASS path_class pairs=%0d chains=%0d split_changes=%0d r1_r2=%0d r4=%0d empty_waits=%0d jobs=%0d results=%0d",
        compatible_pairs,path_chains,path_split_changes,path_r1_r2,path_r4,path_empty_barriers,accepted_jobs,results);
    end else if ($test$plusargs("MASK_PIPELINE_TEST")) begin
      if (compatible_pairs < 500 || !retiring_high_contexts || !mask_empty_handoffs || !mask_hidden_deep || !mask_pending_psum)
        $fatal(1,"MASK: missing overlap/empty/deep/Psum coverage");
      $display("PASS mask_pipeline pairs=%0d empty=%0d hidden_deep=%0d pending_psum=%0d jobs=%0d results=%0d",
        compatible_pairs,mask_empty_handoffs,mask_hidden_deep,mask_pending_psum,accepted_jobs,results);
    end else if ($test$plusargs("PIPELINE_CONFIG_TEST")) begin
      if (compatible_pairs < 200 || !overlap || !results || !retiring_high_contexts)
        $fatal(1,"PIPELINE: missing compatible overlap/high Context coverage");
      $display("PASS pipeline_config pairs=%0d high_context_retire=%0d jobs=%0d results=%0d",
               compatible_pairs,retiring_high_contexts,accepted_jobs,results);
    end else if(!overlap || !switches || !switch_waits || !weight_stalls || !act_stalls || !drain_during_stall ||
       (!$test$plusargs("TIMING_FIGURE") && (!weight_backpressure || !act_backpressure)))
      $fatal(
        1,
        "CHANNELS: coverage missing overlap=%0d switches=%0d wait=%0d wstall=%0d astall=%0d drain=%0d wbp=%0d abp=%0d",
        overlap,
        switches,
        switch_waits,
        weight_stalls,
        act_stalls,
        drain_during_stall,
        weight_backpressure,
        act_backpressure
      );
    $fdisplay(
      metrics,
      "job,precision,os,ws,as,split,cmd_accept,first_issue,last_issue,last_output,next_cmd_gap,next_issue_bubbles,same_config,prior_drain");
    for (int j = 0; j < accepted_jobs; j++)
    $fdisplay(
      metrics,
      "%0d,%0d,%0d,%0d,%0d,%02h,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",
      j,
      configs[j].cim_precision,
      configs[j].cim_os_cnt,
      configs[j].cim_ws_cnt,
      configs[j].cim_as_cnt,
      configs[j].cim_reduce_split_mask,
      cmd_cycle[j],
      first_issue[j],
      last_issue[j],
      last_output[j],
      j + 1 < accepted_jobs ? cmd_cycle[j+1] - last_issue[j] : -1,
      j + 1 < accepted_jobs ? first_issue[j+1] - last_issue[j] - 1 : -1,
      j + 1 < accepted_jobs ? compatible(configs[j],configs[j+1]) : 0,
      prior_drain[j]
    );
    $fclose(metrics);
    $fclose(events);
    $display(
      "PASS channels jobs=%0d results=%0d overlap=%0d switches=%0d switch_waits=%0d weight_stalls=%0d act_stalls=%0d drain_during_stall=%0d weight_backpressure=%0d act_backpressure=%0d",
      accepted_jobs, results, overlap, switches, switch_waits, weight_stalls, act_stalls, drain_during_stall,
      weight_backpressure, act_backpressure);
    $finish;
  end
  initial begin
    #2000000;
    $fatal(1, "CHANNELS: watchdog");
  end
endmodule
