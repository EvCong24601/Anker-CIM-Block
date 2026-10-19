`timescale 1ns/1ps
// Simulation reference Cluster. Existing ports carry RAW Psum, no requant.
module cluster_dut_adapter #(
  parameter int OUTPUT_BUFFER_DEPTH = 4,
  parameter int MAX_CONTEXTS = 16
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
    logic [31:0] mask;
  } tag_t;
  tag_t in_tag, macro_tag, red1_tag, red2_tag;
  longint signed red1 [0:31][0:3], red2 [0:31];
  longint signed fusion [0:MAX_CONTEXTS-1][0:31];
  longint signed psum [0:MAX_CONTEXTS-1][0:31];
  // OUTPUT_BUFFER_DEPTH entries PER channel. A masked vector retires together.
  logic [31:0] output_buffer [0:31][0:OUTPUT_BUFFER_DEPTH-1];
  logic [31:0] output_mask [0:OUTPUT_BUFFER_DEPTH-1];
  int output_context [0:OUTPUT_BUFFER_DEPTH-1]; // internal verification tag
  int rd_ptr, wr_ptr, occupancy, reserved;
  wire pop = out_valid_o && out_ready_i;
  // Internal observation only; no new external signal.
  logic raw_psum_valid;
  int raw_context;
  logic [1023:0] raw_data;
  logic [31:0] raw_mask;
  initial begin
    if(OUTPUT_BUFFER_DEPTH<1 || MAX_CONTEXTS<1)
      $fatal(1,"Buffer depth / context capacity must be >= 1");
  end
  always_comb begin
    command=have_cmd ? queued_cmd : cmd_i;
    phases=abits(int'(command.precision))/4;
    contexts=command.ws_cnt!=0 ? int'(command.ws_cnt) :
             command.as_cnt!=0 ? int'(command.as_cnt) : 1;
    need_plane=command.as_cnt==0 || context_idx==0;
    release_plane=command.as_cnt==0 || context_idx==contexts-1;
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
    issue=!reset && (have_cmd || cmd_valid_i) &&
          (have_act || (need_plane && act_valid_i)) && credit_ok;
    ren=active & {8{issue}};
    for(int m=0;m<8;m++)
      station[m]=!hold_valid[m] || hold_addr[m]!=command.weight_cim_raddr;
  end
  assign cmd_ready_o=!reset && !have_cmd && credit_ok;
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
  always @(posedge clock or posedge reset) begin : pipeline
    longint signed contribution, full_tile, next_psum;
    bit push;
    int r;
    if(reset) begin
      have_cmd<=0; have_act<=0; queued_cmd<='0; held_plane<='0;
      phase<=0; context_idx<=0; tile<=0; hold_valid<='0;
      in_tag<='0; macro_tag<='0; red1_tag<='0; red2_tag<='0;
      rd_ptr<=0; wr_ptr<=0; occupancy<=0; reserved<=0;
      raw_psum_valid<=0; raw_context<=0; raw_data<='0; raw_mask<='0;
      for(int c=0;c<MAX_CONTEXTS;c++) for(int l=0;l<32;l++) begin
        fusion[c][l]=0; psum[c][l]=0;
      end
    end else begin
      if(cmd_valid_i && cmd_ready_o) begin queued_cmd<=cmd_i; have_cmd<=1; end
      if(act_valid_i && act_ready_o) begin held_plane<=act_data_i; have_act<=1; end
      for(int m=0;m<8;m++) begin
        if(weight_wen_i[m]) hold_valid[m]<=0;
        else if(ren[m]) begin hold_valid[m]<=1; hold_addr[m]<=command.weight_cim_raddr; end
      end
      in_tag.valid<=issue;
      if(issue) begin
        if(command.precision>6 || !canonical(command.reduce_split_mask) ||
           command.os_cnt==0 || (command.ws_cnt!=0 && command.as_cnt!=0) ||
           contexts>MAX_CONTEXTS || issue_mask==0)
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
        have_cmd<=0;
        if(release_plane) have_act<=0;
        if(command.as_cnt!=0) begin
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
        for(int l=0;l<32;l++) for(int pair=0;pair<4;pair++) begin
          contribution=0;
          for(int j=0;j<2;j++) begin
            r=2*pair+j;
            if(macro_tag.cmd.macro_en_mask[r] && macro_tag.cmd.macro_oc_mask[4*r+l%4] &&
               group_of(macro_tag.cmd.reduce_split_mask,r)==l/4)
              contribution+=$signed(macro_data[72*r+18*(l%4)+:18]);
          end
          red1[l][pair]<=contribution;
        end
      end
      red2_tag<=red1_tag;
      if(red1_tag.valid) for(int l=0;l<32;l++)
        red2[l]<=red1[l][0]+red1[l][1]+red1[l][2]+red1[l][3];
      raw_psum_valid<=0;
      push=red2_tag.valid && red2_tag.ph==abits(int'(red2_tag.cmd.precision))/4-1 &&
                           red2_tag.kt==int'(red2_tag.cmd.os_cnt)-1;
      if(red2_tag.valid) begin
        for(int l=0;l<32;l++) begin
          full_tile=(red2_tag.ph==0 ? 0 : fusion[red2_tag.ctx][l]) +
                    (red2[l] <<< (4*red2_tag.ph));
          fusion[red2_tag.ctx][l]=full_tile;
          if(red2_tag.ph==abits(int'(red2_tag.cmd.precision))/4-1) begin
            // Update this Context's Psum only after the complete Tile is fused.
            next_psum=(red2_tag.kt==0 ? 0 : psum[red2_tag.ctx][l])+full_tile;
            if(next_psum < -64'sd2147483648 || next_psum>64'sd2147483647 ||
               (!red2_tag.cmd.signed_en && next_psum<0))
              $fatal(1,"Psum signed32 overflow (policy TBD)");
            psum[red2_tag.ctx][l]=next_psum;
            if(push) begin
              output_buffer[l][wr_ptr]<=32'(next_psum);
              raw_data[32*l+:32]<=32'(next_psum);
            end
          end
        end
      end
      if(push) begin
        if(occupancy==OUTPUT_BUFFER_DEPTH && !pop) $fatal(1,"Output FIFO overflow");
        output_mask[wr_ptr]<=red2_tag.mask; output_context[wr_ptr]<=red2_tag.ctx;
        wr_ptr<=(wr_ptr+1)%OUTPUT_BUFFER_DEPTH;
        raw_psum_valid<=1; raw_context<=red2_tag.ctx; raw_mask<=red2_tag.mask;
      end
      if(pop) rd_ptr<=(rd_ptr+1)%OUTPUT_BUFFER_DEPTH;
      occupancy<=occupancy+int'(push)-int'(pop);
      reserved<=reserved+int'(issue && final_issue)-int'(pop);
      if(occupancy<0 || reserved<occupancy || reserved>OUTPUT_BUFFER_DEPTH)
        $fatal(1,"Output FIFO credit accounting error");
    end
  end
endmodule
