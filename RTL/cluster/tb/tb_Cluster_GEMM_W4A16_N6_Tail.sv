`timescale 1ns / 1ps
// Concrete W4A16_N6_Tail GEMM entry; tensor/channel scale is selected by test data.
module tb_Cluster_GEMM_W4A16_N6_Tail;
  ClusterGemmScenario #(.SCENARIO("w4a16_n6_tail")) u_scenario ();
`ifdef CLUSTER_FSDB
  initial begin : case_fsdb_dump
    string fsdb_file;
    if (!$value$plusargs("FSDB_FILE=%s", fsdb_file)) fsdb_file = "tb_Cluster_GEMM_W4A16_N6_Tail.fsdb";
    $display("[WAVE] file=%s", fsdb_file);
    $fsdbDumpfile(fsdb_file);
    $fsdbDumpvars(0, tb_Cluster_GEMM_W4A16_N6_Tail, "+all");
  end
`endif
endmodule
