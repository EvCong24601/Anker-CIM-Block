`timescale 1ns / 1ps
// Concrete OS1/WS32/W8A16 GEMM entry; driver and checking live in ClusterGemmOs1Ws32.
module tb_Cluster_GEMM_OS1_WS32_W8A16;
  ClusterGemmOs1Ws32 u_gemm ();
`ifdef CLUSTER_FSDB
  initial begin : case_fsdb_dump
    string fsdb_file;
    if (!$value$plusargs("FSDB_FILE=%s", fsdb_file)) fsdb_file = "tb_Cluster_GEMM_OS1_WS32_W8A16_default.fsdb";
    $display("[WAVE] file=%s", fsdb_file);
    $fsdbDumpfile(fsdb_file);
    $fsdbDumpvars(0, tb_Cluster_GEMM_OS1_WS32_W8A16, "+all");
  end
`endif
endmodule
