`timescale 1ns / 1ps
// Eight AS Contexts, rotating logical columns across consecutive rows without
// reset. Invalid live commands are poisoned while the saved batch computes.
module tb_Cluster_GEMM_OS1_WS1_AS8_W8A16;
  ClusterGemmOs2As4 #(.M(8), .OS(1), .AS(8), .BASE_ADDR(8'hc0), .CHECK_SWITCH(1)) u_gemm ();
`ifdef CLUSTER_FSDB
  initial begin : case_fsdb_dump
    string fsdb_file;
    if (!$value$plusargs("FSDB_FILE=%s", fsdb_file))
      fsdb_file = "tb_Cluster_GEMM_OS1_WS1_AS8_W8A16_default.fsdb";
    $display("[WAVE] file=%s", fsdb_file);
    $fsdbDumpfile(fsdb_file);
    $fsdbDumpvars(0, tb_Cluster_GEMM_OS1_WS1_AS8_W8A16, "+all");
  end
`endif
endmodule
