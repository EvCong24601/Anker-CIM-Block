`timescale 1ns / 1ps
// Three-channel Cluster: no pending command or output payload register.
//
// File map. Search for "=====" to jump between the sections below:
//    1. Parameters and ports
//    2. Batch decode nets and pipeline declarations
//    3. Weight-address storage clock domains
//    4. Regular SRAM passthrough and protocol checks
//    5. Pipeline tags and tmp/Psum storage declarations
//    6. Operation step counters (simulation only)
//    7. Completion paths, shared views, batch decode
//    8. Issue scheduling
//    9. Raw output lanes, Macro array, reduction tree
//   10. Accumulation: buffer enables, tmp/Psum arrays, arithmetic
//   11. Main pipeline state machine
//
// ===== 1. Parameters and ports =====
module cluster_top #(
  // Unified integration depth. Individual overrides support capacity tests.
  parameter int OUTPUT_PSUM_DEPTH = 16,
  parameter int OUTPUT_BUFFER_DEPTH = OUTPUT_PSUM_DEPTH,
  parameter int WGT_RADDR_BUFFER_DEPTH = OUTPUT_BUFFER_DEPTH,
  // Context tag/completion capacity, independent of the Psum depth. Bounds the
  // WS/AS context count; for OS1 WS it is the only limit, so up to MAX_CONTEXTS
  // contexts (e.g. 64) are legal even beyond OUTPUT_BUFFER_DEPTH.
  parameter int MAX_CONTEXTS = 64,
  parameter bit USE_CLOCK_GATING = 1
) (
  input logic clock,
  input logic reset_n,
  input cluster_pkg::cluster_ctrl_t cmd_i,
  input logic cmd_valid_i,
  output wire cmd_ready_o,
  input logic [7:0] weight_raddr_i,
  input logic weight_valid_i,
  output wire weight_ready_o,
  input logic [1023:0] act_data_i,
  input logic act_valid_i,
  output wire act_ready_o,
  input logic sram_cs_en,
  input logic sram_wr_en,
  input logic sram_macro_group,
  input logic [1:0] sram_bank_sel,
  input logic [7:0] sram_row_addr,
  input logic [3:0] sram_wmask,
  input logic [1023:0] sram_wrdata,
  input logic [7:0] timing_config_i,
  input logic waen_i,
  input logic raen_i,
  output wire [1023:0] sram_rd_data,
  output logic sram_rd_valid,
  // Lane l carries signed32 raw_psum[32*l+:32], qualified by psum_valid[l].
  // No output backpressure. Invalid lane payload is unspecified.
  output wire [1023:0] raw_psum,
  output wire [31:0] psum_valid,
  // Pulse start for one cycle while Cluster is idle. Macro ID and repair map
  // are sampled every clock; the selected Macro updates its repair registers
  // independently of start. Byte 4*bank+sbk selects one 128-column subbank,
  // low SRAM first. Other Macros retain their maps until selected or reset.
  // Read the registered result at done && !busy; reload weights after MBIST.
  input  logic [2:0]  mbist_macro_id_i,
  input  logic [63:0] mbist_test_red_sbk_i,
  input  logic        mbist_test_memory_start_i,
  output logic [63:0] mbist_test_error_sbk_o,
  output logic        mbist_test_done_o,
  output logic        mbist_test_busy_o,
  output logic        mbist_test_memory_valid_o,
  output logic        mbist_out_of_repair_o
);
  import cluster_pkg::*;
  // Sample once at the Cluster boundary, then broadcast to all SRAM wrappers.
  logic [7:0] timing_config_q;
  logic waen_q, raen_q;
  always_ff @(posedge clock or negedge reset_n) begin
    if (!reset_n) begin
      timing_config_q <= '0;
      waen_q <= 1'b0;
      raen_q <= 1'b0;
    end else begin
      timing_config_q <= timing_config_i;
      waen_q <= waen_i;
      raen_q <= raen_i;
    end
  end
  `include "cluster_func.sv"
`ifndef SYNTHESIS
  `include "cluster_check_func.sv"
