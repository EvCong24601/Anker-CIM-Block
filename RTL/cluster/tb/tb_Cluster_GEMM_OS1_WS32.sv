`timescale 1ns/1ps
// One physical Cluster computes four sequential N4 tiles for X[32,128]*W[128,16].
// Eight Macros reduce K256 with a zero-padded K tail; X is replayed four times.
module tb_Cluster_GEMM_OS1_WS32;
  import cluster_pkg::*;
  localparam int M=32,K=128,N=16,CLUSTERS=1,N_TILES=4;
  localparam logic [7:0] WEIGHT_ADDR=8'h40;
  logic clock=0,reset=1;
  always #5 clock=~clock;
  cluster_ctrl_t cmd_i='0;
  logic cmd_valid_i=0;
  wire [CLUSTERS-1:0] cmd_ready_o;
  logic [1023:0] act_data_i='0;
  requant_cfg_t requant_cfg_i[CLUSTERS];
  logic cim_cs_en=0,cim_wr_en=0,cim_macro_group=0;
  logic [1:0] cim_bank_sel=0;
  logic [7:0] cim_row_addr=WEIGHT_ADDR;
  logic [3:0] cim_wmask=0;
  logic [1023:0] cim_wrdata[CLUSTERS];
  wire [1023:0] cim_rd_data[CLUSTERS],psum_data_o[CLUSTERS];
  wire [255:0] requant_data_o[CLUSTERS];
  wire [31:0] out_valid_o[CLUSTERS],requant_valid_o[CLUSTERS];
  wire [CLUSTERS-1:0] issue,batch_active;
  wire [CLUSTERS-1:0] psum_activity;
  wire [7:0] ren[CLUSTERS],station[CLUSTERS];
  wire [1023:0] issue_plane[CLUSTERS];
  wire [7:0] issue_address[CLUSTERS];
  int issue_phase[CLUSTERS],issue_context[CLUSTERS];
  for(genvar c=0;c<CLUSTERS;c++) begin:g_cluster
    cluster_dut_adapter dut(
      .clock(clock),.reset(reset),.cmd_i(cmd_i),.cmd_valid_i(cmd_valid_i),
      .cmd_ready_o(cmd_ready_o[c]),.requant_cfg_i(requant_cfg_i[c]),.act_data_i(act_data_i),
      .weight_wen_i(8'b0),.weight_waddr_i(8'b0),.weight_wdata_i(8192'b0),
      .cim_cs_en(cim_cs_en),.cim_wr_en(cim_wr_en),.cim_macro_group(cim_macro_group),
      .cim_bank_sel(cim_bank_sel),.cim_row_addr(cim_row_addr),.cim_wmask(cim_wmask),
      .cim_wrdata(cim_wrdata[c]),.cim_rd_data(cim_rd_data[c]),
      .psum_data_o(psum_data_o[c]),.out_valid_o(out_valid_o[c]),
      .requant_data_o(requant_data_o[c]),.requant_valid_o(requant_valid_o[c])
    );
    assign issue[c]=dut.issue;
    assign batch_active[c]=dut.batch_active;
    assign psum_activity[c]=(|dut.psum_depth_open) || (|dut.psum_write);
    assign ren[c]=dut.ren;
    assign station[c]=dut.station;
    assign issue_plane[c]=dut.plane;
    assign issue_address[c]=dut.command.weight_cim_raddr;
    always_comb begin issue_phase[c]=dut.phase;issue_context[c]=dut.context_idx;end
  end

  // External Python golden is indexed in ordinary row-major GEMM order.
  logic [15:0] x_q[0:M*K-1];
  logic [7:0] w_q[0:K*N-1],quant_golden[0:M*N-1];
  logic [31:0] raw_golden[0:M*N-1],centered_golden[0:M*N-1],zp[0:N-1];
  logic [31:0] channel_multiplier[0:N-1];
  logic [9:0] channel_shift[0:N-1];
  logic [1023:0] weight_rows[0:31],act_planes[0:M*4-1];
  logic [31:0] observed_raw[0:M*N-1];
  logic [7:0] observed_quant[0:M*N-1];
  int multiplier,shift,output_zp,act_zp;
  string data_dir;
  int cycle=0,active_tile=0,raw_checks=0,quant_checks=0;
  int first_accept[N_TILES],accepted[N_TILES],issues[N_TILES],refreshes[N_TILES][8];
  int raw_rows[N_TILES][4],quant_rows[N_TILES][4];
  bit monitoring=0;
  int trace_fd;

  `include "include/cluster_gemm_driver.svh"
  `include "include/cluster_gemm_scoreboard.svh"
  `include "include/cluster_gemm_regression.svh"

  // VCS supplies a case-specific path; direct runs retain a descriptive default.
`ifdef CLUSTER_FSDB
  initial begin : case_fsdb_dump
    string fsdb_file;
    if(!$value$plusargs("FSDB_FILE=%s",fsdb_file)) fsdb_file="tb_Cluster_GEMM_OS1_WS32_default.fsdb";
    $display("[WAVE] file=%s",fsdb_file);
    $fsdbDumpfile(fsdb_file);
    $fsdbDumpvars(0, tb_Cluster_GEMM_OS1_WS32, "+all");
  end
`endif
endmodule
