`timescale 1ns / 1ps
// Concrete W4A16_HighGroup GEMM entry; tensor/channel scale is selected by test data.
module tb_Cluster_GEMM_W4A16_HighGroup;
  ClusterGemmScenario #(.SCENARIO("w4a16_high_group")) u_scenario ();
`ifdef CLUSTER_FSDB
  initial begin : case_fsdb_dump
    string fsdb_file;
    if (!$value$plusargs("FSDB_FILE=%s", fsdb_file)) fsdb_file = "tb_Cluster_GEMM_W4A16_HighGroup.fsdb";
    $display("[WAVE] file=%s", fsdb_file);
    $fsdbDumpfile(fsdb_file);
    $fsdbDumpvars(0, tb_Cluster_GEMM_W4A16_HighGroup, "+all");
  end
`endif
  // Dump FST under --trace-fst (wave-mcp reads it directly); leave CLUSTER_FST
  // undefined for VCS/Icarus runs.
`ifdef CLUSTER_FST
  initial begin : case_fst_dump
    string fst_file;
    if (!$value$plusargs("FST_FILE=%s", fst_file)) fst_file = "tb_Cluster_GEMM_W4A16_HighGroup.fst";
    $display("[WAVE] file=%s", fst_file);
    $dumpfile(fst_file);
    $dumpvars(0, tb_Cluster_GEMM_W4A16_HighGroup);
  end
`endif
endmodule