`endif
  // ===== 2. Batch decode nets and pipeline declarations =====
  cluster_ctrl_t command;
  // Batch-invariant combinational decode; no additional configuration DFFs.
  logic [31:0] batch_lane_mask, batch_macro_demand;
  logic [2:0] batch_macro_group[0:7];
  logic [1:0] batch_group_path[0:7];
  logic [3:0] batch_group_size[0:7];
  logic [7:0] batch_macro_active;
  logic batch_is_as, batch_uses_psum;
  int batch_activation_bits, batch_weight_bits, batch_phase_count;
  int batch_last_phase, batch_last_tile, batch_act_digits;
  wire [4095:0] act_buffer;  // four 1024-bit bit-slice planes, A0..A3
  logic [1023:0] plane;
  localparam int CONTEXT_W = MAX_CONTEXTS > 1 ? $clog2(MAX_CONTEXTS) : 1;
  localparam int CONTEXT_COUNT_W = MAX_CONTEXTS > 1 ? $clog2(MAX_CONTEXTS + 1) : 1;
  localparam int REUSE_COUNT_W = CONTEXT_COUNT_W < 9 ? CONTEXT_COUNT_W : 9;
  // One active configuration, no pending command. Operands belong to the
  // accepted input job, independently of older jobs still draining.
  logic [7:0] packet_weight_address;  // Shared by WS, single Context and single-phase AS.
  logic [7:0] context_address[0:WGT_RADDR_BUFFER_DEPTH - 1];
  logic packet_active, weight_available;
  logic [3:0] act_slice_valid;
  logic [1:0] external_phase;
  logic [CONTEXT_COUNT_W - 1:0] command_count;
  // Nested receive counters avoid multiplying run-time descriptor counts.
  logic [8:0] act_tiles_left, weight_tiles_left;
  logic [REUSE_COUNT_W - 1:0] reuse_left;
  wire cmd_accept, act_accept, weight_accept;
  logic [1:0] phase;
  logic [CONTEXT_W - 1:0] context_idx;
  logic [8:0] tile;
  int phases, contexts;
  logic issue, final_issue;
  logic [31:0] issue_mask;
  logic [7:0] active, ren, station, hold_valid;
  logic [7:0] hold_addr[0:7];
  wire [575:0] macro_data;
  wire [7:0] macro_valid;
  wire [31:0] macro_mask;
  wire [15:0] macro_phase;
  logic batch_active;
  wire deep_batch, a4_packet, deep_weight_active;
  wire [31:0] write_context_slot;
  wire tile_end, job_end, release_plane, release_weight;
  wire upstream_busy, drain_safe, input_slot_free;
  wire [7:0] issue_weight_address;
  assign cmd_accept = cmd_valid_i && cmd_ready_o;
  assign act_accept = act_valid_i && act_ready_o;
  assign weight_accept = weight_valid_i && weight_ready_o;
  assign deep_batch = batch_is_as && batch_activation_bits > 4;
  assign a4_packet = batch_is_as && batch_activation_bits == 4;
  // A lane forwarding the final missing old beat consumes it directly. On
  // turnover only the *other* beats may update the new job's input state.
  wire forward_act, forward_weight;
  wire store_act = act_accept && !(cmd_accept && forward_act);
  wire act_buffer_we = store_act && !(forward_act && release_plane);
  wire store_weight = weight_accept && !(cmd_accept && forward_weight);
  wire incoming_a4 = abits(int'(cmd_i.cim_precision)) == 4;
  wire [8:0] receive_ws_count = cmd_accept ? cmd_i.cim_ws_cnt : batch_command.cim_ws_cnt;
  wire [8:0] receive_as_count = cmd_accept ? cmd_i.cim_as_cnt : batch_command.cim_as_cnt;
  wire receive_deep_as = receive_as_count > 1 && (cmd_accept ? !incoming_a4 : batch_activation_bits > 4);
  wire receive_frame_end = cmd_accept ? incoming_a4 : external_phase == batch_last_phase;
  // Only one of WS/AS can exceed one. Its stream owns the intra-tile counter.
  wire [REUSE_COUNT_W - 1:0] reuse_count = REUSE_COUNT_W'(receive_ws_count > 1 ? receive_ws_count : receive_as_count);
  wire [REUSE_COUNT_W - 1:0] receive_left = cmd_accept ? reuse_count : reuse_left;
  wire consume_reuse = (receive_ws_count > 1 && store_act && receive_frame_end) ||
                       (receive_as_count > 1 && store_weight);
  assign deep_weight_active = store_weight && receive_deep_as;
  assign write_context_slot = (cmd_accept || tile_end) ? 0 : 32'(command_count);
  wire [3:0] act_plane_clock;
  for (genvar p = 0; p < 4; p++) begin : g_act_plane
    wire plane_we = act_buffer_we && external_phase == 2'(p);
    logic [1023:0] plane_q;
    MacroClockGate #(
      .ENABLE_GATING(USE_CLOCK_GATING)
    ) u_icg (
      .clock(clock),
      .enable(plane_we),
      .gated_clock(act_plane_clock[p])
    );
    // With the ICG bypassed the data enable still holds an unwritten plane.
    always_ff @(posedge act_plane_clock[p] or negedge reset_n)
      if (!reset_n) plane_q <= '0;
      else if (USE_CLOCK_GATING || plane_we) plane_q <= act_data_i;
    assign act_buffer[1024*p+:1024] = plane_q;
  end

  wire deep_weight_clock;
  MacroClockGate #(.ENABLE_GATING(USE_CLOCK_GATING)) u_deep_table_gate (
    .clock(clock), .enable(deep_weight_active), .gated_clock(deep_weight_clock)
  );
  always_ff @(posedge deep_weight_clock or negedge reset_n) begin
    if (!reset_n) for (int d = 0; d < WGT_RADDR_BUFFER_DEPTH; d++) context_address[d] <= '0;
    else if (deep_weight_active && write_context_slot < WGT_RADDR_BUFFER_DEPTH)
      context_address[write_context_slot] <= weight_raddr_i;
  end
  // ===== 4. Regular SRAM passthrough and protocol checks =====
  wire [2:0] regular_macro_id;
  wire regular_access;
  wire regular_read;
  wire regular_write;
  wire [7:0] memory_wen;
  wire [8191:0] regular_read_data;
  // MBIST is issued with the functional interface idle. Capture the entire
  // request on a single start pulse. Ignore further pulses while busy.
  typedef enum logic [2:0] {BIST_IDLE, BIST_DISPATCH, BIST_WAIT_BUSY, BIST_RUN,
                            BIST_REPORT} bist_state_t;
  bist_state_t bist_state;
  logic [2:0] bist_id;
  // The external MBIST pins only feed input flops. A request launched while
  // busy or alongside an accepted command is discarded, not queued.
  logic mbist_start_q, mbist_eligible_q;
  logic [2:0] mbist_id_q;
  logic [63:0] mbist_config_q;
  always_ff @(posedge clock or negedge reset_n) begin
    if (!reset_n) begin
      mbist_start_q <= 0;
      mbist_eligible_q <= 0;
      mbist_id_q <= '0;
      mbist_config_q <= '0;
    end else begin
      mbist_start_q <= mbist_test_memory_start_i;
      mbist_id_q <= mbist_macro_id_i;
      mbist_config_q <= mbist_test_red_sbk_i;
      mbist_eligible_q <= bist_state == BIST_IDLE && !batch_active &&
                          !packet_active && !sram_cs_en && !cmd_accept;
    end
  end
  wire [7:0] bist_done, bist_busy, bist_valid, bist_unrepairable;
  wire [63:0] bist_errors [0:7];
  // Eight 8-bit BL error registers per Macro. Sample the wrapper outputs at
  // completion; preserve every Macro's report until its own next test/reset.
  logic [7:0] bist_error_reg [0:7][0:7];
  wire bist_capture = bist_state == BIST_RUN && bist_done[bist_id] && !bist_busy[bist_id];
  wire [63:0] selected_bist_errors;
  for (genvar m = 0; m < 8; m++) begin : g_bist_error_register
    for (genvar byte_idx = 0; byte_idx < 8; byte_idx++) begin : g_byte
      always_ff @(posedge clock or negedge reset_n)
        if (!reset_n) bist_error_reg[m][byte_idx] <= '0;
        else if (bist_capture && bist_id == 3'(m))
          bist_error_reg[m][byte_idx] <= bist_errors[m][8*byte_idx+:8];
    end
  end
  for (genvar byte_idx = 0; byte_idx < 8; byte_idx++) begin : g_selected_bist_error
    assign selected_bist_errors[8*byte_idx+:8] = bist_error_reg[bist_id][byte_idx];
  end
  wire [7:0] bist_select = bist_state == BIST_DISPATCH ? (8'b1 << bist_id) : 8'b0;
  wire bist_accept = mbist_start_q && mbist_eligible_q && !mbist_test_busy_o &&
                     !batch_active && !packet_active && !sram_cs_en;
  assign mbist_test_busy_o = bist_state != BIST_IDLE;
  always_ff @(posedge clock or negedge reset_n) begin
    if (!reset_n) begin
      bist_state <= BIST_IDLE;
      bist_id <= '0;
      mbist_test_done_o <= 0;
      mbist_test_memory_valid_o <= 0;
      mbist_out_of_repair_o <= 0;
      mbist_test_error_sbk_o <= '0;
    end else case (bist_state)
      BIST_IDLE: if (bist_accept) begin
        bist_id <= mbist_id_q;
        mbist_test_done_o <= 0;
        mbist_test_memory_valid_o <= 0;
        mbist_out_of_repair_o <= 0;
        mbist_test_error_sbk_o <= '0;
        bist_state <= BIST_DISPATCH;
      end
      BIST_DISPATCH: bist_state <= BIST_WAIT_BUSY;
      // A previous run's done can still be high while the request travels
      // through the local register. Observe the new busy before taking done.
      BIST_WAIT_BUSY: if (bist_busy[bist_id]) bist_state <= BIST_RUN;
      BIST_RUN: if (bist_capture) begin
        mbist_test_memory_valid_o <= bist_valid[bist_id];
        mbist_out_of_repair_o <= bist_unrepairable[bist_id];
        bist_state <= BIST_REPORT;
      end
      // The shared output is driven only by the top-level sampled byte bank.
      BIST_REPORT: begin
        mbist_test_error_sbk_o <= selected_bist_errors;
        mbist_test_done_o <= 1;
        bist_state <= BIST_IDLE;
      end
    endcase
  end

  assign regular_macro_id = {sram_macro_group, sram_bank_sel};
  assign regular_access = sram_cs_en && !mbist_test_busy_o;
  assign regular_read = regular_access && !sram_wr_en;
  assign regular_write = regular_access && sram_wr_en && !(&sram_wmask);
  assign memory_wen = regular_write ? (8'd1 << regular_macro_id) : 8'd0;
  // Register the response tag at request acceptance. Selected SRAM data
  // settles after the v2 model's 1.5 ns CK delay in this response cycle.
  // A synchronous consumer samples valid and data on the next rising edge.
  logic [2:0] sram_response_macro;
  always_ff @(posedge clock or negedge reset_n) begin
    if (!reset_n) begin
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
    if (reset_n) begin
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
  // ===== 5. Pipeline tags and tmp/Psum storage declarations =====
  typedef struct packed {
    logic valid;
    pipeline_cfg_t cfg;
    logic [1:0] ph;
    logic [CONTEXT_W - 1:0] ctx;
    logic first_tile, last_tile;
`ifndef SYNTHESIS
    // Checker provenance only; input-only modes need no downstream HW state.
    cluster_ctrl_t check_cmd;
