`timescale 1ns/1ps
// Simulation reference Cluster. Existing ports carry RAW Psum, no requant.
module cluster_dut_adapter #(
  parameter int OUTPUT_BUFFER_DEPTH = 4,
  parameter int MAX_CONTEXTS = 16,
  parameter int PSUM_BUFFER_DEPTH = MAX_CONTEXTS
) (
  input logic clock, reset,
  input cluster_tb_pkg::cluster_ctrl_t cmd_i,
  input logic cmd_valid_i,
  output wire cmd_ready_o,
  input logic [1023:0] act_data_i,
  input logic act_valid_i,
  output wire act_ready_o,
  input logic [7:0] weight_wen_i,
  input logic [7:0] weight_waddr_i,
  input logic [8191:0] weight_wdata_i,
  output logic [1023:0] psum_data_o,
  output logic [31:0] psum_lane_valid_o,
  output logic out_valid_o,
  input logic out_ready_i
);
  import cluster_tb_pkg::*;
  cluster_ctrl_t queued_cmd, command;
  logic have_cmd, have_act;
  logic [1023:0] held_plane, plane;
  int phase, context_idx, tile, phases, contexts;
  logic need_plane, release_plane, issue, credit_ok, final_issue;
  logic [31:0] issue_mask;
  logic [7:0] active, ren, station, hold_valid;
  logic [7:0] hold_addr [0:7];
  wire [575:0] macro_data;
  wire [7:0] macro_valid;
  wire [31:0] macro_mask;
  wire [15:0] macro_phase;
  typedef struct packed {
    logic valid;
    cluster_ctrl_t cmd;
    int ph, ctx, kt;
    int slot;
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
  logic [31:0] tmp_valid;
  tag_t tmp_tag[0:31];
  longint signed tmp_result[0:31];
  // WS reuses depth 0 for adjacent phases. AS with os=1 needs one
  // partial-fusion entry per interleaved Context; it NEVER writes psum.
  longint signed tmp_buffer [0:MAX_CONTEXTS-1][0:31];
  longint signed psum [0:PSUM_BUFFER_DEPTH-1][0:31];
  logic [PSUM_BUFFER_DEPTH-1:0] psum_depth_open;
  logic [MAX_CONTEXTS-1:0] tmp_depth_open;
  logic batch_active, batch_input_done;
  int batch_contexts;
  cluster_ctrl_t batch_command;
  // Explicit advance ICG enables: registered at tmp capture, consumed by
  // the arithmetic-state DFFs on the next edge. High address depths are
  // disabled for the WHOLE batch, independently of per-cycle write requests.
  logic [31:0] tmp_input_cg_en;
  logic [31:0] psum_cg_en[0:PSUM_BUFFER_DEPTH-1];
  logic [31:0] tmp_state_cg_en[0:MAX_CONTEXTS-1];
  wire [31:0] tmp_input_clock;
  wire [31:0] psum_clock[0:PSUM_BUFFER_DEPTH-1];
  wire [31:0] tmp_state_clock[0:MAX_CONTEXTS-1];
  logic [31:0] capture_valid;
  tag_t capture_tag[0:31];
  longint signed capture_data[0:31];
  longint signed fusion_a[0:31], fusion_b[0:31], fusion_result[0:31];
  longint signed acc_a[0:31], acc_b[0:31], acc_result[0:31];
  longint signed phase_result[0:31], arithmetic_result[0:31];
  logic [31:0] fusion_enable, acc_enable, psum_write, tmp_write, result_done;
  int tmp_index[0:31];
  // Internal operation coverage; no extra external interface.
  int tmp_only_steps, as_seed_steps, as_fusion_steps, as_acc_steps;
  int ws_fusion_steps, ws_acc_steps, ws_serial_steps, a4_acc_steps;
  // OUTPUT_BUFFER_DEPTH entries PER channel. A masked vector retires together.
  logic [31:0] output_buffer [0:31][0:OUTPUT_BUFFER_DEPTH-1];
  logic [31:0] output_mask [0:OUTPUT_BUFFER_DEPTH-1];
  int output_context [0:OUTPUT_BUFFER_DEPTH-1]; // internal verification tag
  logic [31:0] ready_mask[0:OUTPUT_BUFFER_DEPTH-1];
  logic pending_slot[0:OUTPUT_BUFFER_DEPTH-1];
  int rd_ptr, wr_ptr, commit_ptr, occupancy, reserved;
  wire pop = out_valid_o && out_ready_i;
  // Internal observation only; no new external signal.
  logic raw_psum_valid;
  int raw_context;
  logic [1023:0] raw_data;
  logic [31:0] raw_mask;
  initial begin
    if(OUTPUT_BUFFER_DEPTH<1 || MAX_CONTEXTS<1 || PSUM_BUFFER_DEPTH<1)
      $fatal(1,"Buffer depth / context capacity must be >= 1");
  end
  always_comb begin
    command=have_cmd ? queued_cmd : cmd_i;
    phases=abits(int'(command.precision))/4;
    contexts=command.ws_cnt>1 ? int'(command.ws_cnt) : int'(command.as_cnt);
    need_plane=command.as_cnt<=1 || context_idx==0;
    release_plane=command.as_cnt<=1 || context_idx==contexts-1;
    plane=have_act ? held_plane : act_data_i;
    issue_mask='0; active='0;
    for(int m=0;m<8;m++) begin
      active[m]=command.macro_en_mask[m] && (|command.macro_oc_mask[4*m+:4]);
      for(int c=0;c<4;c++)
        if(command.macro_en_mask[m] && command.macro_oc_mask[4*m+c])
          issue_mask[4*group_of(command.reduce_split_mask,m)+c]=1;
    end
    final_issue=phase==phases-1 && tile==int'(command.os_cnt)-1;
    credit_ok=!final_issue || reserved<OUTPUT_BUFFER_DEPTH || pop;
    issue=!reset && !batch_input_done && (have_cmd || cmd_valid_i) &&
          (have_act || (need_plane && act_valid_i)) && credit_ok;
    ren=active & {8{issue}};
    for(int m=0;m<8;m++)
      station[m]=!hold_valid[m] || hold_addr[m]!=command.weight_cim_raddr;
  end
  assign cmd_ready_o=!reset && !batch_input_done && !have_cmd && credit_ok;
  assign act_ready_o=!reset && !have_act && need_plane;
  always_comb begin
    out_valid_o=occupancy!=0;
    psum_lane_valid_o=out_valid_o ? output_mask[rd_ptr] : '0;
    psum_data_o='0;
    if(out_valid_o)
      for(int l=0;l<32;l++) psum_data_o[32*l+:32]=output_buffer[l][rd_ptr];
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
      .cim_phase(2'(phase)), .cim_wen(weight_wen_i[m]),
      .cim_waddr(weight_waddr_i), .cim_wdata(weight_wdata_i[1024*m+:1024]),
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
      for(int d=0;d<PSUM_BUFFER_DEPTH;d++) psum_cg_en[d]<='0;
      for(int d=0;d<MAX_CONTEXTS;d++) tmp_state_cg_en[d]<='0;
    end else begin
      tmp_input_cg_en<=terminal_lanes(early_tmp_tag[0],0) |
                       terminal_lanes(early_tmp_tag[1],1) |
                       terminal_lanes(early_tmp_tag[2],2);
      for(int d=0;d<PSUM_BUFFER_DEPTH;d++) psum_cg_en[d]<='0;
      for(int d=0;d<MAX_CONTEXTS;d++) tmp_state_cg_en[d]<='0;
      for(int l=0;l<32;l++) if(capture_valid[l]) begin
        if(capture_tag[l].cmd.os_cnt==1) begin
          if(abits(int'(capture_tag[l].cmd.precision))>4)
            tmp_state_cg_en[capture_tag[l].cmd.as_cnt>1 ? capture_tag[l].ctx : 0][l]<=1;
        end else if(capture_tag[l].cmd.as_cnt>1) begin
          psum_cg_en[capture_tag[l].ctx][l]<=1;
        end else begin
          if(abits(int'(capture_tag[l].cmd.precision))>4) tmp_state_cg_en[0][l]<=1;
          if(capture_tag[l].ph==abits(int'(capture_tag[l].cmd.precision))/4-1)
            psum_cg_en[capture_tag[l].ctx][l]<=1;
        end
      end
    end
  end
  for(genvar l=0;l<32;l++) begin : g_tmp_input
    MacroClockGate u_icg(.clock(clock),.enable(tmp_input_cg_en[l]),
                         .gated_clock(tmp_input_clock[l]));
    always @(posedge tmp_input_clock[l] or posedge reset)
      if(reset) tmp_result[l]<=0;
      else tmp_result[l]<=capture_data[l];
  end
  for(genvar d=0;d<MAX_CONTEXTS;d++) begin : g_tmp_depth
    for(genvar l=0;l<32;l++) begin : g_lane
      MacroClockGate u_icg(.clock(clock),
        .enable(tmp_depth_open[d] && tmp_state_cg_en[d][l]),
        .gated_clock(tmp_state_clock[d][l]));
      always @(posedge tmp_state_clock[d][l] or posedge reset)
        if(reset) tmp_buffer[d][l]<=0;
        else tmp_buffer[d][l]<=phase_result[l];
    end
  end
  for(genvar d=0;d<PSUM_BUFFER_DEPTH;d++) begin : g_psum_depth
    for(genvar l=0;l<32;l++) begin : g_lane
      MacroClockGate u_icg(.clock(clock),
        .enable(psum_depth_open[d] && psum_cg_en[d][l]),
        .gated_clock(psum_clock[d][l]));
      always @(posedge psum_clock[d][l] or posedge reset)
        if(reset) psum[d][l]<=0;
        else psum[d][l]<=arithmetic_result[l];
    end
  end
  // One bit-fusion block and one Psum acc block per parallel channel
  // (channel = 4*group+OC). Contexts share these combinational blocks.
  // Both inputs of an unused adder are explicitly isolated to zero.
  always_comb begin : arithmetic
    for(int l=0;l<32;l++) begin
      tmp_index[l]=tmp_tag[l].cmd.as_cnt>1 ? tmp_tag[l].ctx : 0;
      fusion_enable[l]=0; acc_enable[l]=0;
      psum_write[l]=0; tmp_write[l]=0; result_done[l]=0;
      fusion_a[l]=0; fusion_b[l]=0;
      acc_a[l]=0; acc_b[l]=0;
      if(tmp_valid[l]) begin
        if(tmp_tag[l].cmd.os_cnt==1) begin
          // os=1: fusion stays entirely in tmp storage, including AS.
          tmp_write[l]=abits(int'(tmp_tag[l].cmd.precision))>4;
          fusion_enable[l]=tmp_tag[l].ph>0;
          if(fusion_enable[l]) begin
            fusion_a[l]=tmp_buffer[tmp_index[l]][l];
            fusion_b[l]=tmp_result[l] <<< (4*tmp_tag[l].ph);
          end
        end else if(tmp_tag[l].cmd.as_cnt>1) begin
          // AS: seed on T0/A0; acc on later Tile A0; fusion on A1..A3.
          // History stays in psum[ctx], so fusion and acc NEVER cascade.
          psum_write[l]=1;
          fusion_enable[l]=tmp_tag[l].ph>0;
          acc_enable[l]=tmp_tag[l].ph==0 && tmp_tag[l].kt>0;
          if(fusion_enable[l]) begin
            fusion_a[l]=psum[tmp_tag[l].ctx][l];
            fusion_b[l]=tmp_result[l] <<< (4*tmp_tag[l].ph);
          end
        end else begin
          // WS / single Context: finish current Tile fusion in tmp first.
          tmp_write[l]=abits(int'(tmp_tag[l].cmd.precision))>4;
          fusion_enable[l]=tmp_tag[l].ph>0;
          if(fusion_enable[l]) begin
            fusion_a[l]=tmp_buffer[0][l];
            fusion_b[l]=tmp_result[l] <<< (4*tmp_tag[l].ph);
          end
          psum_write[l]=tmp_tag[l].ph==abits(int'(tmp_tag[l].cmd.precision))/4-1;
          acc_enable[l]=psum_write[l] && tmp_tag[l].kt>0;
        end
      end
      fusion_result[l]=fusion_a[l]+fusion_b[l];
      phase_result[l]=fusion_enable[l] ? fusion_result[l] : tmp_result[l];
      if(acc_enable[l]) begin
        acc_a[l]=psum[tmp_tag[l].ctx][l];
        acc_b[l]=phase_result[l];
      end
      acc_result[l]=acc_a[l]+acc_b[l];
      arithmetic_result[l]=acc_enable[l] ? acc_result[l] : phase_result[l];
      result_done[l]=tmp_valid[l] &&
        tmp_tag[l].ph==abits(int'(tmp_tag[l].cmd.precision))/4-1 &&
        tmp_tag[l].kt==int'(tmp_tag[l].cmd.os_cnt)-1;
      // TIMING COST: WS / single Context, A8/A16, later Tile final phase:
      // tmp state + shifted tmp_result -> fusion adder -> OS acc adder
      // -> psum storage. No DFF between the two adders; STA must check it.
      // AS uses only ONE of these adders per phase. Operand isolation saves
      // switching while disabled; it does not shorten the active WS path.
    end
  end
  always @(posedge clock or posedge reset) begin : pipeline
    bit push;
    logic [31:0] captured;
    int slot;
    if(reset) begin
      have_cmd<=0; have_act<=0; queued_cmd<='0; held_plane<='0;
      phase<=0; context_idx<=0; tile<=0; hold_valid<='0;
      in_tag<='0; macro_tag<='0; red1_tag<='0; red2_tag<='0;
      rd_ptr<=0; wr_ptr<=0; commit_ptr<=0; occupancy<=0; reserved<=0;
      raw_psum_valid<=0; raw_context<=0; raw_data<='0; raw_mask<='0;
      tmp_valid<='0;
      batch_active<=0; batch_input_done<=0; batch_contexts<=0;
      batch_command<='0; psum_depth_open<='0; tmp_depth_open<='0;
      tmp_only_steps=0; as_seed_steps=0; as_fusion_steps=0; as_acc_steps=0;
      ws_fusion_steps=0; ws_acc_steps=0; ws_serial_steps=0; a4_acc_steps=0;
      for(int l=0;l<32;l++) tmp_tag[l]<='0;
      for(int s=0;s<OUTPUT_BUFFER_DEPTH;s++) begin
        ready_mask[s]='0; pending_slot[s]=0;
        output_mask[s]='0; output_context[s]=0;
      end
    end else begin
      if(cmd_valid_i && cmd_ready_o) begin
        queued_cmd<=cmd_i; have_cmd<=1;
        if(!batch_active) begin
          batch_active<=1; batch_command<=cmd_i;
          batch_contexts<=cmd_i.ws_cnt>1 ? int'(cmd_i.ws_cnt) : int'(cmd_i.as_cnt);
          for(int d=0;d<PSUM_BUFFER_DEPTH;d++)
            psum_depth_open[d]<=cmd_i.os_cnt>1 && d<int'(cmd_i.ws_cnt>1 ? cmd_i.ws_cnt : cmd_i.as_cnt);
          for(int d=0;d<MAX_CONTEXTS;d++)
            tmp_depth_open[d]<=abits(int'(cmd_i.precision))>4 &&
              (cmd_i.os_cnt==1 ? d<(cmd_i.as_cnt>1 ? int'(cmd_i.as_cnt) : 1) :
                               (cmd_i.as_cnt<=1 && d==0));
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
      if(act_valid_i && act_ready_o) begin held_plane<=act_data_i; have_act<=1; end
      for(int m=0;m<8;m++) begin
        if(weight_wen_i[m]) hold_valid[m]<=0;
        else if(ren[m]) begin hold_valid[m]<=1; hold_addr[m]<=command.weight_cim_raddr; end
      end
      in_tag.valid<=issue;
      if(issue) begin
        if(command.precision>6 || !canonical(command.reduce_split_mask) ||
           command.os_cnt<1 || command.ws_cnt<1 || command.as_cnt<1 ||
           (command.ws_cnt>1 && command.as_cnt>1) ||
           contexts>MAX_CONTEXTS || contexts>PSUM_BUFFER_DEPTH || issue_mask==0)
          $fatal(1,"Invalid descriptor / context capacity / empty output");
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
        in_tag.slot<=wr_ptr;
        if(final_issue && context_idx==contexts-1) batch_input_done<=1;
        if(final_issue) begin
          // Allocate once BEFORE final-phase results can take any short path.
          pending_slot[wr_ptr]=1; ready_mask[wr_ptr]='0;
          output_mask[wr_ptr]<=issue_mask; output_context[wr_ptr]<=context_idx;
          wr_ptr<=(wr_ptr+1)%OUTPUT_BUFFER_DEPTH;
        end
        have_cmd<=0;
        if(release_plane) have_act<=0;
        if(command.as_cnt>1) begin
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
      raw_psum_valid<=0;
      // Consume the PREVIOUS tmp DFF contents. NBA state writes preserve
      // consecutive-phase feedback and prevent zero-time procedural cascades.
      for(int l=0;l<32;l++) if(tmp_valid[l]) begin
        if(tmp_tag[l].cmd.os_cnt==1) tmp_only_steps++;
        else if(tmp_tag[l].cmd.as_cnt>1) begin
          if(fusion_enable[l]) as_fusion_steps++;
          else if(acc_enable[l]) as_acc_steps++;
          else as_seed_steps++;
        end else begin
          if(fusion_enable[l]) ws_fusion_steps++;
          if(acc_enable[l]) ws_acc_steps++;
          if(fusion_enable[l] && acc_enable[l]) ws_serial_steps++;
        end
        if(acc_enable[l] && abits(int'(tmp_tag[l].cmd.precision))==4) a4_acc_steps++;
        if(result_done[l]) begin
          if(arithmetic_result[l] < -64'sd2147483648 || arithmetic_result[l]>64'sd2147483647 ||
             (!tmp_tag[l].cmd.signed_en && arithmetic_result[l]<0))
            $fatal(1,"Psum signed32 overflow (policy TBD)");
          slot=tmp_tag[l].slot;
          if(!pending_slot[slot] || ready_mask[slot][l])
            $fatal(1,"Unreserved/duplicate final lane write");
          output_buffer[l][slot]=32'(arithmetic_result[l]);
          ready_mask[slot][l]=1;
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
      // A mixed tree writes shallow groups early. Publish only when every
      // required channel in this Context's reserved slot has actually arrived.
      push=pending_slot[commit_ptr] && ready_mask[commit_ptr]==output_mask[commit_ptr] &&
           !(issue && final_issue && commit_ptr==wr_ptr);
      if(push) begin
        if(occupancy==OUTPUT_BUFFER_DEPTH && !pop) $fatal(1,"Output FIFO overflow");
        pending_slot[commit_ptr]=0;
        raw_psum_valid<=1; raw_context<=output_context[commit_ptr]; raw_mask<=output_mask[commit_ptr];
        for(int l=0;l<32;l++) raw_data[32*l+:32]<=output_mask[commit_ptr][l] ? output_buffer[l][commit_ptr] : '0;
        commit_ptr<=(commit_ptr+1)%OUTPUT_BUFFER_DEPTH;
        if(output_context[commit_ptr]==batch_contexts-1) begin
          batch_active<=0; batch_input_done<=0;
          psum_depth_open<='0; tmp_depth_open<='0;
        end
      end
      if(pop) rd_ptr<=(rd_ptr+1)%OUTPUT_BUFFER_DEPTH;
      occupancy<=occupancy+int'(push)-int'(pop);
      reserved<=reserved+int'(issue && final_issue)-int'(pop);
      if(occupancy<0 || reserved<occupancy || reserved>OUTPUT_BUFFER_DEPTH)
        $fatal(1,"Output FIFO credit accounting error");
    end
  end
endmodule
