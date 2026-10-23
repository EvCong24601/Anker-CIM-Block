initial begin:gemm_regression
  int fd;
  load_gemm_vectors();
  $display("[CASE_START] time=%0.3f ns suite=cluster_gemm description=single-cluster-two-N-tiles-asymmetric-A16-symmetric-W8 M=32 K=128 N=16 clusters=1 os=1 ws=32 as=1 multiplier=%0d shift=%0d act_zp=%0d output_zp=%0d",
    $realtime,multiplier,shift,act_zp,output_zp);
  for(int n=0;n<N;n++)
    $display("[REQUANT_CONFIG] time=%0.3f ns description=effective-output-domain-zero-point n=%0d zp=%0d",$realtime,n,$signed(zp[n]));
  trace_fd=$fopen({data_dir,"/gemm_observed_events.csv"},"w");
  if(!trace_fd) $fatal(1,"GEMM: cannot open output event trace");
  $fdisplay(trace_fd,"cycle,relative_cycle,event,n_tile,m,cluster,lane,n,value");
  cim_wrdata[0]='0;
  for(int tile=0;tile<N_TILES;tile++) begin
    issues[tile]=0;first_accept[tile]=-1;accepted[tile]=0;
    for(int lane=0;lane<8;lane++) begin
      raw_rows[tile][lane]=0;quant_rows[tile][lane]=0;refreshes[tile][lane]=0;
    end
  end
  repeat(4) @(negedge clock);reset=0;
  load_gemm_weights();
  for(int tile=0;tile<N_TILES;tile++) begin
    active_tile=tile;monitoring=1;
    $display("[CASE_START] time=%0.3f ns suite=cluster_gemm_N_tile description=WS32-replay-X tile=%0d n_first=%0d n_last=%0d address=0x%02h",
      $realtime,tile,8*tile,8*tile+7,WEIGHT_ADDR+8'(tile));
    send_gemm_rows(tile);
    for(int t=0;t<100;t++) begin
      @(negedge clock);
      if(quant_checks==(tile+1)*M*8 && !(|batch_active)) break;
      if(t==99) $fatal(1,"GEMM: output timeout");
    end
    repeat(2) @(negedge clock);
    if(accepted[tile]!=32 || issues[tile]!=128 || out_valid_o[0]!=0 || requant_valid_o[0]!=0)
      $fatal(1,"GEMM: per-tile Command/issue/drain mismatch");
    for(int lane=0;lane<8;lane++)
      if(raw_rows[tile][lane]!=32 || quant_rows[tile][lane]!=32 || refreshes[tile][lane]!=1)
        $fatal(1,"GEMM: per-tile lane coverage or WS refresh count mismatch");
  end
  repeat(6) @(negedge clock);
  if(accepted[0]+accepted[1]!=64 || raw_checks!=512 || quant_checks!=512)
    $fatal(1,"GEMM: missing/duplicate Command or output");
  fd=$fopen({data_dir,"/gemm_observed_matrix.csv"},"w");
  if(!fd) $fatal(1,"GEMM: cannot open output matrix");
  $fdisplay(fd,"m,n,raw,quant");
  for(int m=0;m<M;m++) for(int n=0;n<N;n++)
    $fdisplay(fd,"%0d,%0d,%0d,%0d",m,n,$signed(observed_raw[m*N+n]),$signed(observed_quant[m*N+n]));
  $fclose(fd);$fclose(trace_fd);
  $display("PASS cluster_gemm M=32 K=128 N=16 clusters=1 n_tiles=2 commands=64 issues=256 raw_checks=%0d quant_checks=%0d first_raw_per_tile=8 last_raw_per_tile=163 first_quant_per_tile=9 last_quant_per_tile=164 refreshes_per_macro_per_tile=1",raw_checks,quant_checks);
  $finish;
end
initial begin
  repeat(1000) @(posedge clock);
  $fatal(1,"GEMM: watchdog timeout");
end