`endif
  } txn_meta_t;
  // Expanded views retain checker access; only compact metadata is registered.
  typedef struct packed {
    logic valid;
    pipeline_cfg_t cfg;
    cluster_ctrl_t cmd;
    int ph, ctx;
    logic first_tile, last_tile;
    logic [31:0] mask;
  } tag_t;
  txn_meta_t pipe_meta[0:4];
  txn_meta_t tmp_path_meta[0:2];
  logic [CONTEXT_W - 1:0] raw_path_context[0:2];
  pipeline_cfg_t raw_path_cfg[0:2];
  logic [31:0] tmp_path_lanes[0:2], raw_path_lanes[0:2];
  logic [31:0] path_lanes[0:2];
  tag_t early_tag, macro_tag, red1_tag, red2_tag;
  tag_t tap_tag[0:2];
  wire [2:0] tap_valid;
  wire [31:0] tap_mask[0:2];
  wire [671:0] tap_data[0:2];
  always_comb begin
    tap_tag[0] = macro_tag;
    tap_tag[1] = red1_tag;
    tap_tag[2] = red2_tag;
  end
  // Each tree endpoint writes one per-output-channel tmp result register.
  // The tagged arithmetic stage consumes it on the NEXT edge (II=1).
  // OUTPUT_BUFFER_DEPTH is the per-OC Context state capacity, not a FIFO.
  wire [31:0] tmp_valid;
  tag_t tmp_tag[0:31];  // Combinational views only; no per-lane tag storage.
  logic signed [31:0] tmp_result[0:31];  // one 32-bit data DFF per OC
  // One tmp data register per OC; Psum stores Context history.
  // NUMERIC LIMIT: tmp/Psum are signed32 storage. Intermediate writes truncate
  // before the final-result overflow check; there is no intermediate overflow
  // flag or saturation. Every stored intermediate must fit signed32, not only
  // the final mathematical sum.
  logic signed [31:0] psum[0:OUTPUT_BUFFER_DEPTH - 1][0:31];
  wire [OUTPUT_BUFFER_DEPTH - 1:0] psum_depth_open;
  cluster_ctrl_t batch_command;
  // All lanes on a reduction path have the same capture and publication edges.
  logic [2:0] tmp_path_valid, psum_path_valid;
  wire [31:0] tmp_input_cg_en;
  wire [31:0] psum_cg_en[0:OUTPUT_BUFFER_DEPTH - 1];
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
  // ===== 6. Operation step counters (simulation only) =====
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
      if (capture_valid[l] && capture_tag[l].ph > 0 && capture_tag[l].cfg.accum_mode != 2) ws_fusion_inc++;
      if (tmp_valid[l]) begin
        if (tmp_tag[l].cfg.accum_mode == 2) begin
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
  always_ff @(posedge clock or negedge reset_n)
    if (!reset_n) begin
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
  // ===== 7. Completion paths, shared views, batch decode =====
  // No output backpressure: each fixed-latency path returns Contexts in
  // issue order. The last Context completing a path also drains all earlier
  // Contexts on that path. Per-lane reservation/duplicate checks live in TB.
  logic pending_psum;
  logic [4:0] pipe_live;
  // Psum publication is registered; tmp publication uses its capture metadata.
  logic [31:0] raw_valid;
  wire [31:0] psum_raw_valid;
  int raw_context[0:31];  // Combinational view of three shared Context registers.
  wire [1023:0] raw_data;  // Valid-qualified observation of existing tmp/Psum storage.
`ifndef SYNTHESIS
  initial begin
    if (MAX_CONTEXTS < 1 || OUTPUT_BUFFER_DEPTH < 1 || WGT_RADDR_BUFFER_DEPTH < 1)
      $fatal(1, "Context capacity must be >= 1");
  end
