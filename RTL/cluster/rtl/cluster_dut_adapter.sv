`timescale 1ns/1ps
// Simulation reference Cluster. Existing ports carry RAW Psum, no requant.
module cluster_dut_adapter #(
  parameter int WGT_RADDR_BUFFER_DEPTH = 64,
  parameter int MAX_CONTEXTS = WGT_RADDR_BUFFER_DEPTH,
  parameter int OUTPUT_BUFFER_DEPTH = 16
) (
  input logic clock, reset,
  input cluster_pkg::cluster_ctrl_t cmd_i,
  input logic cmd_valid_i,
  output wire cmd_ready_o,
  input logic [1023:0] act_data_i,
  input logic [7:0] weight_wen_i,
  input logic [7:0] weight_waddr_i,
  input logic [8191:0] weight_wdata_i,
  input logic cim_cs_en, cim_wr_en,
  input logic cim_macro_group,
  input logic [1:0] cim_bank_sel,
  input logic [7:0] cim_row_addr,
  input logic [3:0] cim_wmask,
  input logic [1023:0] cim_wrdata,
  output wire [1023:0] cim_rd_data,
  output logic [1023:0] psum_data_o,
  output logic [31:0] out_valid_o
);
  import cluster_pkg::*;
  cluster_ctrl_t command;
  logic [4095:0] act_buffer; // four 1024-bit bit-slice planes, A0..A3
  logic [1023:0] plane;
  cluster_ctrl_t packet_cmd;
  logic [7:0] context_address[0:WGT_RADDR_BUFFER_DEPTH-1];
  logic packet_active,act_loading,act_complete;
  logic [3:0] act_slice_valid;
  int external_phase,command_count;
  wire cmd_accept=cmd_valid_i && cmd_ready_o;
  int phase, context_idx, tile, phases, contexts;
  logic need_plane, issue, final_issue;
  logic [31:0] issue_mask;
  logic [7:0] active, ren, station, hold_valid;
  logic [7:0] hold_addr [0:7];
  wire [575:0] macro_data;
  wire [7:0] macro_valid;
  wire [31:0] macro_mask;
  wire [15:0] macro_phase;
  logic batch_active, batch_input_done;
  wire [2:0] regular_macro_id = {cim_macro_group,cim_bank_sel};
  wire regular_access = !reset && cim_cs_en;
  wire regular_read = regular_access && !cim_wr_en;
  wire regular_write = regular_access && cim_wr_en && !(&cim_wmask);
  wire [7:0] memory_wen = reset ? 8'b0 : regular_access
                         ? (regular_write ? (8'b1 << regular_macro_id) : 8'b0)
                         : weight_wen_i;
  wire [8191:0] regular_read_data;
  // Reference timing: asynchronous read, zero outside a selected read.
  // Product SRAM read latency remains an integration choice.
  assign cim_rd_data = regular_read ? regular_read_data[1024*regular_macro_id+:1024] : 1024'b0;
  always @(posedge clock) if (!reset) begin
    if (cim_cs_en && (batch_active || packet_active || cmd_valid_i || (|macro_valid)))
      $fatal(1,"CLUSTER_SRAM_PROTOCOL: regular access overlaps compute");
    if (cim_cs_en && (|weight_wen_i))
      $fatal(1,"CLUSTER_SRAM_PROTOCOL: regular access overlaps preload");
    if ((|weight_wen_i) && batch_active)
      $fatal(1,"CLUSTER_SRAM_PROTOCOL: preload overlaps compute");
    if (cim_cs_en && ((^{cim_wr_en,cim_macro_group,cim_bank_sel,cim_row_addr}) === 1'bx))
      $fatal(1,"CLUSTER_SRAM_PROTOCOL: unknown regular address/control");
    if (cim_cs_en && cim_wr_en && ((^{cim_wmask,cim_wrdata}) === 1'bx))
      $fatal(1,"CLUSTER_SRAM_PROTOCOL: unknown regular write data/mask");
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
    tap_tag[0]=macro_tag; tap_tag[1]=red1_tag; tap_tag[2]=red2_tag;
    early_tmp_tag[0]=in_tag; early_tmp_tag[1]=macro_tag; early_tmp_tag[2]=red1_tag;
  end
  // Each tree endpoint writes one per-output-channel tmp result register.
  // The tagged arithmetic stage consumes it on the NEXT edge (II=1).
  // OUTPUT_BUFFER_DEPTH is the per-OC Context state capacity, not a FIFO.
  logic [31:0] tmp_valid;
  tag_t tmp_tag[0:31];
  logic signed [31:0] tmp_result[0:31]; // one 32-bit data DFF per OC
  // One tmp data register per OC; Psum stores Context history.
  logic signed [31:0] psum [0:OUTPUT_BUFFER_DEPTH-1][0:31];
  logic [OUTPUT_BUFFER_DEPTH-1:0] psum_depth_open;
  int batch_contexts;
  cluster_ctrl_t batch_command;
  // Explicit advance ICG enables: registered at tmp capture, consumed by
  // the arithmetic-state DFFs on the next edge. High address depths are
  // disabled for the WHOLE batch, independently of per-cycle write requests.
  logic [31:0] tmp_input_cg_en;
  logic [31:0] psum_cg_en[0:OUTPUT_BUFFER_DEPTH-1];
  wire [31:0] tmp_input_clock;
  wire [31:0] psum_clock[0:OUTPUT_BUFFER_DEPTH-1];
  logic [31:0] capture_valid;
  tag_t capture_tag[0:31];
  longint signed capture_data[0:31];
  longint signed fusion_a[0:31], fusion_b[0:31], fusion_result[0:31];
  longint signed acc_a[0:31], acc_b[0:31], acc_result[0:31];
  longint signed tmp_store_data[0:31], arithmetic_result[0:31];
  logic [31:0] fusion_enable, acc_enable, psum_write, result_done;
  // Internal operation coverage; no extra external interface.
  int tmp_only_steps, as_seed_steps, as_fusion_steps, as_acc_steps;
  int ws_fusion_steps, ws_acc_steps, ws_tile_commits, a4_acc_steps;
  // No output FIFO, no vector assembly. Every reserved OC lane publishes
  // itself the moment its result arrives: one one-cycle out_valid_o[l] pulse
  // per lane and Context. The downstream is assumed to be always ready (no
  // backpressure). result_ready/result_mask only track lane reservation and
  // completion for the integrity checks and the batch-end decision.
  logic [31:0] result_ready [0:MAX_CONTEXTS-1];
  logic [31:0] result_mask [0:MAX_CONTEXTS-1];
  // Internal observation only; no new external signal.
  // raw_data is the no-requant test output: 32 bits per OC. The final
  // output after requant is 8 bits per OC; requant is not implemented here.
  logic [31:0] raw_valid;
  int raw_context[0:31]; // internal per-lane tag; never an external pin
  logic [1023:0] raw_data;
  initial begin
    if(MAX_CONTEXTS<1 || OUTPUT_BUFFER_DEPTH<1 || WGT_RADDR_BUFFER_DEPTH<1)
      $fatal(1,"Context capacity must be >= 1");
  end
  always_comb begin
    command=packet_cmd;
    if(packet_cmd.as_cnt>1) command.weight_cim_raddr=context_address[context_idx];
    phases=abits(int'(command.precision))/4;
    contexts=command.ws_cnt>1 ? int'(command.ws_cnt) : int'(command.as_cnt);
    // A0 accompanies the first Context descriptor. A1..A3 follow on
    // consecutive edges without ACT handshake. Other AS descriptors may
    // arrive concurrently; they only provide their own weight addresses.
    need_plane=!(packet_active && packet_cmd.as_cnt>1 && command_count<int'(packet_cmd.as_cnt));
    plane=act_buffer[1024*phase+:1024];
    issue_mask='0; active='0;
    for(int m=0;m<8;m++) begin
      active[m]=command.macro_en_mask[m] && (|command.macro_oc_mask[4*m+:4]);
      for(int c=0;c<4;c++)
        if(command.macro_en_mask[m] &&
           merge_contributes(command.reduce_split_mask,command.macro_oc_mask,m,c))
          issue_mask[4*group_of(command.reduce_split_mask,m)+c]=1;
    end
    final_issue=phase==phases-1 && tile==int'(command.os_cnt)-1;
    // Consume only registered inputs: a Plane/address accepted on this edge
    // becomes eligible on the next edge. Later Planes and AS descriptors may
    // still be loading; keep the existing phase/Context order when stalled.
    issue=packet_active && act_slice_valid[phase] && !batch_input_done &&
          (packet_cmd.as_cnt<=1 || context_idx<command_count);
    ren=active & {8{issue}};
    for(int m=0;m<8;m++)
      station[m]=!hold_valid[m] || hold_addr[m]!=command.weight_cim_raddr;
  end
  assign cmd_ready_o=!reset && !cim_cs_en && !batch_input_done &&
    (!packet_active || (packet_cmd.as_cnt>1 && command_count<int'(packet_cmd.as_cnt)));
  // Registered publish: each pulsing out_valid_o bit marks a fresh lane
  // result on psum_data_o for one cycle; that lane's value holds until its
  // next publication.
  always_comb begin
    out_valid_o=raw_valid;
    psum_data_o=raw_data;
  end
  for(genvar m=0;m<8;m++) begin: g_macro
    logic [511:0] idata;
    always_comb begin
      idata='0;
      if(wbits(int'(command.precision))!=0)
        for(int j=0;j<128;j++)
          if(j<256/wbits(int'(command.precision)))
            idata[4*j+:4]=plane[4*(int'(command.act_slot_sel[3*m+:3])*
                                      (256/wbits(int'(command.precision)))+j)+:4];
    end
    SingleMacro #(.USE_CLOCK_GATING(1'b0)) u_macro (
      .clock(clock), .reset(reset), .cim_ren(ren[m]), .cim_idata(idata),
      .cim_raddr(command.weight_cim_raddr), .cim_station(station[m]),
      .cim_oc_mask(command.macro_oc_mask[4*m+:4]),
      .cim_precision(command.precision), .cim_signed_en(command.signed_en),
      .cim_phase(2'(phase)), .cim_wen(memory_wen[m]),
      .cim_waddr(regular_access ? cim_row_addr : weight_waddr_i),
      .cim_wdata(regular_access ? cim_wrdata : weight_wdata_i[1024*m+:1024]),
      .cim_wmask(regular_access ? cim_wmask : 4'b0000),
      .sram_ren(regular_read && regular_macro_id==m), .sram_raddr(cim_row_addr),
      .sram_rdata(regular_read_data[1024*m+:1024]),
      .cim_odata(macro_data[72*m+:72]), .cim_odata_valid(macro_valid[m]),
      .cim_odata_oc_mask(macro_mask[4*m+:4]), .cim_odata_phase(macro_phase[2*m+:2])
    );
  end
  ClusterReduceTree u_reduce (
    .clock(clock), .reset(reset),
    .early_valid_i(in_tag.valid), .early_split_i(in_tag.cmd.reduce_split_mask),
    .early_en_i(in_tag.cmd.macro_en_mask), .early_oc_i(in_tag.cmd.macro_oc_mask),
    .valid_i(macro_tag.valid), .split_i(macro_tag.cmd.reduce_split_mask),
    .en_i(macro_tag.cmd.macro_en_mask), .oc_i(macro_tag.cmd.macro_oc_mask),
    .macro_data_i(macro_data), .tap_valid_o(tap_valid), .tap_mask_o(tap_mask),
    .tap_data_o(tap_data)
  );
  // Predict each terminal lane one cycle before its tmp capture edge.
  // Structural group size, not number of enabled Macros, selects tree depth.
  function automatic logic [31:0] terminal_lanes(input tag_t t, input int path);
    logic [31:0] mask;
    int size,g;
    mask='0;
    for(int m=0;m<8;m++) begin
      g=group_of(t.cmd.reduce_split_mask,m); size=0;
      for(int n=0;n<8;n++)
        if(group_of(t.cmd.reduce_split_mask,n)==g) size++;
      if((size<=2 ? 0 : size==4 ? 1 : 2)==path && t.valid)
        mask[4*g+:4]=t.mask[4*g+:4];
    end
    return mask;
  endfunction
  always_comb begin : collect_tmp
    capture_valid='0;
    for(int l=0;l<32;l++) begin capture_tag[l]='0; capture_data[l]=0; end
    for(int path=0;path<3;path++) if(tap_valid[path])
      for(int l=0;l<32;l++) if(tap_mask[path][l]) begin
        capture_valid[l]=1;
        capture_tag[l]=tap_tag[path];
        capture_data[l]=longint'($signed(tap_data[path][21*l+:21]));
      end
  end
  always @(posedge clock or posedge reset) begin : advance_buffer_enables
    if(reset) begin
      tmp_input_cg_en<='0;
      for(int d=0;d<OUTPUT_BUFFER_DEPTH;d++) psum_cg_en[d]<='0;
    end else begin
      tmp_input_cg_en<=terminal_lanes(early_tmp_tag[0],0) |
                       terminal_lanes(early_tmp_tag[1],1) |
                       terminal_lanes(early_tmp_tag[2],2);
      for(int d=0;d<OUTPUT_BUFFER_DEPTH;d++) psum_cg_en[d]<='0;
      for(int l=0;l<32;l++) if(capture_valid[l]) begin
        if(capture_tag[l].cmd.as_cnt>1 && capture_tag[l].cmd.os_cnt>1) begin
          if(capture_tag[l].cmd.os_cnt>1 || abits(int'(capture_tag[l].cmd.precision))>4)
            psum_cg_en[capture_tag[l].ctx][l]<=1;
        end else if(capture_tag[l].cmd.os_cnt>1 &&
                    capture_tag[l].ph==abits(int'(capture_tag[l].cmd.precision))/4-1)
          psum_cg_en[capture_tag[l].ctx][l]<=1;
      end
    end
  end
  for(genvar l=0;l<32;l++) begin : g_tmp_input
    MacroClockGate u_icg(.clock(clock),.enable(tmp_input_cg_en[l]),
                         .gated_clock(tmp_input_clock[l]));
    always @(posedge tmp_input_clock[l] or posedge reset)
      if(reset) tmp_result[l]<=0;
      else tmp_result[l]<=tmp_store_data[l];
  end
  for(genvar d=0;d<OUTPUT_BUFFER_DEPTH;d++) begin : g_psum_depth
    for(genvar l=0;l<32;l++) begin : g_lane
      MacroClockGate u_icg(.clock(clock),
        .enable(psum_depth_open[d] && psum_cg_en[d][l]),
        .gated_clock(psum_clock[d][l]));
      always @(posedge psum_clock[d][l] or posedge reset)
        if(reset) psum[d][l]<=0;
        else psum[d][l]<=arithmetic_result[l];
    end
  end
  // One fusion block and one acc block per OC, shared by all Contexts.
  // WS and OS1 AS: reduction + old tmp -> fusion -> tmp DFF.
  // OS1 bypasses Psum; WS OS>1 commits the final phase through acc.
  // OS>1 AS is unchanged: reduction -> tmp -> fusion OR acc -> Psum.
  // TIMING: WS / OS1 AS reduction and fusion may cascade before tmp;
  // OS>1 AS has one selected adder after tmp. Fusion and acc never cascade.
  // Both operands of an unused adder are isolated to zero. ASIC STA required.
  always_comb begin : arithmetic
    for(int l=0;l<32;l++) begin
      fusion_enable[l]=0; acc_enable[l]=0; psum_write[l]=0;
      fusion_a[l]=0; fusion_b[l]=0; acc_a[l]=0; acc_b[l]=0;
      if(capture_valid[l] && (capture_tag[l].cmd.as_cnt<=1 || capture_tag[l].cmd.os_cnt==1) && capture_tag[l].ph>0) begin
        fusion_enable[l]=1;
        fusion_a[l]=tmp_result[l];
        fusion_b[l]=capture_data[l] <<< (4*capture_tag[l].ph);
      end
      if(tmp_valid[l] && tmp_tag[l].cmd.as_cnt>1 && tmp_tag[l].cmd.os_cnt>1 && tmp_tag[l].ph>0) begin
        fusion_enable[l]=1;
        fusion_a[l]=psum[tmp_tag[l].ctx][l];
        fusion_b[l]=tmp_result[l] <<< (4*tmp_tag[l].ph);
      end
      fusion_result[l]=fusion_a[l]+fusion_b[l];
      tmp_store_data[l]=(capture_valid[l] && (capture_tag[l].cmd.as_cnt<=1 || capture_tag[l].cmd.os_cnt==1) &&
                         capture_tag[l].ph>0) ? fusion_result[l] : capture_data[l];
      if(tmp_valid[l]) begin
        if(tmp_tag[l].cmd.as_cnt>1 && tmp_tag[l].cmd.os_cnt>1) begin
          psum_write[l]=tmp_tag[l].cmd.os_cnt>1 || abits(int'(tmp_tag[l].cmd.precision))>4;
          acc_enable[l]=tmp_tag[l].ph==0 && tmp_tag[l].kt>0;
        end else begin
          psum_write[l]=tmp_tag[l].cmd.os_cnt>1 &&
                        tmp_tag[l].ph==abits(int'(tmp_tag[l].cmd.precision))/4-1;
          acc_enable[l]=psum_write[l] && tmp_tag[l].kt>0;
        end
        if(acc_enable[l]) begin
          acc_a[l]=psum[tmp_tag[l].ctx][l]; acc_b[l]=tmp_result[l];
        end
      end
      acc_result[l]=acc_a[l]+acc_b[l];
      arithmetic_result[l]=acc_enable[l] ? acc_result[l] :
        (tmp_valid[l] && tmp_tag[l].cmd.as_cnt>1 && tmp_tag[l].cmd.os_cnt>1 && tmp_tag[l].ph>0) ?
        fusion_result[l] : tmp_result[l];
      result_done[l]=tmp_valid[l] && tmp_tag[l].ph==abits(int'(tmp_tag[l].cmd.precision))/4-1 &&
                     tmp_tag[l].kt==int'(tmp_tag[l].cmd.os_cnt)-1;
    end
  end
  always @(posedge clock or posedge reset) begin : pipeline
    bit all_done;
    logic [31:0] captured;
    int ctx;
    if(reset) begin
      act_buffer<='0;packet_cmd<='0;packet_active<=0;act_loading<=0;act_complete<=0;
      act_slice_valid<='0;external_phase<=0;command_count<=0;
      for(int c=0;c<WGT_RADDR_BUFFER_DEPTH;c++) context_address[c]<=0;
      phase<=0; context_idx<=0; tile<=0; hold_valid<='0;
      in_tag<='0; macro_tag<='0; red1_tag<='0; red2_tag<='0;
      raw_valid<='0; raw_data<='0;
      for(int l=0;l<32;l++) raw_context[l]<=0;
      tmp_valid<='0;
      batch_active<=0; batch_input_done<=0; batch_contexts<=0;
      batch_command<='0; psum_depth_open<='0;
      tmp_only_steps=0; as_seed_steps=0; as_fusion_steps=0; as_acc_steps=0;
      ws_fusion_steps=0; ws_acc_steps=0; ws_tile_commits=0; a4_acc_steps=0;
      for(int l=0;l<32;l++) tmp_tag[l]<='0;
      for(int c=0;c<MAX_CONTEXTS;c++) begin
        result_ready[c]='0; result_mask[c]='0;
      end
    end else begin
      if(cmd_accept) begin
        if(cmd_i.os_cnt==0 || cmd_i.ws_cnt==0 || cmd_i.as_cnt==0)
          $fatal(1,"CLUSTER_COUNT_RANGE: counts must be 1..255");
        // Context tags/AS addresses and Psum entries are separate resources.
        // All OS1 modes fuse in tmp and may exceed the Psum depth.
        if(cmd_i.ws_cnt>MAX_CONTEXTS || cmd_i.as_cnt>MAX_CONTEXTS)
          $fatal(1,"CLUSTER_CONTEXT_CAPACITY: context metadata exceeded");
        if(cmd_i.as_cnt>WGT_RADDR_BUFFER_DEPTH)
          $fatal(1,"CLUSTER_CONTEXT_CAPACITY: weight address depth exceeded");
        if(cmd_i.os_cnt>1 &&
           (cmd_i.ws_cnt>OUTPUT_BUFFER_DEPTH || cmd_i.as_cnt>OUTPUT_BUFFER_DEPTH))
          $fatal(1,"CLUSTER_CONTEXT_CAPACITY: Psum depth exceeded");
        if(!packet_active) begin
          packet_cmd<=cmd_i;packet_active<=1;command_count<=1;
          context_address[0]<=cmd_i.weight_cim_raddr;
          act_buffer[0+:1024]<=act_data_i;act_slice_valid<=4'b0001;
          external_phase<=1;
          act_loading<=abits(int'(cmd_i.precision))>4;
          act_complete<=abits(int'(cmd_i.precision))==4;
        end else begin
          if(command_count>=WGT_RADDR_BUFFER_DEPTH) $fatal(1,"AS address capacity exceeded");
          context_address[command_count]<=cmd_i.weight_cim_raddr;
          command_count<=command_count+1;
        end
        if(!batch_active) begin
          batch_active<=1; batch_command<=cmd_i;
          batch_contexts<=cmd_i.ws_cnt>1 ? int'(cmd_i.ws_cnt) : int'(cmd_i.as_cnt);
          // Clear per-lane completion tracking for the whole batch; the
          // per-Context reservation masks are (re)written at final_issue.
          for(int c=0;c<MAX_CONTEXTS;c++) begin result_ready[c]='0; result_mask[c]='0; end
          for(int d=0;d<OUTPUT_BUFFER_DEPTH;d++)
            psum_depth_open[d]<=cmd_i.os_cnt>1 &&
              d<int'(cmd_i.ws_cnt>1 ? cmd_i.ws_cnt : cmd_i.as_cnt);
        end else if(cmd_i.os_cnt!=batch_command.os_cnt ||
                    cmd_i.ws_cnt!=batch_command.ws_cnt || cmd_i.as_cnt!=batch_command.as_cnt ||
                    cmd_i.precision!=batch_command.precision ||
                    cmd_i.signed_en!=batch_command.signed_en ||
                    cmd_i.reduce_split_mask!=batch_command.reduce_split_mask ||
                    cmd_i.macro_en_mask!=batch_command.macro_en_mask ||
                    cmd_i.macro_oc_mask!=batch_command.macro_oc_mask ||
                    cmd_i.act_slot_sel!=batch_command.act_slot_sel)
          $fatal(1,"Batch descriptor fields changed before completion");
      end
      if(act_loading) begin
        act_buffer[1024*external_phase+:1024]<=act_data_i;
        act_slice_valid[external_phase]<=1;
        if(external_phase==abits(int'(packet_cmd.precision))/4-1) begin
          act_loading<=0;act_complete<=1;
        end else external_phase<=external_phase+1;
      end
      for(int m=0;m<8;m++) begin
        if(memory_wen[m]) hold_valid[m]<=0;
        else if(ren[m]) begin hold_valid[m]<=1; hold_addr[m]<=command.weight_cim_raddr; end
      end
      in_tag.valid<=issue;
      if(issue) begin
        if(!act_slice_valid[phase]) $fatal(1,"Internal issue before ACT slice loaded");
        if(phase==phases-1 && (command.as_cnt<=1 || context_idx==contexts-1)) begin
          packet_active<=0;act_complete<=0;command_count<=0;act_slice_valid<='0;
        end
        if(command.precision>6 || !canonical(command.reduce_split_mask) ||
           command.os_cnt<1 || command.ws_cnt<1 || command.as_cnt<1 ||
           (command.ws_cnt>1 && command.as_cnt>1) ||
            contexts>MAX_CONTEXTS || command.as_cnt>WGT_RADDR_BUFFER_DEPTH ||
            (command.os_cnt>1 &&
            contexts>OUTPUT_BUFFER_DEPTH))
          $fatal(1,"Invalid descriptor / context capacity");
        for(int m=0;m<8;m++) if(command.macro_en_mask[m]) begin
          if(int'(command.act_slot_sel[3*m+:3])>=wbits(int'(command.precision)))
            $fatal(1,"ACT slot outside plane");
          for(int n=0;n<m;n++)
            if(command.macro_en_mask[n] &&
               group_of(command.reduce_split_mask,n)==group_of(command.reduce_split_mask,m) &&
               command.act_slot_sel[3*m+:3]==command.act_slot_sel[3*n+:3])
              $fatal(1,"Repeated K slot in one reduction group");
        end
        in_tag.cmd<=command; in_tag.ph<=phase; in_tag.ctx<=context_idx;
        in_tag.kt<=tile; in_tag.mask<=issue_mask;
        if(final_issue && context_idx==contexts-1) batch_input_done<=1;
        if(final_issue) begin
          // Reserve the Context's lanes once BEFORE final-phase results can
          // take any short path.
          result_mask[context_idx]<=issue_mask;
        end
        if(command.as_cnt>1 && command.os_cnt>1) begin
          if(context_idx==contexts-1) begin
            context_idx<=0;
            if(phase==phases-1) begin phase<=0; tile<=final_issue ? 0 : tile+1; end
            else phase<=phase+1;
          end else context_idx<=context_idx+1;
        end else begin
          if(phase==phases-1) begin
            phase<=0;
            if(context_idx==contexts-1) begin context_idx<=0; tile<=final_issue ? 0 : tile+1; end
            else context_idx<=context_idx+1;
          end else phase<=phase+1;
        end
      end
      macro_tag<=in_tag;
      red1_tag<=macro_tag;
      if(macro_tag.valid) begin
        for(int m=0;m<8;m++) begin
          if(macro_valid[m] !== (macro_tag.cmd.macro_en_mask[m] &&
                              (|macro_tag.cmd.macro_oc_mask[4*m+:4])))
            $fatal(1,"Macro valid not aligned with 1T result");
          if(macro_valid[m] && (macro_phase[2*m+:2]!==2'(macro_tag.ph) ||
              macro_mask[4*m+:4]!==macro_tag.cmd.macro_oc_mask[4*m+:4]))
            $fatal(1,"Macro metadata mismatch");
        end
      end
      red2_tag<=red1_tag;
      raw_valid<='0;
      // Consume the PREVIOUS tmp DFF contents. NBA state writes preserve
      // consecutive-phase feedback and prevent zero-time procedural cascades.
      for(int l=0;l<32;l++) if(capture_valid[l] && capture_tag[l].ph>0 &&
        (capture_tag[l].cmd.as_cnt<=1 || capture_tag[l].cmd.os_cnt==1)) begin
        if(capture_tag[l].cmd.as_cnt>1) as_fusion_steps++;
        else ws_fusion_steps++;
      end
      for(int l=0;l<32;l++) if(tmp_valid[l]) begin
        if(tmp_tag[l].cmd.as_cnt>1) begin
          if(tmp_tag[l].cmd.os_cnt==1) tmp_only_steps++;
          if(tmp_tag[l].cmd.os_cnt>1 && tmp_tag[l].ph>0) as_fusion_steps++;
          else if(acc_enable[l]) as_acc_steps++;
          else if(psum_write[l]) as_seed_steps++;
        end else begin
          if(tmp_tag[l].cmd.os_cnt==1) tmp_only_steps++;
          if(psum_write[l]) ws_tile_commits++;
          if(acc_enable[l]) ws_acc_steps++;
        end
        if(acc_enable[l] && abits(int'(tmp_tag[l].cmd.precision))==4) a4_acc_steps++;
        if(result_done[l]) begin
          if(arithmetic_result[l] < -64'sd2147483648 || arithmetic_result[l]>64'sd2147483647 ||
             (!tmp_tag[l].cmd.signed_en && arithmetic_result[l]<0))
            $fatal(1,"Psum signed32 overflow (policy TBD)");
          ctx=tmp_tag[l].ctx;
          if(!result_mask[ctx][l] || result_ready[ctx][l])
            $fatal(1,"Unreserved/duplicate final lane write");
          result_ready[ctx][l]=1;
          // Publish this lane immediately: its out_valid_o bit pulses for
          // one cycle, the lane value holds until the lane publishes again.
          raw_valid[l]<=1;
          raw_data[32*l+:32]<=32'(arithmetic_result[l]);
          raw_context[l]<=ctx;
        end
      end
      // Independent tree taps capture into per-channel tmp DFFs. There is
      // no additional root-only DFF or full-depth result alignment pipeline.
      captured='0;
      tmp_valid<='0;
      for(int path=0;path<3;path++) if(tap_valid[path]) begin
        if(!tap_tag[path].valid || ((tap_mask[path]&~tap_tag[path].mask)!=0))
          $fatal(1,"Terminal tap metadata mismatch path=%0d",path);
        for(int l=0;l<32;l++) if(tap_mask[path][l]) begin
          if(captured[l]) $fatal(1,"Concurrent tree taps target same channel");
          captured[l]=1;
          tmp_valid[l]<=1;
          tmp_tag[l]<=tap_tag[path];
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
      all_done=batch_input_done;
      for(int c=0;c<batch_contexts;c++)
        if(result_ready[c]!=result_mask[c]) all_done=0;
      if(batch_active && all_done) begin
        batch_active<=0; batch_input_done<=0; psum_depth_open<='0;
      end
    end
  end
endmodule
