`timescale 1ns/1ps
module tb_Cluster;
  import cluster_tb_pkg::*;
  parameter logic [7:0] EN_MASK = 8'hff;
  parameter logic [31:0] OC_MASK = 32'hffff_ffff;
  parameter int OS_TILES = 1;
  parameter int PATTERNS = 6;
  parameter int TIMEOUT_CYCLES = 2000;
  parameter logic [31:0] SEED = 32'h19e2a407;
  logic clock=0;
  always #5 clock=~clock;
  logic reset=1;
  cluster_ctrl_t cmd_i='0;
  logic cmd_valid_i=0, act_valid_i=0, out_ready_i=0;
  wire cmd_ready_o, act_ready_o, out_valid_o;
  logic [1023:0] act_data_i='0;
  logic [7:0] weight_wen_i=0, weight_waddr_i=0;
  logic [8191:0] weight_wdata_i=0;
  wire [1023:0] psum_data_o;
  wire [31:0] psum_lane_valid_o;
  cluster_dut_adapter dut(.*);

  logic [31:0] rng=SEED;
  logic [1023:0] rows[0:7];
  int unsigned activation[0:255];
  longint signed expected[0:31];
  logic [31:0] expected_mask;
  int cases_run=0, configurations=0, canonical_count=0;
  int covered[0:6][0:1];
  integer manifest;

  function automatic int unsigned rand32();
    rng=rng^(rng<<13); rng=rng^(rng>>17); rng=rng^(rng<<5);
    return rng;
  endfunction
  function automatic int unsigned sample_bits(
      input int bits, pattern, index, input bit is_signed, weight_operand);
    int unsigned mask, maxpos, minneg;
    mask=(1<<bits)-1;
    maxpos=is_signed ? (1<<(bits-1))-1 : mask;
    minneg=is_signed ? (1<<(bits-1)) : 0;
    case(pattern)
      0: return rand32() & mask;
      1: return 0;
      2: return maxpos;
      3: return minneg;
      4: return (index%2) ? maxpos : minneg;
      // Different signs for W and A; unsigned case stresses sparse extremes.
      default: return ((index%2)!=int'(weight_operand)) ? maxpos : minneg;
    endcase
  endfunction

  // Only macro_en_mask determines the participating K slices, even if an
  // individual macro has all four OC bits gated off. Strict inequality.
  function automatic bit legal_k(input int p, input logic [6:0] split);
    int count;
    for(int g=0;g<8;g++) begin
      count=0;
      for(int m=0;m<8;m++)
        if(EN_MASK[m] && group_of(split,m)==g) count++;
      if(count*(256/wbits(p))>=256) return 0;
    end
    return 1;
  endfunction
  function automatic logic [23:0] make_slots(input logic [6:0] split);
    logic [23:0] slots;
    int rank;
    slots='0;
    for(int m=0;m<8;m++) if(EN_MASK[m]) begin
      rank=0;
      for(int j=0;j<m;j++)
        if(EN_MASK[j] && group_of(split,j)==group_of(split,m)) rank++;
      slots[3*m+:3]=3'(rank);
    end
    return slots;
  endfunction

  task automatic send_command(input cluster_ctrl_t d, input int gap);
    @(negedge clock);
    repeat(gap) @(negedge clock);
    cmd_i=d; cmd_valid_i=1;
    for(int t=0;t<TIMEOUT_CYCLES;t++) begin
      @(posedge clock);
      if(cmd_ready_o===1'b1) begin
        @(negedge clock); cmd_valid_i=0; return;
      end
    end
    $fatal(1,"Command timeout precision=%0d split=%07b",d.precision,d.reduce_split_mask);
  endtask
  task automatic send_plane(input logic [1023:0] data, input int gap);
    @(negedge clock);
    repeat(gap) @(negedge clock);
    act_data_i=data; act_valid_i=1;
    for(int t=0;t<TIMEOUT_CYCLES;t++) begin
      @(posedge clock);
      if(act_ready_o===1'b1) begin
        @(negedge clock); act_valid_i=0; return;
      end
    end
    $fatal(1,"Activation timeout");
  endtask
  task automatic check_result;
    logic [1023:0] held_data;
    logic [31:0] held_mask;
    bit found;
    found=0;
    for(int t=0;t<TIMEOUT_CYCLES;t++) begin
      @(negedge clock);
      if(out_valid_o===1'b1) begin found=1; break; end
    end
    if(!found) $fatal(1,"Output timeout case=%0d",cases_run);
    if(psum_lane_valid_o!==expected_mask)
      $fatal(1,"Lane mask mismatch actual=%08h expected=%08h",psum_lane_valid_o,expected_mask);
    for(int l=0;l<32;l++) if(expected_mask[l]) begin
      if(expected[l]<-64'sd2147483648 || expected[l]>64'sd2147483647)
        $fatal(1,"Test configuration exceeds signed32; reduce OS_TILES");
      if(psum_data_o[32*l+:32]!==32'(expected[l]))
        $fatal(1,"case=%0d p=%0d signed=%0d split=%07b lane=%0d got=%0d expected=%0d",
          cases_run,cmd_i.precision,cmd_i.signed_en,cmd_i.reduce_split_mask,
          l,$signed(psum_data_o[32*l+:32]),expected[l]);
    end
    held_data=psum_data_o; held_mask=psum_lane_valid_o;
    repeat(3) begin
      @(negedge clock);
      if(out_valid_o!==1'b1 || psum_data_o!==held_data || psum_lane_valid_o!==held_mask)
        $fatal(1,"Output changed under backpressure");
    end
    out_ready_i=1;
    @(negedge clock); out_ready_i=0;
    repeat(3) begin
      @(negedge clock);
      if(out_valid_o!==1'b0) $fatal(1,"Duplicate/unretired output");
    end
  endtask

  task automatic run_case(input int p, input bit sign_en,
                          input logic [6:0] split, input int pattern);
    cluster_ctrl_t d;
    logic [1023:0] plane;
    int wb,ab,kr,slot,g,l;
    int unsigned raw;
    longint signed w,a;
    wb=wbits(p); ab=abits(p); kr=256/wb;
    d='0;
    d.os_cnt=16'(OS_TILES); d.reduce_split_mask=split;
    d.macro_en_mask=EN_MASK; d.macro_oc_mask=OC_MASK;
    d.act_slot_sel=make_slots(split); d.precision=3'(p); d.signed_en=sign_en;
    expected_mask='0;
    for(int i=0;i<32;i++) expected[i]=0;
    for(int tile=0;tile<OS_TILES;tile++) begin
      // Vary the shared row across cases and tiles (including 8-bit wrap).
      d.weight_cim_raddr=8'(cases_run*13+tile*17+251);
      for(int k=0;k<256;k++)
        activation[k]=sample_bits(ab,pattern,k+tile,sign_en,0);
      for(int m=0;m<8;m++) begin
        rows[m]='0;
        for(int c=0;c<4;c++) for(int j=0;j<kr;j++) begin
          raw=sample_bits(wb,pattern,j+m*7+c*3+tile,sign_en,1);
          // Variable element width implemented bit-by-bit for portable SV.
          for(int b=0;b<wb;b++) rows[m][256*c+wb*j+b]=(raw>>b)&1;
          if(EN_MASK[m] && OC_MASK[4*m+c]) begin
            g=group_of(split,m); l=4*g+c;
            slot=int'(d.act_slot_sel[3*m+:3]);
            w=number(raw,wb,sign_en);
            a=number(activation[slot*kr+j],ab,sign_en);
            expected[l]+=w*a; expected_mask[l]=1;
          end
        end
      end
      // Legal SRAM writes only after the preceding case has fully drained.
      @(negedge clock);
      weight_waddr_i=d.weight_cim_raddr;
      for(int m=0;m<8;m++) weight_wdata_i[1024*m+:1024]=rows[m];
      weight_wen_i=8'hff;
      @(negedge clock); weight_wen_i=0;
      for(int ph=0;ph<ab/4;ph++) begin
        plane='0;
        for(int k=0;k<256;k++) plane[4*k+:4]=4'(activation[k]>>(4*ph));
        fork
          send_command(d,(pattern+ph)%3);
          send_plane(plane,(pattern+ph+1)%3);
        join
      end
      // Last-phase command acceptance is not completion. Wait for its
      // computation before writing SRAM for the next K tile.
      if(tile!=OS_TILES-1) begin
        for(int t=0;t<TIMEOUT_CYCLES;t++) begin
          @(negedge clock);
          if(cmd_ready_o===1'b1 && act_ready_o===1'b1) break;
          if(t==TIMEOUT_CYCLES-1) $fatal(1,"K tile drain timeout");
        end
        repeat(2) @(negedge clock);
      end
    end
    check_result();
    cases_run++;
  endtask

  initial begin : regression
    int legal_count;
    bit any_lane;
    if(OS_TILES<1 || OS_TILES>256 || PATTERNS<1 || PATTERNS>6 || SEED==0)
      $fatal(1,"Require 1<=OS_TILES<=256, 1<=PATTERNS<=6, SEED!=0");
    any_lane=0;
    for(int m=0;m<8;m++) if(EN_MASK[m] && (|OC_MASK[4*m+:4])) any_lane=1;
    if(!any_lane) $fatal(1,"No enabled OC; no output is specified for an entirely idle task");
    for(int p=0;p<7;p++) for(int s=0;s<2;s++) covered[p][s]=0;
    for(int mask=0;mask<128;mask++) if(canonical(7'(mask))) canonical_count++;
    if(canonical_count!=26) $fatal(1,"Tree enumeration must find 26 canonical masks");
    manifest=$fopen("split_cases.csv","w");
    if(manifest==0) $fatal(1,"Cannot create split_cases.csv");
    $fdisplay(manifest,"precision,signed_en,split_mask_hex,en_mask_hex,oc_mask_hex,slots_hex,group0_K,group1_K,group2_K,group3_K,group4_K,group5_K,group6_K,group7_K");
    repeat(4) @(negedge clock); reset=0;
    repeat(2) @(negedge clock);
    for(int p=0;p<7;p++) begin
      legal_count=0;
      for(int mask=0;mask<128;mask++)
        if(canonical(7'(mask)) && legal_k(p,7'(mask))) begin
          legal_count++;
          for(int s=0;s<2;s++) begin
            $fwrite(manifest,"%0d,%0d,%02h,%02h,%08h,%06h",p,s,7'(mask),EN_MASK,OC_MASK,make_slots(7'(mask)));
            for(int g=0;g<8;g++) begin
              int n;
              n=0;
              for(int m=0;m<8;m++) if(EN_MASK[m] && group_of(7'(mask),m)==g) n++;
              $fwrite(manifest,",%0d",n*(256/wbits(p)));
            end
            $fwrite(manifest,"\n");
            configurations++;
            for(int pattern=0;pattern<PATTERNS;pattern++) run_case(p,1'(s),7'(mask),pattern);
            covered[p][s]++;
          end
        end
      if(legal_count==0) $fatal(1,"No legal splits for precision %0d",p);
      $display("precision=%0d W%0dA%0d signed+unsigned splits=%0d",p,wbits(p),abits(p),legal_count);
    end
    $fclose(manifest);
    $display("PASS configurations=%0d cases=%0d EN_MASK=%02h OC_MASK=%08h seed=%08h",
             configurations,cases_run,EN_MASK,OC_MASK,SEED);
    $finish;
  end
  initial begin
    #200000000;
    $fatal(1,"Global watchdog");
  end
endmodule