`endif
  function automatic tag_t expand_meta(input txn_meta_t meta);
    tag_t result;
    result = '0;
    result.valid = meta.valid;
    result.cfg = meta.cfg;
    result.cmd.cim_reduce_split_mask = meta.cfg.split_mask;
    result.cmd.cim_macro_en_mask = meta.cfg.macro_en_mask;
    result.cmd.cim_macro_oc_mask = meta.cfg.macro_oc_mask;
    result.cmd.cim_as_cnt = meta.cfg.accum_mode == 2 ? 2 : 1;
    result.cmd.cim_os_cnt = meta.cfg.accum_mode == 1 ? 2 : 1;
    result.cmd.cim_ws_cnt = 1;
    result.cmd.cim_precision = meta.cfg.last_phase == 0 ? 0 : meta.cfg.last_phase == 1 ? 1 : 4;
`ifndef SYNTHESIS
    result.cmd = meta.check_cmd;
`endif
    result.ph = int'(meta.ph);
    result.ctx = int'(meta.ctx);
    result.first_tile = meta.first_tile;
    result.last_tile = meta.last_tile;
    result.mask = pipeline_lanes(meta.cfg,0) | pipeline_lanes(meta.cfg,1) | pipeline_lanes(meta.cfg,2);
    return result;
  endfunction
  function automatic txn_meta_t compact_tag(input tag_t tag);
    txn_meta_t result;
    result.valid = tag.valid;
    result.cfg = tag.cfg;
    result.ph = 2'(tag.ph);
    result.ctx = CONTEXT_W'(tag.ctx);
    result.first_tile = tag.first_tile;
    result.last_tile = tag.last_tile;
`ifndef SYNTHESIS
    result.check_cmd = tag.cmd;
