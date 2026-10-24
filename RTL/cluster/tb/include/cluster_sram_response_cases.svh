// Independent SRAM response scoreboard. Requests use live pins only at the
// sampling edge; the expected response then stays independent of those pins.
logic [1023:0] response_memory[0:7][0:255];
logic expected_sram_valid=0;
logic [1023:0] expected_sram_data='0;
int sram_response_checks=0;
always @(posedge clock or posedge reset) begin : check_sampled_sram_response
  int macro_id;
  if(reset) begin
    expected_sram_valid=0;
    expected_sram_data='0;
  end else begin
    macro_id={sram_macro_group,sram_bank_sel};
    expected_sram_valid=sram_cs_en && !sram_wr_en;
    expected_sram_data=expected_sram_valid ? response_memory[macro_id][sram_row_addr] : 1024'b0;
    if(sram_cs_en && sram_wr_en)
      for(int c=0;c<4;c++) if(!sram_wmask[c])
        response_memory[macro_id][sram_row_addr][256*c+:256]=sram_wrdata[256*c+:256];
  end
  #0.003;
  if(sram_rd_valid !== expected_sram_valid || sram_rd_data !== expected_sram_data)
    $fatal(1,"SRAM_RESPONSE: sampled valid/data mismatch");
  if(!reset) sram_response_checks++;
end
// Check after requests change between edges, including CS and read/write.
always @(sram_cs_en or sram_wr_en or sram_macro_group or sram_bank_sel or sram_row_addr) begin
  #0.004;
  if(!reset && (sram_rd_valid !== expected_sram_valid || sram_rd_data !== expected_sram_data))
    $fatal(1,"SRAM_RESPONSE: live request changed the previous response");
end

task automatic run_sram_response_suite();
  logic [1023:0] saved;
  int m,a;
  $display("[CASE_START] time=%0.3f ns suite=sram_response description=cross-Macro-back-to-back/read-idle-write/reset",$realtime);
  for(int macro_id=0;macro_id<8;macro_id++)
    for(int row_id=0;row_id<2;row_id++)
      load_weight_row(macro_id,8'(3+4*row_id),sram_pattern(macro_id,3+4*row_id,91));
  for(int n=0;n<32;n++) begin
    m=n%8;a=n%2 ? 7 : 3;
    @(negedge clock);
    sram_cs_en=1;sram_wr_en=0;sram_macro_group=1'(m/4);sram_bank_sel=2'(m%4);sram_row_addr=8'(a);
    @(posedge clock);#0.002;
    saved=sram_pattern(m,a,91);
    if(!sram_rd_valid || sram_rd_data !== saved) $fatal(1,"SRAM_RESPONSE: consecutive response mismatch");
    // Next request is legal after the sampling edge's hold interval.
    #1;sram_macro_group=1'(((m+1)%8)/4);sram_bank_sel=2'((m+1)%4);sram_row_addr=8'(a==3 ? 7 : 3);
    #1;
    if(!sram_rd_valid || sram_rd_data !== saved) $fatal(1,"SRAM_RESPONSE: Macro mux changed response early");
  end
  @(negedge clock);sram_cs_en=0;
  #0.002;
  if(!sram_rd_valid || sram_rd_data !== saved) $fatal(1,"SRAM_RESPONSE: CS truncated response");
  @(posedge clock);#0.002;
  if(sram_rd_valid || sram_rd_data !== 0) $fatal(1,"SRAM_RESPONSE: idle valid did not clear");
  @(negedge clock);sram_cs_en=1;sram_wr_en=0;sram_macro_group=0;sram_bank_sel=0;sram_row_addr=3;
  @(posedge clock);#1;saved=sram_rd_data;sram_wr_en=1;sram_wmask=4'h0;sram_wrdata='1;
  #1;if(!sram_rd_valid || sram_rd_data !== saved) $fatal(1,"SRAM_RESPONSE: write request truncated read");
  @(posedge clock);#0.002;
  if(sram_rd_valid) $fatal(1,"SRAM_RESPONSE: write produced read valid");
  @(negedge clock);sram_wr_en=0;
  @(posedge clock);#1;reset=1;
  #0.002;if(sram_rd_valid || sram_rd_data !== 0) $fatal(1,"SRAM_RESPONSE: async reset did not cancel response");
  @(negedge clock);sram_cs_en=0;reset=0;
  repeat(3) @(negedge clock);
  $display("PASS sram_response reads=32 macros=8 checks=%0d request_hold=1 async_reset=1",sram_response_checks);
endtask
