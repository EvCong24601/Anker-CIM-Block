`timescale 1ns / 1ps
// Concrete W2A8_HighGroup GEMM entry; tensor/channel scale is selected by test data.
module tb_Cluster_GEMM_W2A8_HighGroup;
  ClusterGemmScenario #(.SCENARIO("w2a8_high_group")) u_scenario ();
`ifdef CLUSTER_FSDB
  initial begin : case_fsdb_dump
    string fsdb_file;
    if (!$value$plusargs("FSDB_FILE=%s", fsdb_file)) fsdb_file = "tb_Cluster_GEMM_W2A8_HighGroup.fsdb";
    $display("[WAVE] file=%s", fsdb_file);
    $fsdbDumpfile(fsdb_file);
    $fsdbDumpvars(0, tb_Cluster_GEMM_W2A8_HighGroup, "+all");
  end
`endif
endmodule
