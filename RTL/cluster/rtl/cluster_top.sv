`timescale 1ns / 1ps
// Simulation reference Cluster, with raw Psum and combinational INT8 Requant.
module cluster_top #(
  parameter int WGT_RADDR_BUFFER_DEPTH = 16,
  parameter int MAX_CONTEXTS = 64,
  parameter int OUTPUT_BUFFER_DEPTH = 16,
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
  logic [4095:0] act_buffer;  // four 1024-bit bit-slice planes, A0..A3
  logic [1023:0] plane;
  cluster_ctrl_t packet_cmd;
  logic [7:0] context_address[0:WGT_RADDR_BUFFER_DEPTH - 1];
  logic [7:0] current_weight_address;  // A4 AS bypass; no deep address entry clocks
  logic packet_active, act_loading, act_complete;
  logic [3:0] act_slice_valid;
  int external_phase, command_count;
  wire cmd_accept = cmd_valid_i && cmd_ready_o;
  int phase, context_idx, tile, phases, contexts;
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
  wire deep_batch = batch_command.cim_as_cnt > 1 && abits(int'(batch_command.cim_precision)) > 4;
  wire a4_packet = packet_cmd.cim_as_cnt > 1 && abits(int'(packet_cmd.cim_precision)) == 4;
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
  always @(posedge entry0_clock or posedge reset)
    if (reset) current_weight_address <= '0;
    else if (storage_active) current_weight_address <= cmd_i.cim_weight_raddr;
  always @(posedge deep_weight_clock or posedge reset) begin
    if (reset) for (int d = 0; d < WGT_RADDR_BUFFER_DEPTH; d++) context_address[d] <= '0;
    else if (cmd_accept && deep_command && write_context_slot < WGT_RADDR_BUFFER_DEPTH)
      context_address[write_context_slot] <= cmd_i.cim_weight_raddr;
  end
  // One table clock for ZP and the shared scale; unused channel scales have
  // a separate group clock. No per-entry clock gates or FIFO pointers.
  always @(posedge deep_requant_clock or posedge reset) begin
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
  always @(posedge channel_scale_clock or posedge reset) begin
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
  always @(posedge batch_cfg_clock or posedge reset) begin
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
  always @(posedge batch_channel_clock or posedge reset) begin
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
  wire [7:0] memory_wen = regular_write ? (8'b1 << regular_macro_id) : 8'b0;
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
  always @(posedge clock)
    if (!reset) begin
      if (sram_cs_en && (batch_active || packet_active || cmd_valid_i || (|macro_valid)))
        $fatal(1, "CLUSTER_SRAM_PROTOCOL: regular access overlaps compute");
      if (sram_cs_en && ((^{sram_wr_en, sram_macro_group, sram_bank_sel, sram_row_addr}) === 1'bx))
        $fatal(1, "CLUSTER_SRAM_PROTOCOL: unknown regular address/control");
      if (sram_cs_en && sram_wr_en && ((^{sram_wmask, sram_wrdata}) === 1'bx))
        $fatal(1, "CLUSTER_SRAM_PROTOCOL: unknown regular write data/mask");
    end
  typedef struct packed {
    logic valid;
    cluster_ctrl_t cmd;
    int ph, ctx, kt;
    logic [31:0] mask;
  } tag_t;
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
  tag_t tmp_tag[0:31];
  logic signed [31:0] tmp_result[0:31];  // one 32-bit data DFF per OC
  // One tmp data register per OC; Psum stores Context history.
  // NUMERIC LIMIT: tmp/Psum are signed32 storage. Intermediate writes truncate
  // before the final-result overflow check; there is no intermediate overflow
  // flag or saturation. Every stored intermediate must fit signed32, not only
  // the final mathematical sum. See docs/Cluster_Requant.md (Psum limits).
  logic signed [31:0] psum[0:OUTPUT_BUFFER_DEPTH - 1][0:31];
  logic [OUTPUT_BUFFER_DEPTH - 1:0] psum_depth_open;
  int batch_contexts;
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
  longint signed tmp_store_data[0:31], arithmetic_result[0:31];
  logic [31:0] fusion_enable, acc_enable, psum_write, result_done;
  wire [255:0] requant_comb_data;
  wire [ 31:0] requant_comb_valid;
  // Internal operation coverage; no extra external interface.
  int tmp_only_steps, as_seed_steps, as_fusion_steps, as_acc_steps;
  int ws_fusion_steps, ws_acc_steps, ws_tile_commits, a4_acc_steps;
  // No output FIFO, no vector assembly. Every reserved OC lane publishes
  // itself the moment its result arrives: one one-cycle out_valid_o[l] pulse
  // per lane and Context. The downstream is assumed to be always ready (no
  // backpressure). result_ready/result_mask only track lane reservation and
  // completion for the integrity checks and the batch-end decision.
  logic [31:0] result_ready[0:MAX_CONTEXTS - 1];
  logic [31:0] result_mask[0:MAX_CONTEXTS - 1];
  // Internal observation only; no new external signal.
  // Raw observations remain available for the independent compute scoreboard.
  logic [31:0] raw_valid;
  int raw_context[0:31];  // internal per-lane tag; never an external pin
  logic [1023:0] raw_data;
  initial begin
    if (MAX_CONTEXTS < 1 || OUTPUT_BUFFER_DEPTH < 1 || WGT_RADDR_BUFFER_DEPTH < 1 || REQUANT_CONTEXT_DEPTH < 1)
      $fatal(1, "Context capacity must be >= 1");
  end
  always_comb begin
    command = packet_cmd;
    if (packet_cmd.cim_as_cnt > 1)
      command.cim_weight_raddr = a4_packet ? current_weight_address : context_address[context_idx];
    phases = abits(int'(command.cim_precision)) / 4;
    contexts = command.cim_ws_cnt > 1 ? int'(command.cim_ws_cnt) : int'(command.cim_as_cnt);
    // A0 accompanies the first Context descriptor. A1..A3 follow on
    // consecutive edges without ACT handshake. Other AS descriptors may
    // arrive concurrently; they only provide their own weight addresses.
    need_plane = !(packet_active && packet_cmd.cim_as_cnt > 1 && command_count < int'(packet_cmd.cim_as_cnt));
    plane = act_buffer[1024*phase+:1024];
    issue_mask = '0;
    active = '0;
    for (int m = 0; m < 8; m++) begin
      active[m] = command.cim_macro_en_mask[m] && (|command.cim_macro_oc_mask[4*m+:4]);
      for (int c = 0; c < 4; c++)
      if (command.cim_macro_en_mask[m] && merge_contributes(
          command.cim_reduce_split_mask, command.cim_macro_oc_mask, m, c
        ))
        issue_mask[4*group_of(command.cim_reduce_split_mask, m)+c] = 1;
    end
    final_issue = phase == phases - 1 && tile == int'(command.cim_os_cnt) - 1;
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
  // Internal registered raw_data/raw_valid feed Requant. Testbenches may
  // observe them hierarchically for arithmetic and latency checking only.
  // Registered raw Psum -> combinational Requant -> INT8 output registers.
  // NBA semantics capture the PREVIOUS raw publication and configuration.
  // A new batch may load its configuration on that same capture edge.
  always_comb begin
    selected_requant_cfg = batch_requant_cfg;
    if (batch_command.cim_as_cnt > 1)
      for (int l = 0; l < 32; l++)
      if (raw_valid[l] && raw_context[l] < REQUANT_CONTEXT_DEPTH) begin
        selected_requant_cfg.requant_zp[32*(l%4)+:32] = requant_context_zp[raw_context[l]][32*(l%4)+:32];
        // Tensor scale belongs to the Context, even when OC0 is masked.
        if (!batch_requant_cfg.requant_mode) begin
          selected_requant_cfg.requant_multiplier[31:0] = requant_context_multiplier[raw_context[l]][31:0];
          selected_requant_cfg.requant_shift[9:0] = requant_context_shift[raw_context[l]][9:0];
        end else begin
          selected_requant_cfg.requant_multiplier[32 * (l % 4) +: 32] = requant_context_multiplier[raw_context[l]][32 * (l % 4) +: 32];
          selected_requant_cfg.requant_shift[10*(l%4)+:10] = requant_context_shift[raw_context[l]][10*(l%4)+:10];
        end
      end
  end
  ClusterRequant u_requant (
    .cfg_i  (selected_requant_cfg),
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
    wire raw_clock, quant_clock;
    MacroClockGate #(
      .ENABLE_GATING(USE_CLOCK_GATING)
    ) u_raw_icg (
      .clock(clock),
      .enable(!reset && result_done[l]),
      .gated_clock(raw_clock)
    );
    MacroClockGate #(
      .ENABLE_GATING(USE_CLOCK_GATING)
    ) u_quant_icg (
      .clock(clock),
      .enable(!reset && requant_comb_valid[l]),
      .gated_clock(quant_clock)
    );
    always @(posedge raw_clock or posedge reset) begin
      if (reset) begin
        raw_data[32*l+:32] <= '0;
        raw_context[l] <= 0;
      end else if (result_done[l]) begin
        raw_data[32*l+:32] <= 32'(arithmetic_result[l]);
        raw_context[l] <= tmp_tag[l].ctx;
      end
    end
    always @(posedge quant_clock or posedge reset) begin
      if (reset) requant_data_o[8*l+:8] <= '0;
      else if (requant_comb_valid[l]) begin
        if (batch_command.cim_as_cnt > 1 &&
            (raw_context[l] >= REQUANT_CONTEXT_DEPTH || !requant_context_valid[raw_context[l]]))
          $fatal(1, "CLUSTER_REQUANT_CONFIG: missing AS context zp");
        requant_data_o[8*l+:8] <= requant_comb_data[8*l+:8];
      end
    end
  end
  for (genvar m = 0; m < 8; m++) begin : g_macro
    logic [511:0] idata;
    wire  [  3:0] result_mask;
    for (genvar c = 0; c < 4; c++) begin : g_result_demand
      // Input-boundary demand is registered inside Macro before its output edge.
      assign result_mask[c] = merge_contributes(command.cim_reduce_split_mask, command.cim_macro_oc_mask, m, c);
    end
    always_comb begin
      idata = '0;
      if (wbits(int'(command.cim_precision)) != 0)
        for (int j = 0; j < 128; j++)
        if (j < 256 / wbits(int'(command.cim_precision)))
          idata[4*j+:4] = plane[4*(int'(command.cim_act_slot_sel[3*m+:3])*(256/wbits(
            int'(command.cim_precision)
          ))+j)+:4];
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
  // Predict each terminal lane one cycle before its tmp capture edge.
  // Structural group size, not number of enabled Macros, selects tree depth.
  function automatic logic [31:0] terminal_lanes(input tag_t t, input int path);
    logic [31:0] mask;
    int size, g;
    mask = '0;
    for (int m = 0; m < 8; m++) begin
      g = group_of(t.cmd.cim_reduce_split_mask, m);
      size = 0;
      for (int n = 0; n < 8; n++) if (group_of(t.cmd.cim_reduce_split_mask, n) == g) size++;
      if ((size <= 2 ? 0 : size == 4 ? 1 : 2) == path && t.valid) mask[4*g+:4] = t.mask[4*g+:4];
    end
    return mask;
  endfunction
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
  always @(posedge clock or posedge reset) begin : advance_buffer_enables
    if (reset) begin
      tmp_input_cg_en <= '0;
      for (int d = 0; d < OUTPUT_BUFFER_DEPTH; d++) psum_cg_en[d] <= '0;
    end else begin
      tmp_input_cg_en <= terminal_lanes(
        early_tmp_tag[0], 0
      ) | terminal_lanes(
        early_tmp_tag[1], 1
      ) | terminal_lanes(
        early_tmp_tag[2], 2
      );
      for (int d = 0; d < OUTPUT_BUFFER_DEPTH; d++) psum_cg_en[d] <= '0;
      for (int l = 0; l < 32; l++)
      if (capture_valid[l]) begin
        if (capture_tag[l].cmd.cim_as_cnt > 1) begin
          if (capture_tag[l].cmd.cim_os_cnt > 1 || abits(int'(capture_tag[l].cmd.cim_precision)) > 4)
            psum_cg_en[capture_tag[l].ctx][l] <= 1;
        end else if (capture_tag[l].cmd.cim_os_cnt > 1 && capture_tag[l].ph == abits(
            int'(capture_tag[l].cmd.cim_precision)
          ) / 4 - 1)
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
    always @(posedge tmp_input_clock[l] or posedge reset)
      if (reset) tmp_result[l] <= 0;
      else if (tmp_input_cg_en[l]) tmp_result[l] <= tmp_store_data[l];
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
      always @(posedge psum_clock[d][l] or posedge reset)
        if (reset) psum[d][l] <= 0;
        else if (psum_depth_open[d] && psum_cg_en[d][l]) psum[d][l] <= arithmetic_result[l];
    end
  end
  // One fusion block and one acc block per OC, shared by all Contexts.
  // WS/single fuses adjacent slices in tmp; commits Psum only for OS>1.
  // AS traverses Contexts within each slice and stores history per Context.
  // AS A4 OS1 bypasses Psum; AS A8/A16 uses it even when OS=1.
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
      if (capture_valid[l] && capture_tag[l].cmd.cim_as_cnt <= 1 && capture_tag[l].ph > 0) begin
        fusion_enable[l] = 1;
        fusion_a[l] = tmp_result[l];
        fusion_b[l] = capture_data[l] <<< (4 * capture_tag[l].ph);
      end
      if (tmp_valid[l] && tmp_tag[l].cmd.cim_as_cnt > 1 && tmp_tag[l].ph > 0) begin
        fusion_enable[l] = 1;
        fusion_a[l] = psum[tmp_tag[l].ctx][l];
        fusion_b[l] = tmp_result[l] <<< (4 * tmp_tag[l].ph);
      end
      fusion_result[l] = fusion_a[l] + fusion_b[l];
      tmp_store_data[l] = (capture_valid[l] && capture_tag[l].cmd.cim_as_cnt <= 1 &&
        capture_tag[l].ph > 0) ? fusion_result[l] : capture_data[l];
      if (tmp_valid[l]) begin
        if (tmp_tag[l].cmd.cim_as_cnt > 1) begin
          psum_write[l] = tmp_tag[l].cmd.cim_os_cnt > 1 || abits(int'(tmp_tag[l].cmd.cim_precision)) > 4;
          acc_enable[l] = tmp_tag[l].ph == 0 && tmp_tag[l].kt > 0;
        end else begin
          psum_write[l] = tmp_tag[l].cmd.cim_os_cnt > 1 &&
            tmp_tag[l].ph == abits(int'(tmp_tag[l].cmd.cim_precision)) / 4 - 1;
          acc_enable[l] = psum_write[l] && tmp_tag[l].kt > 0;
        end
        if (acc_enable[l]) begin
          acc_a[l] = psum[tmp_tag[l].ctx][l];
          acc_b[l] = tmp_result[l];
        end
      end
      acc_result[l] = acc_a[l] + acc_b[l];
      arithmetic_result[l] = acc_enable[l] ? acc_result[l] :
        (tmp_valid[l] && tmp_tag[l].cmd.cim_as_cnt > 1 && tmp_tag[l].ph > 0) ?
        fusion_result[l] : tmp_result[l];
      result_done[l] = tmp_valid[l] && tmp_tag[l].ph == abits(int'(tmp_tag[l].cmd.cim_precision)) / 4 - 1 &&
        tmp_tag[l].kt == int'(tmp_tag[l].cmd.cim_os_cnt) - 1;
    end
  end
  always @(posedge clock or posedge reset) begin : pipeline
    bit all_done;
    logic [31:0] captured;
    int ctx, zp_ctx;
    if (reset) begin
      act_buffer <= '0;
      packet_cmd <= '0;
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
      in_tag <= '0;
      macro_tag <= '0;
      red1_tag <= '0;
      red2_tag <= '0;
      raw_valid <= '0;
      tmp_valid <= '0;
      batch_active <= 0;
      batch_input_done <= 0;
      batch_contexts <= 0;
      requant_context_valid <= '0;
      batch_command <= '0;
      psum_depth_open <= '0;
      tmp_only_steps = 0;
      as_seed_steps = 0;
      as_fusion_steps = 0;
      as_acc_steps = 0;
      ws_fusion_steps = 0;
      ws_acc_steps = 0;
      ws_tile_commits = 0;
      a4_acc_steps = 0;
      for (int l = 0; l < 32; l++) tmp_tag[l] <= '0;
      for (int c = 0; c < MAX_CONTEXTS; c++) begin
        result_ready[c] = '0;
        result_mask[c]  = '0;
      end
    end else begin
      if (cmd_accept) begin
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
        if (ENABLE_REQUANT && cmd_i.cim_as_cnt > 1) begin
          zp_ctx = int'(write_context_slot);
          if(batch_active && (requant_cfg_i.requant_mode!==batch_requant_cfg.requant_mode ||
                             requant_cfg_i.conv_mode!==batch_requant_cfg.conv_mode))
            $fatal(1, "CLUSTER_REQUANT_CONFIG: AS context mode changed");
          begin
            if ($isunknown({requant_cfg_i.requant_multiplier, requant_cfg_i.requant_shift}))
              $fatal(1, "CLUSTER_REQUANT_CONFIG: unknown AS context scale");
            for (int c = 0; c < 4; c++)
            if ((c == 0 || requant_cfg_i.requant_mode) && ($signed(
                requant_cfg_i.requant_shift[10*c+:10]
              ) < -31 || $signed(
                requant_cfg_i.requant_shift[10*c+:10]
              ) > 31))
              $fatal(1, "CLUSTER_REQUANT_CONFIG: shift must be -31..31");
          end
          if ($isunknown(requant_cfg_i.requant_zp)) $fatal(1, "CLUSTER_REQUANT_CONFIG: unknown AS context zp");
          if (write_requant_params) begin
            if (!batch_active) requant_context_valid <= '0;
            requant_context_valid[zp_ctx] <= 1;
          end else if (!requant_context_valid[zp_ctx] || requant_cfg_i.requant_zp !== requant_context_zp[zp_ctx])
            $fatal(1, "CLUSTER_REQUANT_CONFIG: AS context zp changed across K Tiles");
          else if (requant_cfg_i.requant_mode ?
                  (requant_cfg_i.requant_multiplier !== requant_context_multiplier[zp_ctx] ||
                   requant_cfg_i.requant_shift !== requant_context_shift[zp_ctx]) :
                  (requant_cfg_i.requant_multiplier[31:0] !== requant_context_multiplier[zp_ctx][31:0] ||
                   requant_cfg_i.requant_shift[9:0] !== requant_context_shift[zp_ctx][9:0]))
            $fatal(1, "CLUSTER_REQUANT_CONFIG: AS context scale changed across K Tiles");
        end
        if (!packet_active) begin
          packet_cmd <= cmd_i;
          packet_active <= 1;
          command_count <= 1;
          act_buffer[0+:1024] <= act_data_i;
          act_slice_valid <= 4'b0001;
          external_phase <= 1;
          act_loading <= abits(int'(cmd_i.cim_precision)) > 4;
          act_complete <= abits(int'(cmd_i.cim_precision)) == 4;
        end else begin
          if (deep_command && command_count >= WGT_RADDR_BUFFER_DEPTH) $fatal(1, "AS address capacity exceeded");
          command_count <= command_count + 1;
        end
        if (!batch_active) begin
          if (ENABLE_REQUANT && $isunknown(requant_cfg_i)) $fatal(1, "CLUSTER_REQUANT_CONFIG: unknown configuration");
          if (ENABLE_REQUANT && requant_cfg_i.requant_mode && !requant_cfg_i.conv_mode)
            $fatal(1, "CLUSTER_REQUANT_CONFIG: per-channel scale requires conv_mode");
          if (ENABLE_REQUANT && !conv_group_legal(cmd_i))
            $fatal(1, "CLUSTER_REQUANT_CONFIG: Requant requires one aligned reduction group");
          for (int c = 0; c < 4; c++)
          if (ENABLE_REQUANT && (c == 0 || requant_cfg_i.requant_mode))
            if ($signed(
                requant_cfg_i.requant_shift[10*c+:10]
              ) < -31 || $signed(
                requant_cfg_i.requant_shift[10*c+:10]
              ) > 31)
              $fatal(1, "CLUSTER_REQUANT_CONFIG: shift must be -31..31");
          batch_active   <= 1;
          batch_command  <= cmd_i;
          batch_contexts <= cmd_i.cim_ws_cnt > 1 ? int'(cmd_i.cim_ws_cnt) : int'(cmd_i.cim_as_cnt);
          // Clear per-lane completion tracking for the whole batch; the
          // per-Context reservation masks are (re)written at final_issue.
          for (int c = 0; c < MAX_CONTEXTS; c++) begin
            result_ready[c] = '0;
            result_mask[c]  = '0;
          end
          for (int d = 0; d < OUTPUT_BUFFER_DEPTH; d++)
          psum_depth_open[d] <= (cmd_i.cim_os_cnt > 1 || (cmd_i.cim_as_cnt > 1 && abits(
            int'(cmd_i.cim_precision)
          ) > 4)) && d < int'(cmd_i.cim_ws_cnt > 1 ? cmd_i.cim_ws_cnt : cmd_i.cim_as_cnt);
        end else if (cmd_i.cim_os_cnt != batch_command.cim_os_cnt ||
          cmd_i.cim_ws_cnt != batch_command.cim_ws_cnt || cmd_i.cim_as_cnt != batch_command.cim_as_cnt ||
          cmd_i.cim_precision != batch_command.cim_precision ||
          cmd_i.cim_signed_en != batch_command.cim_signed_en ||
          cmd_i.cim_reduce_split_mask != batch_command.cim_reduce_split_mask ||
          cmd_i.cim_macro_en_mask != batch_command.cim_macro_en_mask ||
          cmd_i.cim_macro_oc_mask != batch_command.cim_macro_oc_mask ||
          cmd_i.cim_act_slot_sel != batch_command.cim_act_slot_sel)
          $fatal(1, "Batch descriptor fields changed before completion");
      end
      if (act_loading) begin
        act_buffer[1024*external_phase+:1024] <= act_data_i;
        act_slice_valid[external_phase] <= 1;
        if (external_phase == abits(int'(packet_cmd.cim_precision)) / 4 - 1) begin
          act_loading  <= 0;
          act_complete <= 1;
        end else external_phase <= external_phase + 1;
      end
      for (int m = 0; m < 8; m++) begin
        if (memory_wen[m]) hold_valid[m] <= 0;
        else if (ren[m]) begin
          hold_valid[m] <= 1;
          hold_addr[m]  <= command.cim_weight_raddr;
        end
      end
      in_tag.valid <= issue;
      if (issue) begin
        if (!act_slice_valid[phase]) $fatal(1, "Internal issue before ACT slice loaded");
        if (phase == phases - 1 && (command.cim_as_cnt <= 1 || context_idx == contexts - 1)) begin
          packet_active <= 0;
          act_complete <= 0;
          command_count <= 0;
          act_slice_valid <= '0;
        end
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
        in_tag.cmd  <= command;
        in_tag.ph   <= phase;
        in_tag.ctx  <= context_idx;
        in_tag.kt   <= tile;
        in_tag.mask <= issue_mask;
        if (final_issue && context_idx == contexts - 1) batch_input_done <= 1;
        if (final_issue) begin
          // Reserve the Context's lanes once BEFORE final-phase results can
          // take any short path.
          result_mask[context_idx] <= issue_mask;
        end
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
      macro_tag <= in_tag;
      red1_tag  <= macro_tag;
      if (macro_tag.valid) begin
        for (int m = 0; m < 8; m++) begin
          if (macro_valid[m] !== (macro_tag.cmd.cim_macro_en_mask[m] && (|macro_tag.cmd.cim_macro_oc_mask[4*m+:4])))
            $fatal(1, "Macro valid not aligned with 1T result");
          if(macro_valid[m] && (macro_phase[2 * m +: 2]!==2'(macro_tag.ph) ||
              macro_mask[4 * m +: 4]!==macro_tag.cmd.cim_macro_oc_mask[4 * m +: 4]))
            $fatal(1, "Macro metadata mismatch");
        end
      end
      red2_tag  <= red1_tag;
      raw_valid <= '0;
      // Consume the PREVIOUS tmp DFF contents. NBA state writes preserve
      // consecutive-phase feedback and prevent zero-time procedural cascades.
      for (int l = 0; l < 32; l++)
      if (capture_valid[l] && capture_tag[l].ph > 0 && capture_tag[l].cmd.cim_as_cnt <= 1) begin
        ws_fusion_steps++;
      end
      for (int l = 0; l < 32; l++)
      if (tmp_valid[l]) begin
        if (tmp_tag[l].cmd.cim_as_cnt > 1) begin
          if (tmp_tag[l].cmd.cim_os_cnt == 1 && abits(int'(tmp_tag[l].cmd.cim_precision)) == 4) tmp_only_steps++;
          if (tmp_tag[l].ph > 0) as_fusion_steps++;
          else if (acc_enable[l]) as_acc_steps++;
          else if (psum_write[l]) as_seed_steps++;
        end else begin
          if (tmp_tag[l].cmd.cim_os_cnt == 1) tmp_only_steps++;
          if (psum_write[l]) ws_tile_commits++;
          if (acc_enable[l]) ws_acc_steps++;
        end
        if (acc_enable[l] && abits(int'(tmp_tag[l].cmd.cim_precision)) == 4) a4_acc_steps++;
        if (result_done[l]) begin
          // This checks the current widened operation only. Earlier signed32
          // tmp/Psum truncation may already have wrapped an oversized history
          // back into range; this is not end-to-end overflow detection.
          if(arithmetic_result[l] < -64'sd2147483648 || arithmetic_result[l]>64'sd2147483647 ||
             (!tmp_tag[l].cmd.cim_signed_en && arithmetic_result[l]<0))
            $fatal(1, "Psum signed32 overflow (policy TBD)");
          ctx = tmp_tag[l].ctx;
          if (!result_mask[ctx][l] || result_ready[ctx][l]) $fatal(1, "Unreserved/duplicate final lane write");
          result_ready[ctx][l] = 1;
          // Publish this internal raw lane: its raw_valid bit pulses for
          // one cycle, the lane value holds until the lane publishes again.
          raw_valid[l] <= 1;
        end
      end
      // Independent tree taps capture into per-channel tmp DFFs. There is
      // no additional root-only DFF or full-depth result alignment pipeline.
      captured = '0;
      tmp_valid <= '0;
      for (int path = 0; path < 3; path++)
      if (tap_valid[path]) begin
        if (!tap_tag[path].valid || ((tap_mask[path] & ~tap_tag[path].mask) != 0))
          $fatal(1, "Terminal tap metadata mismatch path=%0d", path);
        for (int l = 0; l < 32; l++)
        if (tap_mask[path][l]) begin
          if (captured[l]) $fatal(1, "Concurrent tree taps target same channel");
          captured[l] = 1;
          tmp_valid[l] <= 1;
          tmp_tag[l]   <= tap_tag[path];
        end
      end
      // A mixed tree writes shallow groups early; every lane publishes at
      // its own endpoint latency, so per-OC results leave the Cluster
      // without waiting for the Context vector to fill. Same-lane
      // publication order follows Context order: all Contexts share one
      // descriptor (identical lane latencies), final-issue cycles increase
      // strictly, and every completion cycle maps to exactly one issue
      // event. The batch closes only after every Context has reserved and
      // completed its lanes.
      // A leftmost mask can suppress every output while other Macros still
      // issue. Empty batches complete after all inputs, without lane pulses.
      all_done = batch_input_done;
      for (int c = 0; c < batch_contexts; c++) if (result_ready[c] != result_mask[c]) all_done = 0;
      if (batch_active && all_done) begin
        batch_active <= 0;
        batch_input_done <= 0;
        psum_depth_open <= '0;
      end
    end
  end
endmodule