`endif
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
    // Each Macro uses its full 256-bit OC row: 128/64/32 ACT digits.
    // K=256 uses 2/4/8 distinct slots in W2/W4/W8; masks set participation.
    case (batch_weight_bits)
      2: batch_act_digits = 128;
      4: batch_act_digits = 64;
      8: batch_act_digits = 32;
      default: batch_act_digits = 0;
    endcase
    batch_lane_mask = '0;
    batch_macro_demand = '0;
    batch_macro_active = '0;
    for (int g = 0; g < 8; g++) batch_group_size[g] = '0;
    for (int m = 0; m < 8; m++) begin
      batch_macro_group[m] = 3'(group_of(batch_command.cim_reduce_split_mask, m));
      batch_group_size[batch_macro_group[m]]++;
      batch_macro_active[m] = batch_command.cim_macro_en_mask[m] && (|batch_command.cim_macro_oc_mask[4*m+:4]);
      // Decode physical group placement for each enabled Macro.
      // from Macro enables, never from OC0's potentially masked valid.
      for (int c = 0; c < 4; c++) begin
        batch_macro_demand[4*m+c] =
          merge_contributes(batch_command.cim_reduce_split_mask, batch_command.cim_macro_oc_mask, m, c);
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
  always_comb begin : shared_metadata_views
    early_tag = expand_meta(pipe_meta[1]);
    macro_tag = expand_meta(pipe_meta[2]);
    red1_tag = expand_meta(pipe_meta[3]);
    red2_tag = expand_meta(pipe_meta[4]);
    for (int path = 0; path < 3; path++) begin
      tmp_path_lanes[path] = pipeline_lanes(tmp_path_meta[path].cfg,path);
      raw_path_lanes[path] = pipeline_lanes(raw_path_cfg[path],path);
    end
    for (int l = 0; l < 32; l++) begin
      tmp_tag[l] = '0;
      raw_context[l] = 0;
      for (int path = 0; path < 3; path++) begin
        if (tmp_path_valid[path] && tmp_path_lanes[path][l]) begin
          tmp_tag[l] = expand_meta(tmp_path_meta[path]);
          raw_context[l] = int'(tmp_path_meta[path].ctx);
        end
        if (psum_path_valid[path] && raw_path_lanes[path][l])
          raw_context[l] = int'(raw_path_context[path]);
      end
    end
  end
  // ===== 8. Independent channel reception and issue scheduling =====
  // An empty slot can always accept its next beat. Derive forwarding from
  // that capacity directly so issue does not feed back through ready.
  wire buffered_weight = deep_batch ? context_idx < command_count : weight_available;
  wire issue_last_tile = tile == batch_last_tile;
  assign forward_act = packet_active && !sram_cs_en && act_tiles_left != 0 &&
      !act_slice_valid[phase] && external_phase == phase && act_valid_i;
  assign forward_weight = packet_active && !sram_cs_en && weight_tiles_left != 0 &&
      !buffered_weight && (!deep_batch || context_idx == command_count) && weight_valid_i;
  always_comb begin
    command = batch_command;
    phases = batch_phase_count;
    contexts = batch_command.cim_ws_cnt > 1 ? int'(batch_command.cim_ws_cnt) : int'(batch_command.cim_as_cnt);
    plane = forward_act ? act_data_i : act_buffer[1024*phase+:1024];
    issue_mask = batch_lane_mask;
    active = batch_macro_active;
    final_issue = phase == batch_last_phase && issue_last_tile;
    issue = packet_active && (act_slice_valid[phase] || forward_act) && (buffered_weight || forward_weight);
    ren = active & {8{issue}};
    for (int m = 0; m < 8; m++) station[m] = !hold_valid[m] || hold_addr[m] != issue_weight_address;
  end
  assign issue_weight_address = forward_weight ? weight_raddr_i :
      deep_batch ? context_address[context_idx] : packet_weight_address;
  assign tile_end = issue && phase == batch_last_phase && context_idx == contexts - 1;
  assign job_end = tile_end && issue_last_tile;
  assign release_plane = issue && (!batch_is_as || context_idx == contexts - 1);
  assign release_weight = a4_packet ? issue : tile_end;
  assign input_slot_free = !packet_active || job_end;
  // Count each in-flight issue using its OWN route and enabled lanes. A newer
  // empty/shallow mask must not hide an older deep result. Ignore tag stages
  // beyond that issue's actual endpoint. Current RAW is sampled on this edge.
  assign pipe_live[2:0] = {pipe_meta[2].valid,pipe_meta[1].valid,pipe_meta[0].valid};
  assign pipe_live[3] = pipe_meta[3].valid && (|(pipeline_lanes(pipe_meta[3].cfg,1) | pipeline_lanes(pipe_meta[3].cfg,2)));
  assign pipe_live[4] = pipe_meta[4].valid && (|pipeline_lanes(pipe_meta[4].cfg,2));
  assign upstream_busy = (issue && (|issue_mask)) || (|pipe_live);
  always_comb begin
    pending_psum = 0;
    for (int path = 0; path < 3; path++)
      pending_psum |= tmp_path_valid[path] && tmp_path_meta[path].cfg.accum_mode != 0;
  end
  assign drain_safe = !upstream_busy && !pending_psum;
  // Ready is a capacity promise; reset qualification belongs to the protocol.
  logic pipeline_compatible;
  always_comb begin : compatible_inflight
    pipeline_compatible = compatible_pipeline(pipeline_config(cmd_i),pipeline_config(batch_command));
    for (int s = 0; s < 5; s++)
      if (pipe_live[s]) pipeline_compatible &= compatible_pipeline(pipeline_config(cmd_i),pipe_meta[s].cfg);
    for (int path = 0; path < 3; path++)
      if (tmp_path_valid[path] && tmp_path_meta[path].cfg.accum_mode != 0)
        pipeline_compatible &= compatible_pipeline(pipeline_config(cmd_i),tmp_path_meta[path].cfg);
  end
  assign cmd_ready_o = !mbist_test_busy_o && !bist_accept && !sram_cs_en && input_slot_free && (!batch_active || pipeline_compatible || drain_safe);
  // Each stream is ordered independently. The old job has first claim on
  // its last missing beat; a stream already finished may start the next job.
  assign act_ready_o = cmd_accept || (!sram_cs_en && packet_active && act_tiles_left != 0 &&
      (!act_slice_valid[external_phase] || (release_plane && phase == external_phase)));
  assign weight_ready_o = cmd_accept || (!sram_cs_en && packet_active && weight_tiles_left != 0 &&
      (deep_batch ? (command_count < contexts || tile_end) : (!weight_available || release_weight)));
  // tmp-backed results are visible as soon as the final tmp write completes.
  // The consumer samples them before the following edge may overwrite tmp.
  // Psum-backed results retain writeback-aligned registered publication.
  assign raw_psum = raw_data;
  assign psum_valid = raw_valid;
  always_comb begin
    for (int l = 0; l < 32; l++) raw_valid[l] = psum_raw_valid[l] || (result_done[l] && tmp_tag[l].cfg.accum_mode == 0);
  end
  for (genvar l = 0; l < 32; l++) begin : g_output_lane
    assign raw_data[32*l+:32] = psum_raw_valid[l] ? psum[raw_context[l]][l] : tmp_result[l];
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
      .reset_n(reset_n),
      .timing_config(timing_config_q),
      .waen(waen_q),
      .raen(raen_q),
      .mbist_select(bist_select[m]),
      .mbist_repair_select(mbist_id_q == 3'(m)),
      .mbist_config(mbist_config_q),
      .mbist_busy(bist_busy[m]),
      .mbist_done(bist_done[m]),
      .mbist_valid(bist_valid[m]),
      .mbist_unrepairable(bist_unrepairable[m]),
      .mbist_errors(bist_errors[m]),
      .cim_ren(ren[m]),
      .cim_idata(idata),
      .cim_raddr(issue_weight_address),
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
    .reset_n(reset_n),
    .early_valid_i(early_tag.valid),
    .early_split_i(early_tag.cmd.cim_reduce_split_mask),
    .early_en_i(early_tag.cmd.cim_macro_en_mask),
    .early_oc_i(early_tag.cmd.cim_macro_oc_mask),
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
  // ===== 10. Accumulation: buffer enables, tmp/Psum arrays, arithmetic =====
  function automatic logic [31:0] expand_path_mask(input logic [2:0] requests, input logic [31:0] lanes[0:2]);
    return (lanes[0] & {32{requests[0]}}) | (lanes[1] & {32{requests[1]}}) | (lanes[2] & {32{requests[2]}});
  endfunction
  // The aligned pipeline valid already reaches each tap before its tmp write edge.
  assign tmp_input_cg_en = tap_mask[0] | tap_mask[1] | tap_mask[2];
  assign tmp_valid = expand_path_mask(tmp_path_valid, tmp_path_lanes);
  assign psum_raw_valid = expand_path_mask(psum_path_valid, raw_path_lanes);
  for (genvar l = 0; l < 32; l++) begin : g_tmp_input
    MacroClockGate #(
      .ENABLE_GATING(USE_CLOCK_GATING)
    ) u_icg (
      .clock(clock),
      .enable(tmp_input_cg_en[l]),
      .gated_clock(tmp_input_clock[l])
    );
    always_ff @(posedge tmp_input_clock[l] or negedge reset_n)
      if (!reset_n) tmp_result[l] <= 0;
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
    wire tmp_meta_req, raw_meta_req;
    assign tmp_meta_req = tap_valid[path] && (|tap_mask[path]);
    assign raw_meta_req = tmp_path_valid[path] && tmp_path_meta[path].cfg.accum_mode != 0 &&
                          (|(result_done & tmp_path_lanes[path]));
    always_ff @(posedge clock or negedge reset_n) begin
      if (!reset_n) begin
        tmp_path_valid[path] <= 1'b0;
        psum_path_valid[path] <= 1'b0;
      end else begin
        tmp_path_valid[path] <= tap_valid[path];
        psum_path_valid[path] <= raw_meta_req;
      end
    end
    MacroClockGate #(
      .ENABLE_GATING(USE_CLOCK_GATING)
    ) u_tmp_meta_icg (
      .clock(clock),
      .enable(tmp_meta_req),
      .gated_clock(tmp_meta_clock)
    );
    MacroClockGate #(
      .ENABLE_GATING(USE_CLOCK_GATING)
    ) u_raw_meta_icg (
      .clock(clock),
      .enable(raw_meta_req),
      .gated_clock(raw_meta_clock)
    );
    always_ff @(posedge tmp_meta_clock or negedge reset_n)
      if (!reset_n) tmp_path_meta[path] <= '0;
      else if (tmp_meta_req) tmp_path_meta[path] <= compact_tag(tap_tag[path]);
    always_ff @(posedge raw_meta_clock or negedge reset_n)
      if (!reset_n) begin
        raw_path_context[path] <= '0;
        raw_path_cfg[path] <= '0;
      end else if (raw_meta_req) begin
        raw_path_context[path] <= tmp_path_meta[path].ctx;
        raw_path_cfg[path] <= tmp_path_meta[path].cfg;
      end
  end
  for (genvar d = 0; d < OUTPUT_BUFFER_DEPTH; d++) begin : g_psum_depth
    // Register each tap's write request at tmp capture, one edge before Psum
    // writeback. The shared lane mapping is held until these writes drain.
    logic [2:0] path_write_req;
    for (genvar path = 0; path < 3; path++) begin : g_path_req
      always_ff @(posedge clock or negedge reset_n)
        if (!reset_n) path_write_req[path] <= 1'b0;
        else path_write_req[path] <= tap_valid[path] && tap_tag[path].ctx == d &&
            (tap_tag[path].cfg.accum_mode == 2 || (tap_tag[path].cfg.accum_mode == 1 &&
             tap_tag[path].ph == int'(tap_tag[path].cfg.last_phase)));
    end
    assign psum_cg_en[d] = expand_path_mask(path_write_req, tmp_path_lanes);
    // A retiring old Context may exceed the NEW job's Context count.
    // The aligned request already selects a legal physical entry and its lanes.
    assign psum_depth_open[d] = (|psum_cg_en[d]);
    for (genvar l = 0; l < 32; l++) begin : g_lane
      MacroClockGate #(
        .ENABLE_GATING(USE_CLOCK_GATING)
      ) u_icg (
        .clock(clock),
        .enable(psum_depth_open[d] && psum_cg_en[d][l]),
        .gated_clock(psum_clock[d][l])
      );
      always_ff @(posedge psum_clock[d][l] or negedge reset_n)
        if (!reset_n) psum[d][l] <= 0;
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
      longint signed shift_data;
      logic [1:0] shift_phase;
      bit tmp_is_as, capture_is_as;
      tmp_is_as = tmp_tag[l].cfg.accum_mode == 2;
      capture_is_as = capture_tag[l].cfg.accum_mode == 2;
      shift_data = tmp_is_as ? longint'($signed(tmp_result[l])) : capture_data[l];
      shift_phase = tmp_is_as ? 2'(tmp_tag[l].ph) : 2'(capture_tag[l].ph);
      fusion_enable[l] = 0;
      acc_enable[l] = 0;
      psum_write[l] = 0;
      fusion_a[l] = 0;
      fusion_b[l] = 0;
      acc_a[l] = 0;
      acc_b[l] = 0;
      if (capture_valid[l] && !capture_is_as && capture_tag[l].ph > 0) begin
        fusion_enable[l] = 1;
        fusion_a[l] = tmp_result[l];
      end
      if (tmp_valid[l] && tmp_is_as && tmp_tag[l].ph > 0) begin
        fusion_enable[l] = 1;
        fusion_a[l] = psum[tmp_tag[l].ctx][l];
      end
      if (fusion_enable[l]) fusion_b[l] = shift_data <<< {shift_phase, 2'b00};
      if (tmp_valid[l]) begin
        if (tmp_is_as) begin
          psum_write[l] = 1;
          acc_enable[l] = tmp_tag[l].ph == 0 && !tmp_tag[l].first_tile;
        end else begin
          psum_write[l] = tmp_tag[l].cfg.accum_mode == 1 && tmp_tag[l].ph == int'(tmp_tag[l].cfg.last_phase);
          acc_enable[l] = psum_write[l] && !tmp_tag[l].first_tile;
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
      tmp_store_data[l] = (capture_valid[l] && !capture_is_as && capture_tag[l].ph > 0) ?
          fusion_result[l] : capture_data[l];
      arithmetic_result[l] = acc_enable[l] ? acc_result[l] :
        (tmp_valid[l] && tmp_is_as && tmp_tag[l].ph > 0) ?
        fusion_result[l] : tmp_result[l];
      result_done[l] = tmp_valid[l] && tmp_tag[l].ph == int'(tmp_tag[l].cfg.last_phase) && tmp_tag[l].last_tile;
    end
  end
  // ===== 11. Main pipeline state machine =====
`ifndef SYNTHESIS
  // A channel may be captured by at most one active tap. Union the masks in tap
  // order; only the assertion inside the pipeline block consumes the conflicts.
  wire [31:0] tap_claim_0, tap_claim_1, tap_claim_2, tap_conflict;
  assign tap_claim_0  = tap_valid[0] ? tap_mask[0] : 32'd0;
  assign tap_claim_1  = tap_valid[1] ? tap_mask[1] : 32'd0;
  assign tap_claim_2  = tap_valid[2] ? tap_mask[2] : 32'd0;
  assign tap_conflict = (tap_claim_1 & tap_claim_0) | (tap_claim_2 & (tap_claim_0 | tap_claim_1));
