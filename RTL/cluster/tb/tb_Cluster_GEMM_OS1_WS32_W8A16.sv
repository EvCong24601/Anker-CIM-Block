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
  // Dump FST under --trace-fst (wave-mcp reads it directly); leave CLUSTER_FST
  // undefined for VCS/Icarus runs.
`ifdef CLUSTER_FST
  initial begin : case_fst_dump
    string fst_file;
    if (!$value$plusargs("FST_FILE=%s", fst_file)) fst_file = "tb_Cluster_GEMM_OS1_WS32_W8A16_default.fst";
    $display("[WAVE] file=%s", fst_file);
    $dumpfile(fst_file);
    $dumpvars(0, tb_Cluster_GEMM_OS1_WS32_W8A16);
  end
`endif
endmodule
