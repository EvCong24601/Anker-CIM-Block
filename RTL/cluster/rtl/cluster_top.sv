`timescale 1ns / 1ps
// Simulation reference Cluster, with raw Psum and combinational INT8 Requant.
module cluster_top #(
  // Unified integration depth. Individual overrides support capacity tests.
  parameter int OUTPUT_PSUM_DEPTH = 16,
  parameter int OUTPUT_BUFFER_DEPTH = OUTPUT_PSUM_DEPTH,
  parameter int WGT_RADDR_BUFFER_DEPTH = OUTPUT_BUFFER_DEPTH,
  // Context tag/completion capacity, independent of the Psum depth. Bounds the
  // WS/AS context count; for OS1 WS it is the only limit, so up to MAX_CONTEXTS
  // contexts (e.g. 64) are legal even beyond OUTPUT_BUFFER_DEPTH.
  parameter int MAX_CONTEXTS = 64,
  parameter int REQUANT_CONTEXT_DEPTH = OUTPUT_BUFFER_DEPTH,
  parameter bit USE_CLOCK_GATING = 1,
  parameter bit ENABLE_REQUANT = 1
) (
  input logic clock,
  input logic reset,
  input cluster_pkg::cluster_ctrl_t cmd_i,
  input cluster_pkg::requant_cfg_t requant_cfg_i,
  input logic cmd_valid_i,
  output wire cmd_ready_o,
  input logic [1023:0] act_data_i,
  input logic sram_cs_en,
  input logic sram_wr_en,
  input logic sram_macro_group,
  input logic [1:0] sram_bank_sel,
  input logic [7:0] sram_row_addr,
  input logic [3:0] sram_wmask,
  input logic [1023:0] sram_wrdata,
  output wire [1023:0] sram_rd_data,
  output logic sram_rd_valid,
  // TB observation only: these are NOT public RTL output ports.
  // output logic [1023:0] psum_data_o,
  // output logic [31:0] out_valid_o,
  // Final registered INT8 data and per-lane valid; no output backpressure.
  output logic [255:0] requant_data_o,
  output logic [31:0] requant_valid_o
);
  import cluster_pkg::*;
  cluster_ctrl_t command;
  // Batch-invariant combinational decode; no additional configuration DFFs.
  logic [31:0] batch_lane_mask, batch_macro_demand;
  logic [2:0] batch_macro_group[0:7];
  logic [1:0] batch_group_path[0:7];
  logic [3:0] batch_group_size[0:7];
  logic [7:0] batch_macro_active;
  logic batch_is_as, batch_uses_psum;
  logic [2:0] batch_requant_group;
  int batch_activation_bits, batch_weight_bits, batch_phase_count;
  int batch_last_phase, batch_last_tile, batch_act_digits;
  logic [4095:0] act_buffer;  // four 1024-bit bit-slice planes, A0..A3
  logic [1023:0] plane;
  localparam int CONTEXT_W = MAX_CONTEXTS > 1 ? $clog2(MAX_CONTEXTS) : 1;
  localparam int CONTEXT_COUNT_W = MAX_CONTEXTS > 1 ? $clog2(MAX_CONTEXTS + 1) : 1;
  // Only the packet weight address changes within a batch. Other fields
  // are a combinational view of the single shared batch descriptor.
  logic [7:0] packet_weight_address;
  cluster_ctrl_t packet_cmd;
  logic [7:0] context_address[0:WGT_RADDR_BUFFER_DEPTH - 1];
  logic [7:0] current_weight_address;  // A4 AS bypass; no deep address entry clocks
  logic packet_active, act_loading, act_complete;
  logic [3:0] act_slice_valid;
  logic [1:0] external_phase;
  logic [CONTEXT_COUNT_W - 1:0] command_count;
  wire cmd_accept = cmd_valid_i && cmd_ready_o;
  logic [1:0] phase;
  logic [CONTEXT_W - 1:0] context_idx;
  logic [7:0] tile;
  int phases, contexts;  // Combinational decode, not DFF state.
  logic need_plane, issue, final_issue;
  logic [31:0] issue_mask;
  logic [7:0] active, ren, station, hold_valid;
  logic [7:0] hold_addr[0:7];
  wire [575:0] macro_data;
  wire [7:0] macro_valid;
  wire [31:0] macro_mask;
  wire [15:0] macro_phase;
  logic batch_active, batch_input_done;
  requant_cfg_t batch_requant_cfg;
  // Fixed Context slots: AS never recycles an entry within a batch.
  // A4 bypasses only the weight-address table; all AS modes retain Q params.
  logic [127:0] requant_context_zp[0:REQUANT_CONTEXT_DEPTH - 1];
  logic [127:0] requant_context_multiplier[0:REQUANT_CONTEXT_DEPTH - 1];
  logic [39:0] requant_context_shift[0:REQUANT_CONTEXT_DEPTH - 1];
  logic [REQUANT_CONTEXT_DEPTH - 1:0] requant_context_valid;
  requant_cfg_t selected_requant_cfg;
  wire deep_command = cmd_i.cim_as_cnt > 1 && abits(int'(cmd_i.cim_precision)) > 4;
  wire deep_batch = batch_is_as && batch_activation_bits > 4;
  wire a4_packet = batch_is_as && batch_activation_bits == 4;
  wire storage_active = !reset && cmd_accept && cmd_i.cim_as_cnt > 1 && abits(int'(cmd_i.cim_precision)) == 4;
  wire deep_weight_active = !reset && ((batch_active && deep_batch) || (cmd_accept && deep_command));
  wire deep_requant_active = !reset && ENABLE_REQUANT &&
      ((batch_active && batch_command.cim_as_cnt > 1) || (cmd_accept && cmd_i.cim_as_cnt > 1));
  wire channel_scale_active = deep_requant_active &&
      (batch_active ? batch_requant_cfg.requant_mode : requant_cfg_i.requant_mode);
  wire batch_cfg_load = !reset && ENABLE_REQUANT && cmd_accept && !batch_active;
  wire entry0_clock, deep_weight_clock, deep_requant_clock;
  wire channel_scale_clock, batch_cfg_clock, batch_channel_clock;
  wire [31:0] accepted_context = packet_active ? command_count : 0;
  wire [31:0] write_context_slot = accepted_context;
  wire write_requant_params = cmd_accept && ENABLE_REQUANT && cmd_i.cim_as_cnt > 1 && (!batch_active || tile == 0);
  MacroClockGate #(
    .ENABLE_GATING(USE_CLOCK_GATING)
  ) u_entry0_icg (
    .clock(clock),
    .enable(storage_active),
    .gated_clock(entry0_clock)
  );
  MacroClockGate #(
    .ENABLE_GATING(USE_CLOCK_GATING)
  ) u_deep_weight_icg (
    .clock(clock),
    .enable(deep_weight_active),
    .gated_clock(deep_weight_clock)
  );
  MacroClockGate #(
    .ENABLE_GATING(USE_CLOCK_GATING)
  ) u_deep_requant_icg (
    .clock(clock),
    .enable(deep_requant_active),
    .gated_clock(deep_requant_clock)
  );
  MacroClockGate #(
    .ENABLE_GATING(USE_CLOCK_GATING)
  ) u_channel_scale_icg (
    .clock(clock),
    .enable(channel_scale_active),
    .gated_clock(channel_scale_clock)
  );
  MacroClockGate #(
    .ENABLE_GATING(USE_CLOCK_GATING)
  ) u_batch_cfg_icg (
    .clock(clock),
    .enable(batch_cfg_load),
    .gated_clock(batch_cfg_clock)
  );
  MacroClockGate #(
    .ENABLE_GATING(USE_CLOCK_GATING)
  ) u_batch_channel_icg (
    .clock(clock),
    .enable(batch_cfg_load && requant_cfg_i.requant_mode),
    .gated_clock(batch_channel_clock)
  );

  // WS/single uses packet_cmd directly. A4 AS uses one bypass register.
  always_ff @(posedge entry0_clock or posedge reset)
    if (reset) current_weight_address <= '0;
    else if (storage_active) current_weight_address <= cmd_i.cim_weight_raddr;
  always_ff @(posedge deep_weight_clock or posedge reset) begin
    if (reset) for (int d = 0; d < WGT_RADDR_BUFFER_DEPTH; d++) context_address[d] <= '0;
    else if (cmd_accept && deep_command && write_context_slot < WGT_RADDR_BUFFER_DEPTH)
      context_address[write_context_slot] <= cmd_i.cim_weight_raddr;
  end
  // One table clock for ZP and the shared scale; unused channel scales have
  // a separate group clock. No per-entry clock gates or FIFO pointers.
  always_ff @(posedge deep_requant_clock or posedge reset) begin
    if (reset)
      for (int d = 0; d < REQUANT_CONTEXT_DEPTH; d++) begin
        requant_context_zp[d] <= '0;
        requant_context_multiplier[d][31:0] <= '0;
        requant_context_shift[d][9:0] <= '0;
      end
    else if (write_requant_params && write_context_slot < REQUANT_CONTEXT_DEPTH) begin
      requant_context_zp[write_context_slot] <= requant_cfg_i.requant_zp;
      requant_context_multiplier[write_context_slot][31:0] <= requant_cfg_i.requant_multiplier[31:0];
      requant_context_shift[write_context_slot][9:0] <= requant_cfg_i.requant_shift[9:0];
    end
  end
  always_ff @(posedge channel_scale_clock or posedge reset) begin
    if (reset)
      for (int d = 0; d < REQUANT_CONTEXT_DEPTH; d++) begin
        requant_context_multiplier[d][127:32] <= '0;
        requant_context_shift[d][39:10] <= '0;
      end
    else if (write_requant_params && requant_cfg_i.requant_mode && write_context_slot < REQUANT_CONTEXT_DEPTH) begin
      requant_context_multiplier[write_context_slot][127:32] <= requant_cfg_i.requant_multiplier[127:32];
      requant_context_shift[write_context_slot][39:10] <= requant_cfg_i.requant_shift[39:10];
    end
  end
  // Non-AS uses only this batch configuration. Its payload clocks pulse at
  // configuration load; the combinational Requant reads retained values.
  always_ff @(posedge batch_cfg_clock or posedge reset) begin
    if (reset) begin
      batch_requant_cfg.conv_mode <= 0;
      batch_requant_cfg.requant_mode <= 0;
      batch_requant_cfg.requant_zp <= '0;
      batch_requant_cfg.requant_multiplier[31:0] <= 1;
      batch_requant_cfg.requant_shift[9:0] <= '0;
    end else if (batch_cfg_load) begin
      batch_requant_cfg.conv_mode <= requant_cfg_i.conv_mode;
      batch_requant_cfg.requant_mode <= requant_cfg_i.requant_mode;
      batch_requant_cfg.requant_zp <= requant_cfg_i.requant_zp;
      batch_requant_cfg.requant_multiplier[31:0] <= requant_cfg_i.requant_multiplier[31:0];
      batch_requant_cfg.requant_shift[9:0] <= requant_cfg_i.requant_shift[9:0];
    end
  end
  always_ff @(posedge batch_channel_clock or posedge reset) begin
    if (reset) begin
      batch_requant_cfg.requant_multiplier[127:32] <= '0;
      batch_requant_cfg.requant_shift[39:10] <= '0;
    end else if (batch_cfg_load && requant_cfg_i.requant_mode) begin
      batch_requant_cfg.requant_multiplier[127:32] <= requant_cfg_i.requant_multiplier[127:32];
      batch_requant_cfg.requant_shift[39:10] <= requant_cfg_i.requant_shift[39:10];
    end
  end
  wire [2:0] regular_macro_id = {sram_macro_group, sram_bank_sel};
  wire regular_access = !reset && sram_cs_en;
  wire regular_read = regular_access && !sram_wr_en;
  wire regular_write = regular_access && sram_wr_en && !(&sram_wmask);
  wire [7:0] memory_wen = regular_write ? (8'd1 << regular_macro_id) : 8'd0;
  wire [8191:0] regular_read_data;
  // Request and response selection share the SRAM sampling edge. The
  // next live request must not change an outstanding synchronous response.
  logic [2:0] sram_response_macro;
  always_ff @(posedge clock or posedge reset) begin
    if (reset) begin
      sram_rd_valid <= 0;
      sram_response_macro <= '0;
    end else begin
      sram_rd_valid <= regular_read;
      if (regular_read) sram_response_macro <= regular_macro_id;
    end
  end
  assign sram_rd_data = sram_rd_valid ? regular_read_data[1024*sram_response_macro+:1024] : 1024'b0;
`ifndef SYNTHESIS
  always @(posedge clock)
    if (!reset) begin
      if (sram_cs_en && (batch_active || packet_active || cmd_valid_i || (|macro_valid)))
        $fatal(1, "CLUSTER_SRAM_PROTOCOL: regular access overlaps compute");
      if (sram_cs_en && ((^{sram_wr_en, sram_macro_group, sram_bank_sel, sram_row_addr}) === 1'bx))
        $fatal(1, "CLUSTER_SRAM_PROTOCOL: unknown regular address/control");
      if (sram_cs_en && sram_wr_en && ((^{sram_wmask, sram_wrdata}) === 1'bx))
        $fatal(1, "CLUSTER_SRAM_PROTOCOL: unknown regular write data/mask");
      // A4 AS keeps one shared weight address instead of a per-Context table.
      // That bypass is only correct while a Context occupies exactly one phase,
      // because issue consumes the most recently accepted address.
      if (batch_active && a4_packet && batch_phase_count != 1)
        $fatal(1, "CLUSTER_AS_PROTOCOL: A4 AS relies on one phase per Context");
    end
`endif
  typedef struct packed {
    logic valid;
    logic [1:0] ph;
    logic [CONTEXT_W - 1:0] ctx;
    logic [7:0] kt;
  } txn_meta_t;
  // Expanded views retain checker access; only compact metadata is registered.
  typedef struct packed {
    logic valid;
    cluster_ctrl_t cmd;
    int ph, ctx, kt;
    logic [31:0] mask;
  } tag_t;
  txn_meta_t pipe_meta[0:3];
  txn_meta_t tmp_path_meta[0:2];
  logic [CONTEXT_W - 1:0] raw_path_context[0:2];
  logic [31:0] path_lanes[0:2];
  tag_t in_tag, macro_tag, red1_tag, red2_tag;
  tag_t tap_tag[0:2];
  tag_t early_tmp_tag[0:2];
  wire [2:0] tap_valid;
  wire [31:0] tap_mask[0:2];
  wire [671:0] tap_data[0:2];
  always_comb begin
    tap_tag[0] = macro_tag;
    tap_tag[1] = red1_tag;
    tap_tag[2] = red2_tag;
    early_tmp_tag[0] = in_tag;
    early_tmp_tag[1] = macro_tag;
    early_tmp_tag[2] = red1_tag;
  end
  // Each tree endpoint writes one per-output-channel tmp result register.
  // The tagged arithmetic stage consumes it on the NEXT edge (II=1).
  // OUTPUT_BUFFER_DEPTH is the per-OC Context state capacity, not a FIFO.
  logic [31:0] tmp_valid;
  tag_t tmp_tag[0:31]; // Combinational views only; no per-lane tag storage.
  logic signed [31:0] tmp_result[0:31];  // one 32-bit data DFF per OC
  // One tmp data register per OC; Psum stores Context history.
  // NUMERIC LIMIT: tmp/Psum are signed32 storage. Intermediate writes truncate
  // before the final-result overflow check; there is no intermediate overflow
  // flag or saturation. Every stored intermediate must fit signed32, not only
  // the final mathematical sum. See docs/Cluster_Requant.md (Psum limits).
  logic signed [31:0] psum[0:OUTPUT_BUFFER_DEPTH - 1][0:31];
  logic [OUTPUT_BUFFER_DEPTH - 1:0] psum_depth_open;
  logic [CONTEXT_COUNT_W - 1:0] batch_contexts;
  cluster_ctrl_t batch_command;
  // Explicit advance ICG enables: registered at tmp capture, consumed by
  // the arithmetic-state DFFs on the next edge. High address depths are
  // disabled for the WHOLE batch, independently of per-cycle write requests.
  logic [31:0] tmp_input_cg_en;
  logic [31:0] psum_cg_en[0:OUTPUT_BUFFER_DEPTH - 1];
  wire [31:0] tmp_input_clock;
  wire [31:0] psum_clock[0:OUTPUT_BUFFER_DEPTH - 1];
  logic [31:0] capture_valid;
  tag_t capture_tag[0:31];
  longint signed capture_data[0:31];
  longint signed fusion_a[0:31], fusion_b[0:31], fusion_result[0:31];
  longint signed acc_a[0:31], acc_b[0:31], acc_result[0:31];
  longint signed shared_add_a[0:31], shared_add_b[0:31], shared_add_result[0:31];
  longint signed tmp_store_data[0:31], arithmetic_result[0:31];
  logic [31:0] fusion_enable, acc_enable, psum_write, result_done;
  wire [255:0] requant_comb_data;
  wire [ 31:0] requant_comb_valid;
  // Internal operation coverage; no extra external interface. The pipeline
  // block only updates state; step terms are gathered separately so each
  // counter keeps a single non-blocking driver.
`ifndef SYNTHESIS
  // Step counters are read only by the testbench scoreboards.
  int tmp_only_steps, as_seed_steps, as_fusion_steps, as_acc_steps;
  int ws_fusion_steps, ws_acc_steps, ws_tile_commits, a4_acc_steps;
  int tmp_only_inc, as_seed_inc, as_fusion_inc, as_acc_inc;
  int ws_fusion_inc, ws_acc_inc, ws_tile_commit_inc, a4_acc_inc;
  always_comb begin : count_step_terms
    tmp_only_inc = 0;
    as_seed_inc = 0;
    as_fusion_inc = 0;
    as_acc_inc = 0;
    ws_fusion_inc = 0;
    ws_acc_inc = 0;
    ws_tile_commit_inc = 0;
    a4_acc_inc = 0;
    for (int l = 0; l < 32; l++) begin
      if (capture_valid[l] && capture_tag[l].ph > 0 && !batch_is_as) ws_fusion_inc++;
      if (tmp_valid[l]) begin
        if (batch_is_as) begin
          if (tmp_tag[l].ph > 0) as_fusion_inc++;
          else if (acc_enable[l]) as_acc_inc++;
          else if (psum_write[l]) as_seed_inc++;
        end else begin
          if (tmp_tag[l].cmd.cim_os_cnt == 1) tmp_only_inc++;
          if (psum_write[l]) ws_tile_commit_inc++;
          if (acc_enable[l]) ws_acc_inc++;
        end
        if (acc_enable[l] && abits(int'(tmp_tag[l].cmd.cim_precision)) == 4) a4_acc_inc++;
      end
    end
  end
  always_ff @(posedge clock or posedge reset)
    if (reset) begin
      tmp_only_steps <= 0;
      as_seed_steps <= 0;
      as_fusion_steps <= 0;
      as_acc_steps <= 0;
      ws_fusion_steps <= 0;
      ws_acc_steps <= 0;
      ws_tile_commits <= 0;
      a4_acc_steps <= 0;
    end else begin
      tmp_only_steps <= tmp_only_steps + tmp_only_inc;
      as_seed_steps <= as_seed_steps + as_seed_inc;
      as_fusion_steps <= as_fusion_steps + as_fusion_inc;
      as_acc_steps <= as_acc_steps + as_acc_inc;
      ws_fusion_steps <= ws_fusion_steps + ws_fusion_inc;
      ws_acc_steps <= ws_acc_steps + ws_acc_inc;
      ws_tile_commits <= ws_tile_commits + ws_tile_commit_inc;
      a4_acc_steps <= a4_acc_steps + a4_acc_inc;
    end
`endif
  // No output backpressure: each fixed-latency path returns Contexts in
  // issue order. The last Context completing a path also drains all earlier
  // Contexts on that path. Per-lane reservation/duplicate checks live in TB.
  logic [2:0] completion_path_done;
  logic [2:0] completion_path_required, completion_path_last;
  // Internal observation only; no new external signal.
  // Raw observations remain available for the independent compute scoreboard.
  logic [31:0] raw_valid;
  int raw_context[0:31]; // Combinational view of three shared Context registers.
  wire [1023:0] raw_data; // Valid-qualified observation of existing tmp/Psum storage.
`ifndef SYNTHESIS
  initial begin
    if (MAX_CONTEXTS < 1 || OUTPUT_BUFFER_DEPTH < 1 || WGT_RADDR_BUFFER_DEPTH < 1 || REQUANT_CONTEXT_DEPTH < 1)
      $fatal(1, "Context capacity must be >= 1");
  end
`endif
  function automatic logic [31:0] mask_for_batch(input cluster_ctrl_t cfg);
    logic [31:0] result;
    result = '0;
    for (int m = 0; m < 8; m++)
      for (int c = 0; c < 4; c++)
        if (cfg.cim_macro_en_mask[m] && merge_contributes(cfg.cim_reduce_split_mask, cfg.cim_macro_oc_mask, m, c))
          result[4 * group_of(cfg.cim_reduce_split_mask, m) + c] = 1;
    return result;
  endfunction
  function automatic tag_t expand_meta(input txn_meta_t meta);
    tag_t result;
    result = '0;
    result.valid = meta.valid;
    result.cmd = batch_command;
    result.ph = int'(meta.ph);
    result.ctx = int'(meta.ctx);
    result.kt = int'(meta.kt);
    result.mask = batch_lane_mask;
    return result;
  endfunction
  function automatic txn_meta_t compact_tag(input tag_t tag);
    txn_meta_t result;
    result.valid = tag.valid;
    result.ph = 2'(tag.ph);
    result.ctx = CONTEXT_W'(tag.ctx);
    result.kt = 8'(tag.kt);
    return result;
  endfunction
  always_comb begin : decode_batch
    batch_is_as = batch_command.cim_as_cnt > 1;
    batch_uses_psum = batch_command.cim_os_cnt > 1 || batch_is_as;
    batch_activation_bits = abits(int'(batch_command.cim_precision));
    batch_weight_bits = wbits(int'(batch_command.cim_precision));
    batch_phase_count = batch_activation_bits / 4;
    batch_last_phase = batch_phase_count - 1;
    batch_last_tile = int'(batch_command.cim_os_cnt) - 1;
    case (batch_weight_bits)
      2: batch_act_digits = 128;
      4: batch_act_digits = 64;
      8: batch_act_digits = 32;
      default: batch_act_digits = 0;
    endcase
    batch_lane_mask = '0;
    batch_macro_demand = '0;
    batch_macro_active = '0;
    batch_requant_group = '0;
    for (int g = 0; g < 8; g++) batch_group_size[g] = '0;
    for (int m = 0; m < 8; m++) begin
      batch_macro_group[m] = 3'(group_of(batch_command.cim_reduce_split_mask, m));
      batch_group_size[batch_macro_group[m]]++;
      batch_macro_active[m] = batch_command.cim_macro_en_mask[m] &&
          (|batch_command.cim_macro_oc_mask[4*m+:4]);
      // Requant legality guarantees exactly one enabled group. Decode it
      // from Macro enables, never from OC0's potentially masked valid.
      if (batch_command.cim_macro_en_mask[m]) batch_requant_group = batch_macro_group[m];
      for (int c = 0; c < 4; c++) begin
        batch_macro_demand[4*m+c] = merge_contributes(
            batch_command.cim_reduce_split_mask, batch_command.cim_macro_oc_mask, m, c);
        if (batch_command.cim_macro_en_mask[m] && batch_macro_demand[4*m+c])
          batch_lane_mask[4*batch_macro_group[m]+c] = 1;
      end
    end
    for (int path = 0; path < 3; path++) path_lanes[path] = '0;
    for (int g = 0; g < 8; g++) begin
      batch_group_path[g] = batch_group_size[g] <= 2 ? 0 : batch_group_size[g] == 4 ? 1 : 2;
      path_lanes[batch_group_path[g]][4*g+:4] = batch_lane_mask[4*g+:4];
    end
  end
  always_comb begin : completion_paths
    for (int path = 0; path < 3; path++) begin
      completion_path_required[path] = |path_lanes[path];
      completion_path_last[path] = (|(result_done & path_lanes[path])) &&
          int'(tmp_path_meta[path].ctx) == int'(batch_contexts) - 1;
    end
  end
  always_comb begin : shared_metadata_views
    in_tag = expand_meta(pipe_meta[0]);
    macro_tag = expand_meta(pipe_meta[1]);
    red1_tag = expand_meta(pipe_meta[2]);
    red2_tag = expand_meta(pipe_meta[3]);
    for (int l = 0; l < 32; l++) begin
      tmp_tag[l] = expand_meta(tmp_path_meta[int'(batch_group_path[l/4])]);
      raw_context[l] = int'(raw_path_context[int'(batch_group_path[l/4])]);
    end
  end
  always_comb begin
    packet_cmd = batch_command;
    packet_cmd.cim_weight_raddr = packet_weight_address;
    command = packet_cmd;
    if (packet_cmd.cim_as_cnt > 1)
      command.cim_weight_raddr = a4_packet ? current_weight_address : context_address[context_idx];
    phases = batch_phase_count;
    contexts = command.cim_ws_cnt > 1 ? int'(command.cim_ws_cnt) : int'(command.cim_as_cnt);
    // A0 accompanies the first Context descriptor. A1..A3 follow on
    // consecutive edges without ACT handshake. Other AS descriptors may
    // arrive concurrently; they only provide their own weight addresses.
    need_plane = !(packet_active && packet_cmd.cim_as_cnt > 1 && command_count < int'(packet_cmd.cim_as_cnt));
    plane = act_buffer[1024*phase+:1024];
    issue_mask = batch_lane_mask;
    active = batch_macro_active;
    final_issue = phase == batch_last_phase && tile == batch_last_tile;
    // Consume only registered inputs: a Plane/address accepted on this edge
    // becomes eligible on the next edge. Later Planes and AS descriptors may
    // still be loading; keep the existing phase/Context order when stalled.
    issue = packet_active && act_slice_valid[phase] && !batch_input_done &&
            (packet_cmd.cim_as_cnt <= 1 || context_idx < command_count);
    ren = active & {8{issue}};
    for (int m = 0; m < 8; m++) station[m] = !hold_valid[m] || hold_addr[m] != command.cim_weight_raddr;
  end
  assign cmd_ready_o = !reset && !sram_cs_en && !batch_input_done &&
                       (!packet_active || (packet_cmd.cim_as_cnt > 1 && command_count < int'(packet_cmd.cim_as_cnt)));
  // A registered publication valid and shared Context select retained
  // tmp/Psum data directly; there is no separate raw payload register.
  // Storage-backed Psum -> combinational Requant -> INT8 output registers.
  // NBA semantics capture the PREVIOUS raw publication and configuration.
  // A new batch may load its configuration on that same capture edge.
  logic [CONTEXT_W - 1:0] requant_read_context;
  logic [3:0] requant_group_valid;
  always_comb begin : select_requant_context
    requant_read_context = raw_path_context[batch_group_path[batch_requant_group]];
    requant_group_valid = raw_valid[4*batch_requant_group+:4];
    selected_requant_cfg = batch_requant_cfg;
    if (batch_is_as && (|requant_group_valid) && int'(requant_read_context) < REQUANT_CONTEXT_DEPTH) begin
      for (int c = 0; c < 4; c++) begin
        // Preserve per-OC isolation while sharing the Context address.
        if (requant_group_valid[c]) begin
          selected_requant_cfg.requant_zp[32*c+:32] = requant_context_zp[requant_read_context][32*c+:32];
          if (batch_requant_cfg.requant_mode) begin
            selected_requant_cfg.requant_multiplier[32*c+:32] =
                requant_context_multiplier[requant_read_context][32*c+:32];
            selected_requant_cfg.requant_shift[10*c+:10] = requant_context_shift[requant_read_context][10*c+:10];
          end
        end
      end
      // Tensor entry zero is shared even when OC0 itself is masked.
      if (!batch_requant_cfg.requant_mode) begin
        selected_requant_cfg.requant_multiplier[31:0] = requant_context_multiplier[requant_read_context][31:0];
        selected_requant_cfg.requant_shift[9:0] = requant_context_shift[requant_read_context][9:0];
      end
    end
  end
  ClusterRequant u_requant (
    .cfg_i  (selected_requant_cfg),
    .group_sel_i(batch_requant_group),
    .psum_i (raw_data),
    .valid_i(ENABLE_REQUANT ? raw_valid : 32'b0),
    .data_o (requant_comb_data),
    .valid_o(requant_comb_valid)
  );
  // Valid stays on the root clock so the final pulse always clears.
  always_ff @(posedge clock or posedge reset)
    if (reset) requant_valid_o <= '0;
    else requant_valid_o <= requant_comb_valid;
  for (genvar l = 0; l < 32; l++) begin : g_output_lane
    wire quant_clock;
    MacroClockGate #(
      .ENABLE_GATING(USE_CLOCK_GATING)
    ) u_quant_icg (
      .clock(clock),
      .enable(!reset && requant_comb_valid[l]),
      .gated_clock(quant_clock)
    );
    assign raw_data[32 * l +: 32] = batch_uses_psum ?
        psum[raw_context[l]][l] : tmp_result[l];
    always_ff @(posedge quant_clock or posedge reset) begin
      if (reset) requant_data_o[8*l+:8] <= '0;
      else if (requant_comb_valid[l]) begin
`ifndef SYNTHESIS
        if (batch_command.cim_as_cnt > 1 &&
            (raw_context[l] >= REQUANT_CONTEXT_DEPTH || !requant_context_valid[raw_context[l]]))
          $fatal(1, "CLUSTER_REQUANT_CONFIG: missing AS context zp");
`endif
        requant_data_o[8*l+:8] <= requant_comb_data[8*l+:8];
      end
    end
  end
  for (genvar m = 0; m < 8; m++) begin : g_macro
    logic [511:0] idata;
    wire  [  3:0] result_mask;
    for (genvar c = 0; c < 4; c++) begin : g_result_demand
      // Input-boundary demand is registered inside Macro before its output edge.
      assign result_mask[c] = batch_macro_demand[4*m+c];
    end
    always_comb begin
      idata = '0;
      if (batch_act_digits != 0)
        for (int j = 0; j < 128; j++)
        if (j < batch_act_digits)
          idata[4*j+:4] = plane[4*(int'(command.cim_act_slot_sel[3*m+:3])*batch_act_digits+j)+:4];
    end
    SingleMacro #(
      .USE_CLOCK_GATING(USE_CLOCK_GATING)
    ) u_macro (
      .clock(clock),
      .reset(reset),
      .cim_ren(ren[m]),
      .cim_idata(idata),
      .cim_raddr(command.cim_weight_raddr),
      .cim_station(station[m]),
      .cim_oc_mask(command.cim_macro_oc_mask[4*m+:4]),
      .cim_result_mask(result_mask),
      .cim_precision(command.cim_precision),
      .cim_signed_en(command.cim_signed_en),
      .cim_phase(2'(phase)),
      .sram_wen(memory_wen[m]),
      .sram_waddr(sram_row_addr),
      .sram_wdata(sram_wrdata),
      .sram_wmask(sram_wmask),
      .sram_ren(regular_read && regular_macro_id == m),
      .sram_raddr(sram_row_addr),
      .sram_rdata(regular_read_data[1024*m+:1024]),
      .cim_odata(macro_data[72*m+:72]),
      .cim_odata_valid(macro_valid[m]),
      .cim_odata_oc_mask(macro_mask[4*m+:4]),
      .cim_odata_phase(macro_phase[2*m+:2])
    );
  end
  ClusterReduceTree #(
    .USE_CLOCK_GATING(USE_CLOCK_GATING)
  ) u_reduce (
    .clock(clock),
    .reset(reset),
    .early_valid_i(in_tag.valid),
    .early_split_i(in_tag.cmd.cim_reduce_split_mask),
    .early_en_i(in_tag.cmd.cim_macro_en_mask),
    .early_oc_i(in_tag.cmd.cim_macro_oc_mask),
    .valid_i(macro_tag.valid),
    .split_i(macro_tag.cmd.cim_reduce_split_mask),
    .en_i(macro_tag.cmd.cim_macro_en_mask),
    .oc_i(macro_tag.cmd.cim_macro_oc_mask),
    .macro_data_i(macro_data),
    .tap_valid_o(tap_valid),
    .tap_mask_o(tap_mask),
    .tap_data_o(tap_data)
  );
  always_comb begin : collect_tmp
    capture_valid = '0;
    for (int l = 0; l < 32; l++) begin
      capture_tag[l]  = '0;
      capture_data[l] = 0;
    end
    for (int path = 0; path < 3; path++)
    if (tap_valid[path])
      for (int l = 0; l < 32; l++)
      if (tap_mask[path][l]) begin
        capture_valid[l] = 1;
        capture_tag[l]   = tap_tag[path];
        capture_data[l]  = longint'($signed(tap_data[path][21*l+:21]));
      end
  end
  always_ff @(posedge clock or posedge reset) begin : advance_buffer_enables
    if (reset) begin
      tmp_input_cg_en <= '0;
      for (int d = 0; d < OUTPUT_BUFFER_DEPTH; d++) psum_cg_en[d] <= '0;
    end else begin
      tmp_input_cg_en <= (path_lanes[0] & {32{early_tmp_tag[0].valid}}) |
                         (path_lanes[1] & {32{early_tmp_tag[1].valid}}) |
                         (path_lanes[2] & {32{early_tmp_tag[2].valid}});
      for (int d = 0; d < OUTPUT_BUFFER_DEPTH; d++) psum_cg_en[d] <= '0;
      for (int l = 0; l < 32; l++)
      if (capture_valid[l]) begin
        if (batch_is_as) begin
          psum_cg_en[capture_tag[l].ctx][l] <= 1;
        end else if (capture_tag[l].cmd.cim_os_cnt > 1 && capture_tag[l].ph == batch_last_phase)
          psum_cg_en[capture_tag[l].ctx][l] <= 1;
      end
    end
  end
  for (genvar l = 0; l < 32; l++) begin : g_tmp_input
    MacroClockGate #(
      .ENABLE_GATING(USE_CLOCK_GATING)
    ) u_icg (
      .clock(clock),
      .enable(tmp_input_cg_en[l]),
      .gated_clock(tmp_input_clock[l])
    );
    always_ff @(posedge tmp_input_clock[l] or posedge reset)
      if (reset) tmp_result[l] <= 0;
      else if (tmp_input_cg_en[l]) begin
`ifndef SYNTHESIS
        // Every intermediate store must fit signed32. A final-value-only check
        // cannot see a history that already wrapped at this write.
        if (tmp_store_data[l] < -64'sd2147483648 || tmp_store_data[l] > 64'sd2147483647)
          $fatal(1, "CLUSTER_ARITH: tmp signed32 overflow");
`endif
        tmp_result[l] <= tmp_store_data[l];
      end
  end
  for (genvar path = 0; path < 3; path++) begin : g_shared_meta
    wire tmp_meta_clock, raw_meta_clock;
    wire tmp_meta_req = |(tmp_input_cg_en & path_lanes[path]);
    wire raw_meta_req = |(result_done & path_lanes[path]);
    MacroClockGate #(.ENABLE_GATING(USE_CLOCK_GATING)) u_tmp_meta_icg (
      .clock(clock), .enable(!reset && tmp_meta_req), .gated_clock(tmp_meta_clock)
    );
    MacroClockGate #(.ENABLE_GATING(USE_CLOCK_GATING)) u_raw_meta_icg (
      .clock(clock), .enable(!reset && raw_meta_req), .gated_clock(raw_meta_clock)
    );
    always_ff @(posedge tmp_meta_clock or posedge reset)
      if (reset) tmp_path_meta[path] <= '0;
      else if (tmp_meta_req) tmp_path_meta[path] <= compact_tag(tap_tag[path]);
    always_ff @(posedge raw_meta_clock or posedge reset)
      if (reset) raw_path_context[path] <= '0;
      else if (raw_meta_req) raw_path_context[path] <= tmp_path_meta[path].ctx;
  end
  for (genvar d = 0; d < OUTPUT_BUFFER_DEPTH; d++) begin : g_psum_depth
    for (genvar l = 0; l < 32; l++) begin : g_lane
      MacroClockGate #(
        .ENABLE_GATING(USE_CLOCK_GATING)
      ) u_icg (
        .clock(clock),
        .enable(psum_depth_open[d] && psum_cg_en[d][l]),
        .gated_clock(psum_clock[d][l])
      );
      always_ff @(posedge psum_clock[d][l] or posedge reset)
        if (reset) psum[d][l] <= 0;
        else if (psum_depth_open[d] && psum_cg_en[d][l]) begin
`ifndef SYNTHESIS
          if (arithmetic_result[l] < -64'sd2147483648 || arithmetic_result[l] > 64'sd2147483647)
            $fatal(1, "CLUSTER_ARITH: Psum signed32 overflow");
`endif
          psum[d][l] <= arithmetic_result[l];
        end
    end
  end
  // One shared fusion/acc adder per OC, reused by all Contexts.
  // Legal in-order scheduling makes fusion_enable and acc_enable exclusive.
  // WS/single fuses adjacent slices in tmp; commits Psum only for OS>1.
  // AS traverses Contexts within each slice and stores history per Context.
  // Every multi-Context AS writes Psum, including A4 OS1 final results.
  // Both operands of an unused adder are isolated to zero. ASIC STA required.
  always_comb begin : arithmetic
    for (int l = 0; l < 32; l++) begin
      fusion_enable[l] = 0;
      acc_enable[l] = 0;
      psum_write[l] = 0;
      fusion_a[l] = 0;
      fusion_b[l] = 0;
      acc_a[l] = 0;
      acc_b[l] = 0;
      if (capture_valid[l] && !batch_is_as && capture_tag[l].ph > 0) begin
        fusion_enable[l] = 1;
        fusion_a[l] = tmp_result[l];
        fusion_b[l] = capture_data[l] <<< (4 * capture_tag[l].ph);
      end
      if (tmp_valid[l] && batch_is_as && tmp_tag[l].ph > 0) begin
        fusion_enable[l] = 1;
        fusion_a[l] = psum[tmp_tag[l].ctx][l];
        fusion_b[l] = tmp_result[l] <<< (4 * tmp_tag[l].ph);
      end
      if (tmp_valid[l]) begin
        if (batch_is_as) begin
          psum_write[l] = 1;
          acc_enable[l] = tmp_tag[l].ph == 0 && tmp_tag[l].kt > 0;
        end else begin
          psum_write[l] = tmp_tag[l].cmd.cim_os_cnt > 1 &&
            tmp_tag[l].ph == batch_last_phase;
          acc_enable[l] = psum_write[l] && tmp_tag[l].kt > 0;
        end
        if (acc_enable[l]) begin
          acc_a[l] = psum[tmp_tag[l].ctx][l];
          acc_b[l] = tmp_result[l];
        end
      end
      shared_add_a[l] = acc_enable[l] ? acc_a[l] : fusion_a[l];
      shared_add_b[l] = acc_enable[l] ? acc_b[l] : fusion_b[l];
      shared_add_result[l] = shared_add_a[l] + shared_add_b[l];
      fusion_result[l] = fusion_enable[l] ? shared_add_result[l] : 0;
      acc_result[l] = acc_enable[l] ? shared_add_result[l] : 0;
      tmp_store_data[l] = (capture_valid[l] && !batch_is_as && capture_tag[l].ph > 0) ?
          fusion_result[l] : capture_data[l];
      arithmetic_result[l] = acc_enable[l] ? acc_result[l] :
        (tmp_valid[l] && batch_is_as && tmp_tag[l].ph > 0) ?
        fusion_result[l] : tmp_result[l];
      result_done[l] = tmp_valid[l] && tmp_tag[l].ph == batch_last_phase &&
        tmp_tag[l].kt == batch_last_tile;
    end
  end
  always_ff @(posedge clock or posedge reset) begin : pipeline
    bit all_done;
    logic [31:0] captured;
    int zp_ctx;
    if (reset) begin
      act_buffer <= '0;
      packet_weight_address <= '0;
      packet_active <= 0;
      act_loading <= 0;
      act_complete <= 0;
      act_slice_valid <= '0;
      external_phase <= 0;
      command_count <= 0;
      phase <= 0;
      context_idx <= 0;
      tile <= 0;
      hold_valid <= '0;
      raw_valid <= '0;
      tmp_valid <= '0;
      batch_active <= 0;
      batch_input_done <= 0;
      batch_contexts <= 0;
      requant_context_valid <= '0;
      batch_command <= '0;
      psum_depth_open <= '0;
      for (int path = 0; path < 4; path++) pipe_meta[path] <= '0;
      completion_path_done <= '0;
    end else begin
      if (cmd_accept) begin
`ifndef SYNTHESIS
        if (cmd_i.cim_os_cnt == 0 || cmd_i.cim_ws_cnt == 0 || cmd_i.cim_as_cnt == 0)
          $fatal(1, "CLUSTER_COUNT_RANGE: counts must be 1..255");
        // Context tags/AS addresses and Psum entries are separate resources.
        // AS always reserves fixed Context slots; WS OS1 may exceed Psum depth.
        if (cmd_i.cim_ws_cnt > MAX_CONTEXTS || cmd_i.cim_as_cnt > MAX_CONTEXTS)
          $fatal(1, "CLUSTER_CONTEXT_CAPACITY: context metadata exceeded");
        if (cmd_i.cim_as_cnt > OUTPUT_BUFFER_DEPTH)
          $fatal(1, "CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth");
        if (deep_command && cmd_i.cim_as_cnt > WGT_RADDR_BUFFER_DEPTH)
          $fatal(1, "CLUSTER_CONTEXT_CAPACITY: weight address depth exceeded");
        if (cmd_i.cim_os_cnt > 1 && (cmd_i.cim_ws_cnt > OUTPUT_BUFFER_DEPTH || cmd_i.cim_as_cnt > OUTPUT_BUFFER_DEPTH))
          $fatal(1, "CLUSTER_CONTEXT_CAPACITY: Psum depth exceeded");
        if (ENABLE_REQUANT && cmd_i.cim_as_cnt > 1 && cmd_i.cim_as_cnt > REQUANT_CONTEXT_DEPTH)
          $fatal(1, "CLUSTER_REQUANT_CONFIG: AS context zp depth exceeded");
`endif
        if (ENABLE_REQUANT && cmd_i.cim_as_cnt > 1) begin
          zp_ctx = int'(write_context_slot);
`ifndef SYNTHESIS
          if(batch_active && (requant_cfg_i.requant_mode!==batch_requant_cfg.requant_mode ||
                             requant_cfg_i.conv_mode!==batch_requant_cfg.conv_mode))
            $fatal(1, "CLUSTER_REQUANT_CONFIG: AS context mode changed");
          if ($isunknown({requant_cfg_i.requant_multiplier, requant_cfg_i.requant_shift}))
            $fatal(1, "CLUSTER_REQUANT_CONFIG: unknown AS context scale");
          if ($isunknown(requant_cfg_i.requant_zp)) $fatal(1, "CLUSTER_REQUANT_CONFIG: unknown AS context zp");
`endif
          if (write_requant_params) begin
            if (!batch_active) requant_context_valid <= '0;
            requant_context_valid[zp_ctx] <= 1;
          end else begin
`ifndef SYNTHESIS
            if (!requant_context_valid[zp_ctx] || requant_cfg_i.requant_zp !== requant_context_zp[zp_ctx])
              $fatal(1, "CLUSTER_REQUANT_CONFIG: AS context zp changed across K Tiles");
            else if (requant_cfg_i.requant_mode ?
                    (requant_cfg_i.requant_multiplier !== requant_context_multiplier[zp_ctx] ||
                     requant_cfg_i.requant_shift !== requant_context_shift[zp_ctx]) :
                    (requant_cfg_i.requant_multiplier[31:0] !== requant_context_multiplier[zp_ctx][31:0] ||
                     requant_cfg_i.requant_shift[9:0] !== requant_context_shift[zp_ctx][9:0]))
              $fatal(1, "CLUSTER_REQUANT_CONFIG: AS context scale changed across K Tiles");
`endif
          end
        end
        if (!packet_active) begin
          packet_weight_address <= cmd_i.cim_weight_raddr;
          packet_active <= 1;
          command_count <= 1;
          act_buffer[0+:1024] <= act_data_i;
          act_slice_valid <= 4'b0001;
          external_phase <= 1;
          act_loading <= abits(int'(cmd_i.cim_precision)) > 4;
          act_complete <= abits(int'(cmd_i.cim_precision)) == 4;
        end else begin
`ifndef SYNTHESIS
          if (deep_command && command_count >= WGT_RADDR_BUFFER_DEPTH) $fatal(1, "AS address capacity exceeded");
`endif
          command_count <= command_count + 1;
        end
        if (!batch_active) begin
`ifndef SYNTHESIS
          if (ENABLE_REQUANT && $isunknown(requant_cfg_i)) $fatal(1, "CLUSTER_REQUANT_CONFIG: unknown configuration");
          if (ENABLE_REQUANT && requant_cfg_i.requant_mode && !requant_cfg_i.conv_mode)
            $fatal(1, "CLUSTER_REQUANT_CONFIG: per-channel scale requires conv_mode");
          if (ENABLE_REQUANT && !conv_group_legal(cmd_i))
            $fatal(1, "CLUSTER_REQUANT_CONFIG: Requant requires one aligned reduction group");
`endif

          batch_active   <= 1;
          batch_command  <= cmd_i;
          batch_contexts <= CONTEXT_COUNT_W'(cmd_i.cim_ws_cnt > 1 ? cmd_i.cim_ws_cnt : cmd_i.cim_as_cnt);
          completion_path_done <= '0;
          for (int d = 0; d < OUTPUT_BUFFER_DEPTH; d++)
          psum_depth_open[d] <= (cmd_i.cim_os_cnt > 1 || cmd_i.cim_as_cnt > 1) &&
              d < int'(cmd_i.cim_ws_cnt > 1 ? cmd_i.cim_ws_cnt : cmd_i.cim_as_cnt);
        end else begin
`ifndef SYNTHESIS
          if (cmd_i.cim_os_cnt != batch_command.cim_os_cnt ||
            cmd_i.cim_ws_cnt != batch_command.cim_ws_cnt || cmd_i.cim_as_cnt != batch_command.cim_as_cnt ||
            cmd_i.cim_precision != batch_command.cim_precision ||
            cmd_i.cim_signed_en != batch_command.cim_signed_en ||
            cmd_i.cim_reduce_split_mask != batch_command.cim_reduce_split_mask ||
            cmd_i.cim_macro_en_mask != batch_command.cim_macro_en_mask ||
            cmd_i.cim_macro_oc_mask != batch_command.cim_macro_oc_mask ||
            cmd_i.cim_act_slot_sel != batch_command.cim_act_slot_sel)
            $fatal(1, "Batch descriptor fields changed before completion");
`endif
        end
      end
      if (act_loading) begin
        act_buffer[1024*external_phase+:1024] <= act_data_i;
        act_slice_valid[external_phase] <= 1;
        if (external_phase == batch_last_phase) begin
          act_loading  <= 0;
          act_complete <= 1;
        end else external_phase <= external_phase + 1;
      end
      for (int m = 0; m < 8; m++) begin
        if (memory_wen[m]) hold_valid[m] <= 0;
        else if (regular_read && regular_macro_id == m) begin
          hold_valid[m] <= 1;
          hold_addr[m] <= sram_row_addr;
        end else if (ren[m] && station[m]) begin
          hold_valid[m] <= 1;
          hold_addr[m] <= command.cim_weight_raddr;
        end
      end
      // Empty effective masks have no downstream transaction. Suppressing
      // their tags prevents a draining empty batch from borrowing the next
      // batch's shared mask after ready reopens. Input scheduling is unchanged.
      pipe_meta[0].valid <= issue && (|issue_mask);
      if (issue) begin
`ifndef SYNTHESIS
        if (!act_slice_valid[phase]) $fatal(1, "Internal issue before ACT slice loaded");
`endif
        if (phase == phases - 1 && (command.cim_as_cnt <= 1 || context_idx == contexts - 1)) begin
          packet_active <= 0;
          act_complete <= 0;
          command_count <= 0;
          act_slice_valid <= '0;
        end
`ifndef SYNTHESIS
        if (command.cim_precision > 6 || !canonical(
            command.cim_reduce_split_mask
          ) || command.cim_os_cnt < 1 || command.cim_ws_cnt < 1 || command.cim_as_cnt < 1 ||
            (command.cim_ws_cnt > 1 && command.cim_as_cnt > 1) || contexts > MAX_CONTEXTS ||
            (command.cim_as_cnt > 1 && abits(
            int'(command.cim_precision)
          ) > 4 && command.cim_as_cnt > WGT_RADDR_BUFFER_DEPTH) ||
            (command.cim_os_cnt > 1 && contexts > OUTPUT_BUFFER_DEPTH))
          $fatal(1, "Invalid descriptor / context capacity");
        for (int m = 0; m < 8; m++)
        if (command.cim_macro_en_mask[m]) begin
          if (int'(command.cim_act_slot_sel[3*m+:3]) >= wbits(int'(command.cim_precision)))
            $fatal(1, "ACT slot outside plane");
          for (int n = 0; n < m; n++)
          if (command.cim_macro_en_mask[n] && group_of(
              command.cim_reduce_split_mask, n
            ) == group_of(
              command.cim_reduce_split_mask, m
            ) && command.cim_act_slot_sel[3*m+:3] == command.cim_act_slot_sel[3*n+:3])
            $fatal(1, "Repeated K slot in one reduction group");
        end
`endif
        pipe_meta[0].ph <= 2'(phase);
        pipe_meta[0].ctx <= CONTEXT_W'(context_idx);
        pipe_meta[0].kt <= 8'(tile);
        if (final_issue && context_idx == contexts - 1) batch_input_done <= 1;
        if (command.cim_as_cnt > 1) begin
          if (context_idx == contexts - 1) begin
            context_idx <= 0;
            if (phase == phases - 1) begin
              phase <= 0;
              tile  <= final_issue ? 0 : tile + 1;
            end else phase <= phase + 1;
          end else context_idx <= context_idx + 1;
        end else begin
          if (phase == phases - 1) begin
            phase <= 0;
            if (context_idx == contexts - 1) begin
              context_idx <= 0;
              tile <= final_issue ? 0 : tile + 1;
            end else context_idx <= context_idx + 1;
          end else phase <= phase + 1;
        end
      end
      pipe_meta[1] <= pipe_meta[0];
      pipe_meta[2] <= pipe_meta[1];
      if (macro_tag.valid) begin
`ifndef SYNTHESIS
        for (int m = 0; m < 8; m++) begin
          if (macro_valid[m] !== (macro_tag.cmd.cim_macro_en_mask[m] && (|macro_tag.cmd.cim_macro_oc_mask[4*m+:4])))
            $fatal(1, "Macro valid not aligned with 1T result");
          if(macro_valid[m] && (macro_phase[2 * m +: 2]!==2'(macro_tag.ph) ||
              macro_mask[4 * m +: 4]!==macro_tag.cmd.cim_macro_oc_mask[4 * m +: 4]))
            $fatal(1, "Macro metadata mismatch");
        end
`endif
      end
      pipe_meta[3] <= pipe_meta[2];
      raw_valid <= '0;
      // Consume the PREVIOUS tmp DFF contents. NBA state writes preserve
      // consecutive-phase feedback and prevent zero-time procedural cascades.
      for (int l = 0; l < 32; l++)
      if (tmp_valid[l] && result_done[l]) begin
`ifndef SYNTHESIS
          // This checks the current widened operation only. Earlier signed32
          // tmp/Psum truncation may already have wrapped an oversized history
          // back into range; this is not end-to-end overflow detection.
          if(arithmetic_result[l] < -64'sd2147483648 || arithmetic_result[l]>64'sd2147483647 ||
             (!tmp_tag[l].cmd.cim_signed_en && arithmetic_result[l]<0))
            $fatal(1, "Psum signed32 overflow (policy TBD)");
`endif
          // Publish this lane for one cycle. The observation reads existing
          // tmp/Psum storage and has no holding contract while valid is low.
          raw_valid[l] <= 1;
        end
      // Independent tree taps capture into per-channel tmp DFFs. There is
      // no additional root-only DFF or full-depth result alignment pipeline.
      captured = '0;
      tmp_valid <= '0;
      for (int path = 0; path < 3; path++)
      if (tap_valid[path]) begin
`ifndef SYNTHESIS
        if (!tap_tag[path].valid || ((tap_mask[path] & ~tap_tag[path].mask) != 0))
          $fatal(1, "Terminal tap metadata mismatch path=%0d", path);
`endif
        for (int l = 0; l < 32; l++)
        if (tap_mask[path][l]) begin
`ifndef SYNTHESIS
          if (captured[l]) $fatal(1, "Concurrent tree taps target same channel");
`endif
          captured[l] = 1;
          tmp_valid[l] <= 1;
        end
      end
      // Include this edge's last-Context publications, preserving the
      // existing batch-close cycle. Empty paths require no completion event.
      completion_path_done <= completion_path_done | completion_path_last;
      if (cmd_accept && !batch_active) completion_path_done <= '0;
      all_done = batch_input_done &&
          (((completion_path_done | completion_path_last) & completion_path_required) == completion_path_required);
      if (batch_active && all_done) begin
        batch_active <= 0;
        batch_input_done <= 0;
        psum_depth_open <= '0;
      end
    end
  end
endmodule