`endif
  always_ff @(posedge clock or negedge reset_n) begin : pipeline
    if (!reset_n) begin
      packet_weight_address <= '0;
      packet_active <= 0;
      weight_available <= 0;
      act_slice_valid <= '0;
      external_phase <= 0;
      command_count <= 0;
      act_tiles_left <= 0;
      reuse_left <= 0;
      weight_tiles_left <= 0;
      phase <= 0;
      context_idx <= 0;
      tile <= 0;
      hold_valid <= '0;
      batch_active <= 0;
      batch_command <= '0;
      foreach (pipe_meta[s]) pipe_meta[s] <= '0;
    end else begin
      // A missing operand only inserts an invalid issue. Downstream stages
      // always advance, including while a different command is held outside.
      if (release_plane) act_slice_valid[phase] <= 0;
      if (release_weight) weight_available <= 0;
      if (tile_end) command_count <= 0;
      if (job_end) packet_active <= 0;
      if (batch_active && !packet_active && drain_safe) batch_active <= 0;
      // Initialize the new input job before crediting any same-edge beats.
      if (cmd_accept) begin
`ifndef SYNTHESIS
        if (cmd_i.cim_os_cnt == 0 || cmd_i.cim_ws_cnt == 0 || cmd_i.cim_as_cnt == 0)
          $fatal(1, "CLUSTER_COUNT_RANGE: counts must be 1..511");
        if (cmd_i.cim_ws_cnt > MAX_CONTEXTS || cmd_i.cim_as_cnt > MAX_CONTEXTS)
          $fatal(1, "CLUSTER_CONTEXT_CAPACITY: context metadata exceeded");
        if (cmd_i.cim_as_cnt > OUTPUT_BUFFER_DEPTH)
          $fatal(1, "CLUSTER_CONTEXT_CAPACITY: AS count exceeds output depth");
        if (cmd_i.cim_as_cnt > 1 && abits(int'(cmd_i.cim_precision)) > 4 && cmd_i.cim_as_cnt > WGT_RADDR_BUFFER_DEPTH)
          $fatal(1, "CLUSTER_CONTEXT_CAPACITY: weight address depth exceeded");
        if (cmd_i.cim_os_cnt > 1 && cmd_i.cim_ws_cnt > OUTPUT_BUFFER_DEPTH)
          $fatal(1, "CLUSTER_CONTEXT_CAPACITY: Psum depth exceeded");
        if (cmd_i.cim_precision > 6 || !canonical(cmd_i.cim_reduce_split_mask) ||
            (cmd_i.cim_ws_cnt > 1 && cmd_i.cim_as_cnt > 1))
          $fatal(1, "Invalid descriptor / context capacity");
        for (int m = 0; m < 8; m++)
        if (cmd_i.cim_macro_en_mask[m]) begin
          if (int'(cmd_i.cim_act_slot_sel[3*m+:3]) >= wbits(int'(cmd_i.cim_precision)))
            $fatal(1, "ACT slot outside plane");
          for (int n = 0; n < m; n++)
          if (cmd_i.cim_macro_en_mask[n] && cmd_i.cim_act_slot_sel[3*m+:3] == cmd_i.cim_act_slot_sel[3*n+:3]) begin
            if (group_of(cmd_i.cim_reduce_split_mask, n) == group_of(cmd_i.cim_reduce_split_mask, m))
              $fatal(1, "Repeated K slot in one reduction group");
          end
        end
`endif
        batch_active <= 1;
        batch_command <= cmd_i;
        packet_active <= 1;
        act_slice_valid <= '0;
        external_phase <= 0;
        command_count <= 0;
        weight_available <= 0;
        act_tiles_left <= cmd_i.cim_os_cnt;
        weight_tiles_left <= cmd_i.cim_os_cnt;
      end
      if (consume_reuse) reuse_left <= receive_left == 1 ? reuse_count : receive_left - 1'b1;
      else if (cmd_accept) reuse_left <= reuse_count;
      if (store_act) begin
        act_slice_valid[external_phase] <= !(forward_act && release_plane);
        if (receive_frame_end && (receive_ws_count == 1 || receive_left == 1))
          act_tiles_left <= (cmd_accept ? cmd_i.cim_os_cnt : act_tiles_left) - 1'b1;
        external_phase <= receive_frame_end ? 0 : external_phase + 1'b1;
      end
      if (store_weight) begin
        if (receive_as_count == 1 || receive_left == 1)
          weight_tiles_left <= (cmd_accept ? cmd_i.cim_os_cnt : weight_tiles_left) - 1'b1;
        if (receive_deep_as) command_count <= (cmd_accept || tile_end) ? 1 : command_count + 1'b1;
        else begin
          weight_available <= !(forward_weight && release_weight);
          packet_weight_address <= weight_raddr_i;
        end
      end
      for (int m = 0; m < 8; m++) begin
        if (memory_wen[m] || bist_select[m]) hold_valid[m] <= 0;
        else if (regular_read && regular_macro_id == m) begin
          hold_valid[m] <= 1;
          hold_addr[m]  <= sram_row_addr;
        end else if (ren[m] && station[m]) begin
          hold_valid[m] <= 1;
          hold_addr[m]  <= issue_weight_address;
        end
      end
      // Empty effective masks have no downstream transaction. Suppressing
      // their tags prevents a draining empty batch from borrowing the next
      // batch's shared mask after ready reopens. Input scheduling is unchanged.
      pipe_meta[0].valid <= issue && (|issue_mask);
      if (issue) begin
`ifndef SYNTHESIS
        if (forward_act && !act_accept || forward_weight && !weight_accept)
          $fatal(1, "Internal issue forwarded an operand without a handshake");
`endif
        pipe_meta[0].cfg <= pipeline_config(command);
        pipe_meta[0].ph  <= 2'(phase);
        pipe_meta[0].ctx <= CONTEXT_W'(context_idx);
        pipe_meta[0].first_tile <= tile == 0;
        pipe_meta[0].last_tile <= issue_last_tile;
`ifndef SYNTHESIS
        pipe_meta[0].check_cmd <= command;
`endif
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
      for (int s = 1; s < $size(pipe_meta); s++) pipe_meta[s] <= pipe_meta[s-1];
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
`ifndef SYNTHESIS
      for (int l = 0; l < 32; l++)
      if (result_done[l]) begin
        // This checks the current widened operation only. Earlier signed32
        // tmp/Psum truncation may already have wrapped an oversized history
        // back into range; this is not end-to-end overflow detection.
        if(arithmetic_result[l] < -64'sd2147483648 || arithmetic_result[l]>64'sd2147483647 ||
             (!tmp_tag[l].cmd.cim_signed_en && arithmetic_result[l]<0))
          $fatal(1, "Psum signed32 overflow (policy TBD)");
      end
      if (|tap_conflict) $fatal(1, "Concurrent tree taps target same channel");
      for (int path = 0; path < 3; path++)
      if (tap_valid[path]) begin
        if (!tap_tag[path].valid || tap_mask[path] !== pipeline_lanes(tap_tag[path].cfg,path))
          $fatal(1, "Terminal tap metadata mismatch path=%0d", path);
      end
`endif
      // Short endpoints may leave valid bits in unused deeper tag stages.
      // They must not be reinterpreted with a newly installed deeper route.
      if (cmd_accept && (!batch_active || !pipeline_compatible))
        foreach (pipe_meta[s]) pipe_meta[s].valid <= 0;
    end
  end
endmodule
