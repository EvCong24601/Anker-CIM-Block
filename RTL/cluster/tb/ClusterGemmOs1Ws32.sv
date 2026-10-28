`timescale 1ns / 1ps
// Shared driver and checking for tb_Cluster_GEMM_OS1_WS32_W8A16.
// One physical Cluster computes four sequential N4 tiles for X[32,128]*W[128,16].
// Eight Macros reduce K256 with a zero-padded K tail; X is replayed four times.
module ClusterGemmOs1Ws32;
  import cluster_pkg::*;
  localparam int M = 32, K = 128, N = 16, CLUSTERS = 1, N_TILES = 4;
  localparam logic [7:0] WEIGHT_ADDR = 8'h40;
  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  cluster_ctrl_t cmd_i = '0;
  logic cmd_valid_i = 0;
  wire [CLUSTERS - 1:0] cmd_ready_o, sram_rd_valid;
  logic [1023:0] act_data_i = '0;
  requant_cfg_t requant_cfg_i[CLUSTERS];
  logic sram_cs_en = 0, sram_wr_en = 0, sram_macro_group = 0;
  logic [1:0] sram_bank_sel = 0;
  logic [7:0] sram_row_addr = WEIGHT_ADDR;
  logic [3:0] sram_wmask = 0;
  logic [1023:0] sram_wrdata[CLUSTERS];
  wire [1023:0] sram_rd_data[CLUSTERS], psum_data_o[CLUSTERS];
  wire [255:0] requant_data_o[CLUSTERS];
  wire [31:0] out_valid_o[CLUSTERS], requant_valid_o[CLUSTERS];
  wire [CLUSTERS - 1:0] issue, batch_active;
  wire [CLUSTERS - 1:0] psum_activity;
  wire [7:0] ren[CLUSTERS], station[CLUSTERS];
  wire [1023:0] issue_plane[CLUSTERS];
  wire [7:0] issue_address[CLUSTERS];
  int issue_phase[CLUSTERS], issue_context[CLUSTERS];
  for (genvar c = 0; c < CLUSTERS; c++) begin : g_cluster
    cluster_top dut (
      .clock(clock),
      .reset(reset),
      .cmd_i(cmd_i),
      .cmd_valid_i(cmd_valid_i),
      .cmd_ready_o(cmd_ready_o[c]),
      .requant_cfg_i(requant_cfg_i[c]),
      .act_data_i(act_data_i),
      .sram_cs_en(sram_cs_en),
      .sram_wr_en(sram_wr_en),
      .sram_macro_group(sram_macro_group),
      .sram_bank_sel(sram_bank_sel),
      .sram_row_addr(sram_row_addr),
      .sram_wmask(sram_wmask),
      .sram_wrdata(sram_wrdata[c]),
      .sram_rd_data(sram_rd_data[c]),
      .sram_rd_valid(sram_rd_valid[c]),
      .requant_data_o(requant_data_o[c]),
      .requant_valid_o(requant_valid_o[c])
    );
    // TB-only raw observation; these aliases are not cluster_top ports.
    assign psum_data_o[c] = dut.raw_data;
    assign out_valid_o[c] = dut.raw_valid;
    assign issue[c] = dut.issue;
    assign batch_active[c] = dut.batch_active;
    assign psum_activity[c] = (|dut.psum_depth_open) || (|dut.psum_write);
    assign ren[c] = dut.ren;
    assign station[c] = dut.station;
    assign issue_plane[c] = dut.plane;
    assign issue_address[c] = dut.command.cim_weight_raddr;
    always_comb begin
      issue_phase[c]   = dut.phase;
      issue_context[c] = dut.context_idx;
    end
  end

  // External Python golden is indexed in ordinary row-major GEMM order.
  logic [15:0] x_q[0:M * K - 1];
  logic [7:0] w_q[0:K * N - 1], quant_golden[0:M * N - 1], cim_golden[0:M * N - 1];
  logic [31:0] raw_golden[0:M * N - 1], centered_golden[0:M * N - 1], zp[0:N - 1];
  logic [31:0] channel_multiplier[0:N - 1];
  logic [9:0] channel_shift[0:N - 1];
  logic [1023:0] weight_rows[0:31], act_planes[0:M * 4 - 1];
  logic [31:0] observed_raw  [0:M * N - 1];
  logic [ 7:0] observed_quant[0:M * N - 1];
  int multiplier, shift, output_zp, act_zp;
  string data_dir;
  int cycle = 0, active_tile = 0, raw_checks = 0, quant_checks = 0;
  int first_accept[N_TILES], accepted[N_TILES], issues[N_TILES], refreshes[N_TILES][8];
  int raw_rows[N_TILES][4], quant_rows[N_TILES][4];
  bit monitoring = 0;
  int trace_fd;

  `include "include/cluster_gemm_driver.svh"
  `include "include/cluster_gemm_scoreboard.svh"
  `include "include/cluster_gemm_regression.svh"
endmodule
