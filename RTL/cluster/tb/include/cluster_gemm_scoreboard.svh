// Output rows are reconstructed by lane order, independently of DUT Context
// tags. Exact due cycles distinguish missing/duplicated/reordered Contexts.
always @(posedge clock) begin:gemm_scoreboard
  logic [31:0] previous_raw_valid[CLUSTERS];
  logic [255:0] previous_quant[CLUSTERS];
  int row,n,ph;
  cycle++;
  for(int c=0;c<CLUSTERS;c++) begin
    previous_raw_valid[c]=out_valid_o[c];previous_quant[c]=requant_data_o[c];
  end
  if(!reset && monitoring) begin
    if(|psum_activity) $fatal(1,"GEMM: OS1 WS32 must bypass the depth16 Psum buffer");
    if(cmd_valid_i && (&cmd_ready_o)) begin
      if(first_accept[active_tile]<0) first_accept[active_tile]=cycle;
      if(cycle!=first_accept[active_tile]+5*accepted[active_tile]) $fatal(1,"GEMM: Command spacing is not five cycles");
      $fdisplay(trace_fd,"%0d,%0d,command,%0d,%0d,0,-1,-1,0",cycle,cycle-first_accept[active_tile],active_tile,accepted[active_tile]);
      accepted[active_tile]++;
    end
    for(int c=0;c<CLUSTERS;c++) if(issue[c]) begin
      row=issues[active_tile]/4;ph=issues[active_tile]%4;
      if(issue_context[c]!=row || issue_phase[c]!=ph || issue_address[c]!==WEIGHT_ADDR+8'(active_tile) ||
         issue_plane[c]!==act_planes[4*row+ph] || cycle!=first_accept[active_tile]+5*row+1+ph)
        $fatal(1,"GEMM: internal issue schedule/data mismatch cluster=%0d row=%0d slice=%0d",c,row,ph);
      for(int macro=0;macro<8;macro++) if(ren[c][macro]) begin
        if(station[c][macro] !== (issues[active_tile]==0))
          $fatal(1,"GEMM: WS weight refreshed after the first issue cluster=%0d macro=%0d",c,macro);
        if(station[c][macro]) refreshes[active_tile][macro]++;
      end
      issues[active_tile]++;
    end
  end
  #1;
  if(!reset && monitoring) for(int c=0;c<CLUSTERS;c++) begin
    if((out_valid_o[c]&32'hffffff00)!=0 || (requant_valid_o[c]&32'hffffff00)!=0)
      $fatal(1,"GEMM: output on inactive group lane cluster=%0d",c);
    if(requant_valid_o[c]!==previous_raw_valid[c])
      $fatal(1,"GEMM: quant valid must follow raw by one cycle cluster=%0d",c);
    for(int lane=0;lane<32;lane++) if(!requant_valid_o[c][lane] &&
      requant_data_o[c][8*lane+:8]!==previous_quant[c][8*lane+:8])
      $fatal(1,"GEMM: INT8 output register changed without valid");
    for(int lane=0;lane<8;lane++) begin
      n=8*active_tile+lane;
      if(out_valid_o[c][lane]) begin
        row=raw_rows[active_tile][lane];
        if(row>=M || cycle!=first_accept[active_tile]+5*row+8)
          $fatal(1,"GEMM: raw row/order/latency mismatch cluster=%0d lane=%0d row=%0d",c,lane,row);
        if(psum_data_o[c][32*lane+:32]!==raw_golden[row*N+n])
          $fatal(1,"GEMM: raw matrix mismatch m=%0d n=%0d got=%0d expected=%0d",row,n,
            $signed(psum_data_o[c][32*lane+:32]),$signed(raw_golden[row*N+n]));
        observed_raw[row*N+n]=psum_data_o[c][32*lane+:32];
        $fdisplay(trace_fd,"%0d,%0d,raw,%0d,%0d,%0d,%0d,%0d,%0d",cycle,cycle-first_accept[active_tile],active_tile,row,c,lane,n,$signed(observed_raw[row*N+n]));
        raw_rows[active_tile][lane]++;raw_checks++;
      end
      if(requant_valid_o[c][lane]) begin
        row=quant_rows[active_tile][lane];
        if(row>=M || cycle!=first_accept[active_tile]+5*row+9)
          $fatal(1,"GEMM: INT8 row/order/latency mismatch cluster=%0d lane=%0d row=%0d",c,lane,row);
        if(requant_data_o[c][8*lane+:8]!==quant_golden[row*N+n])
          $fatal(1,"GEMM: INT8 matrix mismatch m=%0d n=%0d got=%0d expected=%0d",row,n,
            $signed(requant_data_o[c][8*lane+:8]),$signed(quant_golden[row*N+n]));
        observed_quant[row*N+n]=requant_data_o[c][8*lane+:8];
        $fdisplay(trace_fd,"%0d,%0d,quant,%0d,%0d,%0d,%0d,%0d,%0d",cycle,cycle-first_accept[active_tile],active_tile,row,c,lane,n,$signed(observed_quant[row*N+n]));
        quant_rows[active_tile][lane]++;quant_checks++;
      end
    end
  end
end
