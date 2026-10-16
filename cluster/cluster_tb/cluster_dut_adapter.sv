`timescale 1ns/1ps
// Replace this module's body with the real Cluster instantiation when available.
// This default harness exercises eight EXISTING SingleMacro RTL instances.
// Its serial scheduler is a functional reference, not a production Cluster RTL.
module cluster_dut_adapter (
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
  typedef enum logic [1:0] {LOAD, ISSUE, COLLECT, OUTPUT_WAIT} state_t;
  state_t state;
  cluster_ctrl_t command;
  logic [1023:0] plane;
  logic have_cmd, have_act;
  int phase, tile;
  logic [7:0] ren, active;
  wire [575:0] macro_data;
  wire [7:0] macro_valid;
  wire [31:0] macro_mask;
  wire [15:0] macro_phase;
  longint signed accum [0:31];
  assign cmd_ready_o = state==LOAD && !have_cmd;
  assign act_ready_o = state==LOAD && !have_act;
  always_comb begin
    for (int m=0;m<8;m++) begin
      active[m]=command.macro_en_mask[m] && (|command.macro_oc_mask[4*m+:4]);
      ren[m]=(state==ISSUE) && active[m];
    end
  end
  for (genvar m=0;m<8;m++) begin: g_macro
    logic [511:0] idata;
    always_comb begin
      idata='0;
      for (int j=0;j<128;j++)
        if (j<256/wbits(int'(command.precision)))
          idata[4*j+:4]=plane[4*(int'(command.act_slot_sel[3*m+:3])*
                                      (256/wbits(int'(command.precision)))+j)+:4];
    end
    SingleMacro #(.USE_CLOCK_GATING(1'b0)) u_macro (
      .clock(clock), .reset(reset), .cim_ren(ren[m]), .cim_idata(idata),
      .cim_raddr(command.weight_cim_raddr), .cim_station(1'b1),
      .cim_oc_mask(command.macro_oc_mask[4*m+:4]),
      .cim_precision(command.precision), .cim_signed_en(command.signed_en),
      .cim_phase(2'(phase)), .cim_wen(weight_wen_i[m]),
      .cim_waddr(weight_waddr_i), .cim_wdata(weight_wdata_i[1024*m+:1024]),
      .cim_odata(macro_data[72*m+:72]), .cim_odata_valid(macro_valid[m]),
      .cim_odata_oc_mask(macro_mask[4*m+:4]),
      .cim_odata_phase(macro_phase[2*m+:2])
    );
  end
  always @(posedge clock or posedge reset) begin : scheduler
    longint signed contribution, next_sum;
    int lane;
    if (reset) begin
      state<=LOAD; command<='0; plane<='0; have_cmd<=0; have_act<=0;
      phase<=0; tile<=0; out_valid_o<=0;
      psum_data_o<='0; psum_lane_valid_o<='0;
      for (int l=0;l<32;l++) accum[l]=0;
    end else begin
      case(state)
        LOAD: begin
          if(cmd_valid_i && cmd_ready_o) begin command<=cmd_i; have_cmd<=1; end
          if(act_valid_i && act_ready_o) begin plane<=act_data_i; have_act<=1; end
          if(have_cmd && have_act) begin
            if(command.ws_cnt!=0 || command.as_cnt!=0 || command.os_cnt==0)
              $fatal(1,"Default adapter supports OS only, os_cnt >= 1");
            state<=ISSUE;
          end
        end
        ISSUE: state<=COLLECT;
        COLLECT: if ((macro_valid & active)==active) begin
          for(int m=0;m<8;m++) if(active[m]) begin
            if(macro_phase[2*m+:2]!==2'(phase) ||
               macro_mask[4*m+:4]!==command.macro_oc_mask[4*m+:4])
              $fatal(1,"Macro result metadata mismatch");
          end
          for(int g=0;g<8;g++) for(int c=0;c<4;c++) begin
            lane=4*g+c; contribution=0;
            for(int m=0;m<8;m++)
              if(active[m] && command.macro_oc_mask[4*m+c] &&
                 group_of(command.reduce_split_mask,m)==g) begin
                contribution += $signed(macro_data[72*m+18*c+:18]);
                psum_lane_valid_o[lane]<=1;
              end
            next_sum=accum[lane]+(contribution<<<(4*phase));
            accum[lane]=next_sum;
            if(phase==abits(int'(command.precision))/4-1 &&
               tile==int'(command.os_cnt)-1) begin
              if(next_sum < -64'sd2147483648 || next_sum > 64'sd2147483647)
                $fatal(1,"Psum overflow; overflow policy is not frozen");
              psum_data_o[32*lane+:32]<=32'(next_sum);
            end
          end
          have_cmd<=0; have_act<=0;
          if(phase==abits(int'(command.precision))/4-1) begin
            phase<=0;
            if(tile==int'(command.os_cnt)-1) begin
              out_valid_o<=1; state<=OUTPUT_WAIT;
            end else begin tile<=tile+1; state<=LOAD; end
          end else begin phase<=phase+1; state<=LOAD; end
        end
        OUTPUT_WAIT: if(out_valid_o && out_ready_i) begin
          out_valid_o<=0; state<=LOAD; tile<=0; phase<=0;
          psum_lane_valid_o<='0;
          for(int l=0;l<32;l++) accum[l]=0;
        end
        default: $fatal(1,"Invalid adapter state");
      endcase
    end
  end
endmodule
