`timescale 1ns/1ps
module tb_Cluster;
  import cluster_tb_pkg::*;
  parameter logic [7:0] EN_MASK=8'hff;
  parameter logic [31:0] OC_MASK=32'hffff_ffff;
  parameter int OS_TILES=1;
  parameter int PATTERNS=6;
  parameter int OUTPUT_BUFFER_DEPTH=4; // signed32 entries in EACH output channel
  parameter int TIMEOUT_CYCLES=4000;
  parameter logic [31:0] SEED=32'h19e2a407;
  localparam int MAX_CONTEXTS=16;
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
  cluster_dut_adapter #(.OUTPUT_BUFFER_DEPTH(OUTPUT_BUFFER_DEPTH),
                       .MAX_CONTEXTS(MAX_CONTEXTS)) dut(.*);
  logic [31:0] rng=SEED;
  int unsigned activation[0:255][0:MAX_CONTEXTS-1][0:255];
  longint signed expected[0:MAX_CONTEXTS-1][0:31];
  logic [31:0] expected_mask;
  int golden_group[0:7];
  int cases_run=0, configurations=0, canonical_count=0, manifest;
  int cycle=0, issue_count, raw_count, output_count;
  int case_os, case_ws, case_as, case_r, case_p, first_issue, last_issue;
  int final_due[0:MAX_CONTEXTS-1];
  bit raw_seen[0:MAX_CONTEXTS-1], output_seen[0:MAX_CONTEXTS-1];
  bit monitoring=0, stress=0, exact_ii=0;
  int stalled_cycles=0, reuse_cycles=0, full_cycles=0;
  bit held_output=0;
  logic [1023:0] last_data;
  logic [31:0] last_mask;
  bit held_cmd=0, held_act=0;
  cluster_ctrl_t last_cmd;
  logic [1023:0] last_act;

  function automatic int unsigned rand32();
    rng=rng^(rng<<13); rng=rng^(rng>>17); rng=rng^(rng<<5); return rng;
  endfunction
  function automatic int unsigned sample_bits(input int bits, pattern, index,
                                               input bit sign_en, is_weight);
    int unsigned hi,lo;
    hi=sign_en ? (1<<(bits-1))-1 : (1<<bits)-1;
    lo=sign_en ? 1<<(bits-1) : 0;
    case(pattern)
      0: return rand32() & ((1<<bits)-1);
      1: return 0;
      2: return hi;
      3: return lo;
      4: return index%2 ? hi : lo;
      default: return ((index%2)!=int'(is_weight)) ? hi : lo;
    endcase
  endfunction
  // Independent recursive decoder for the numerical scoreboard.
  task automatic decode_groups(input logic [6:0] s, input int node,start,size,
                               inout int group_id);
    if(size==1 || !s[node]) begin
      for(int m=start;m<start+size;m++) golden_group[m]=group_id;
      group_id++;
    end else begin
      decode_groups(s,2*node+1,start,size/2,group_id);
      decode_groups(s,2*node+2,start+size/2,size/2,group_id);
    end
  endtask
  function automatic bit legal_k(input int p, input logic [6:0] split);
    int count;
    for(int g=0;g<8;g++) begin
      count=0;
      for(int m=0;m<8;m++) if(EN_MASK[m] && group_of(split,m)==g) count++;
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
      for(int j=0;j<m;j++) if(EN_MASK[j] && group_of(split,j)==group_of(split,m)) rank++;
      slots[3*m+:3]=3'(rank);
    end
    return slots;
  endfunction

  // Capture accepted compute events before NBA, inspect raw result after NBA.
  always @(posedge clock) begin : scoreboard
    int t,c,p,idx,tag;
    cycle=cycle+1;
    if(reset) begin held_output=0; end
    else if(monitoring) begin
      if(held_cmd && (!cmd_valid_i || cmd_i!==last_cmd))
        $fatal(1,"Command changed before ready");
      if(held_act && (!act_valid_i || act_data_i!==last_act))
        $fatal(1,"ACT changed before ready");
      held_cmd=cmd_valid_i && !cmd_ready_o; last_cmd=cmd_i;
      held_act=act_valid_i && !act_ready_o; last_act=act_data_i;
      if(held_output && (!out_valid_o || psum_data_o!==last_data ||
                         psum_lane_valid_o!==last_mask))
        $fatal(1,"Output changed under backpressure");
      held_output=out_valid_o && !out_ready_i;
      last_data=psum_data_o; last_mask=psum_lane_valid_o;
      if(dut.occupancy==OUTPUT_BUFFER_DEPTH) full_cycles++;
      if(cmd_valid_i && !cmd_ready_o) stalled_cycles++;
      if(out_valid_o && out_ready_i) begin
        tag=dut.output_context[dut.rd_ptr];
        if(tag!=output_count || tag>=case_r || output_seen[tag])
          $fatal(1,"Duplicate/out-of-order buffered Context %0d",tag);
        if(psum_lane_valid_o!==expected_mask) $fatal(1,"Buffered mask mismatch");
        for(int l=0;l<32;l++) if(expected_mask[l] &&
            psum_data_o[32*l+:32]!==32'(expected[tag][l]))
          $fatal(1,"Buffered result case=%0d ctx=%0d lane=%0d",cases_run,tag,l);
        output_seen[tag]=1; output_count++;
      end
      if(dut.issue) begin
        idx=issue_count; t=idx/(case_r*case_p);
        if(case_as!=0) begin p=(idx/case_r)%case_p; c=idx%case_r; end
        else begin c=(idx/case_p)%case_r; p=idx%case_p; end
        if(dut.phase!=p || dut.context_idx!=c || dut.tile!=t)
          $fatal(1,"Issue order differs from spec at index %0d",idx);
        if(case_as!=0 && c!=0 && act_ready_o)
          $fatal(1,"AS plane can be overwritten before all consumers finish");
        if(dut.command.weight_cim_raddr!==8'('h20+16*t+(case_as!=0 ? c : 0)))
          $fatal(1,"Descriptor weight address mismatch");
        if(issue_count==0) first_issue=cycle;
        else if(exact_ii && cycle!=last_issue+1)
          $fatal(1,"Unexpected bubble in v2.7 schedule");
        last_issue=cycle; issue_count++;
        if((dut.ren & ~dut.station)!=0) reuse_cycles++;
        if(p==case_p-1 && t==case_os-1) final_due[c]=cycle+4;
      end
      #1;
      if(dut.raw_psum_valid) begin
        tag=dut.raw_context;
        if(tag>=case_r || raw_seen[tag] || final_due[tag]!=cycle)
          $fatal(1,"Raw latency/context mismatch ctx=%0d actual=%0d due=%0d",
                 tag,cycle,final_due[tag]);
        if(dut.raw_mask!==expected_mask) $fatal(1,"Raw mask mismatch");
        for(int l=0;l<32;l++) if(expected_mask[l] &&
            dut.raw_data[32*l+:32]!==32'(expected[tag][l]))
          $fatal(1,"Raw mismatch case=%0d p=%0d sign=%0d ctx=%0d lane=%0d got=%0d expected=%0d",
              cases_run,cmd_i.precision,cmd_i.signed_en,tag,l,
              $signed(dut.raw_data[32*l+:32]),expected[tag][l]);
        raw_seen[tag]=1; raw_count++;
      end
      for(int c0=0;c0<case_r;c0++)
        if(final_due[c0]==cycle && !raw_seen[c0]) $fatal(1,"Missing raw output at +4T");
    end
  end
  // Downstream is held long enough to fill even a non-power-of-two buffer.
  always @(negedge clock) begin
    if(monitoring) begin
      if(stress && (issue_count==0 || cycle-first_issue<case_os*case_r*case_p*4+16))
        out_ready_i=0;
      else out_ready_i=!stress || cycle%4!=0;
    end
  end
  task automatic send_command(input cluster_ctrl_t d, input int gap);
    @(negedge clock); repeat(gap) @(negedge clock);
    cmd_i=d; cmd_valid_i=1;
    for(int t=0;t<TIMEOUT_CYCLES;t++) begin
      @(posedge clock);
      if(cmd_ready_o) begin #1; cmd_valid_i=0; return; end
    end
    $fatal(1,"Command timeout");
  endtask
  task automatic send_plane(input logic [1023:0] data, input int gap);
    @(negedge clock); repeat(gap) @(negedge clock);
    act_data_i=data; act_valid_i=1;
    for(int t=0;t<TIMEOUT_CYCLES;t++) begin
      @(posedge clock);
      if(act_ready_o) begin #1; act_valid_i=0; return; end
    end
    $fatal(1,"ACT timeout");
  endtask

  task automatic run_case(input int precision, input bit sign_en,
      input logic [6:0] split, input logic [7:0] en,
      input logic [31:0] oc, input logic [23:0] slots,
      input int pattern,os,ws,as_count, input bit pressure,bubbles);
    cluster_ctrl_t d;
    logic [1023:0] plane, row;
    int wb,ab,kr,l,slot,a_ctx,c,p,t,groups,used_digits;
    int unsigned raw;
    longint signed w,a;
    wb=wbits(precision); ab=abits(precision); kr=256/wb;
    case_os=os; case_ws=ws; case_as=as_count;
    case_r=ws!=0 ? ws : as_count!=0 ? as_count : 1; case_p=ab/4;
    d='0; d.os_cnt=16'(os); d.ws_cnt=16'(ws); d.as_cnt=16'(as_count);
    d.precision=3'(precision); d.signed_en=sign_en; d.reduce_split_mask=split;
    d.macro_en_mask=en; d.macro_oc_mask=oc; d.act_slot_sel=slots;
    used_digits=0;
    for(int m=0;m<8;m++) if(en[m] && (int'(slots[3*m+:3])+1)*kr>used_digits)
      used_digits=(int'(slots[3*m+:3])+1)*kr;
    groups=0; decode_groups(split,0,0,8,groups);
    expected_mask='0;
    for(int cx=0;cx<case_r;cx++) begin
      final_due[cx]=-1; raw_seen[cx]=0; output_seen[cx]=0;
      for(int i=0;i<32;i++) expected[cx][i]=0;
    end
    for(int kt=0;kt<os;kt++) for(int cx=0;cx<case_r;cx++)
      for(int k=0;k<256;k++) begin
        a_ctx=as_count!=0 ? 0 : cx;
        if(cx==0 || as_count==0)
          activation[kt][cx][k]=sample_bits(ab,pattern,k+7*cx+kt,sign_en,0);
        else activation[kt][cx][k]=activation[kt][0][k];
        // Keep all positive W8A16 OS extrema within signed32; no saturation.
        if(!sign_en && wb==8 && ab==16)
          activation[kt][cx][k]%= (32768/os);
      end
    // Preload every tile/context row before issuing any computation.
    for(int kt=0;kt<os;kt++) begin
      for(int wc=0;wc<(as_count!=0 ? case_r : 1);wc++) begin
        @(negedge clock);
        weight_waddr_i=8'('h20+16*kt+wc); weight_wen_i=8'hff;
        for(int m=0;m<8;m++) begin
          row='0;
          for(int ocid=0;ocid<4;ocid++) for(int j=0;j<kr;j++) begin
            raw=sample_bits(wb,pattern,j+m*7+ocid*3+kt+wc*11,sign_en,1);
            for(int b=0;b<wb;b++) row[256*ocid+wb*j+b]=(raw>>b)&1;
            if(en[m] && oc[4*m+ocid]) begin
              l=4*golden_group[m]+ocid; slot=int'(slots[3*m+:3]);
              for(int cx=0;cx<case_r;cx++) if(as_count==0 || cx==wc) begin
                w=number(raw,wb,sign_en);
                a=number(activation[kt][cx][slot*kr+j],ab,sign_en);
                expected[cx][l]+=w*a; expected_mask[l]=1;
              end
            end
          end
          weight_wdata_i[1024*m+:1024]=row;
        end
        @(negedge clock); weight_wen_i=0;
      end
    end
    for(int cx=0;cx<case_r;cx++) for(int ch=0;ch<32;ch++)
      if(expected[cx][ch]<-64'sd2147483648 || expected[cx][ch]>64'sd2147483647)
        $fatal(1,"Golden overflow: selected OS/pattern exceeds signed32");
    issue_count=0; raw_count=0; output_count=0; first_issue=-1; last_issue=-1;
    stress=pressure; exact_ii=!pressure && !bubbles;
    held_output=0; held_cmd=0; held_act=0;
    monitoring=1;
    for(int index=0;index<os*case_r*case_p;index++) begin
      t=index/(case_r*case_p);
      if(as_count!=0) begin p=(index/case_r)%case_p; c=index%case_r; end
      else begin c=(index/case_p)%case_r; p=index%case_p; end
      d.weight_cim_raddr=8'('h20+16*t+(as_count!=0 ? c : 0));
      plane='0;
      for(int k=0;k<used_digits;k++) plane[4*k+:4]=4'(activation[t][c][k]>>(4*p));
      if(as_count==0 || c==0) begin
        fork
          send_command(d,bubbles ? (index%3) : 0);
          send_plane(plane,bubbles ? ((index+1)%3) : 0);
        join
      end else send_command(d,bubbles ? index%2 : 0);
    end
    for(int wait_cycles=0;wait_cycles<TIMEOUT_CYCLES;wait_cycles++) begin
      @(negedge clock);
      if(output_count==case_r) break;
      if(wait_cycles==TIMEOUT_CYCLES-1) $fatal(1,"Output timeout");
    end
    if(raw_count!=case_r || issue_count!=os*case_r*case_p)
      $fatal(1,"Lost/duplicate compute or result");
    repeat(6) @(negedge clock);
    if(out_valid_o || dut.reserved!=0 || dut.occupancy!=0)
      $fatal(1,"FIFO failed to drain");
    monitoring=0; out_ready_i=0; cases_run++;
  endtask

  initial begin : regression
    int legal_count,n,r;
    logic [23:0] standard_slots;
    logic [7:0] standard_en;
    logic [6:0] standard_split;
    if(OS_TILES<1 || OS_TILES>14 || PATTERNS<1 || PATTERNS>6 || SEED==0)
      $fatal(1,"Require OS_TILES 1..14 (distinct preload rows), PATTERNS 1..6, nonzero seed");
    if(OUTPUT_BUFFER_DEPTH<1) $fatal(1,"Depth must be >=1");
    for(int mask=0;mask<128;mask++) if(canonical(7'(mask))) canonical_count++;
    if(canonical_count!=26) $fatal(1,"Expected 26 canonical trees");
    manifest=$fopen("split_cases.csv","w");
    $fdisplay(manifest,"precision,signed_en,split_mask_hex,en_mask_hex,oc_mask_hex,slots_hex,group0_K,group1_K,group2_K,group3_K,group4_K,group5_K,group6_K,group7_K");
    repeat(4) @(negedge clock); reset=0;
    repeat(2) @(negedge clock);
    for(int p=0;p<7;p++) begin
      legal_count=0;
      for(int mask=0;mask<128;mask++) if(canonical(7'(mask)) && legal_k(p,7'(mask))) begin
        legal_count++;
        for(int s=0;s<2;s++) begin
          $fwrite(manifest,"%0d,%0d,%02h,%02h,%08h,%06h",p,s,7'(mask),EN_MASK,OC_MASK,make_slots(7'(mask)));
          for(int g=0;g<8;g++) begin
            n=0;
            for(int m=0;m<8;m++) if(EN_MASK[m] && group_of(7'(mask),m)==g) n++;
            $fwrite(manifest,",%0d",n*(256/wbits(p)));
          end
          $fwrite(manifest,"\n"); configurations++;
          for(int pattern=0;pattern<PATTERNS;pattern++)
            run_case(p,1'(s),7'(mask),EN_MASK,OC_MASK,make_slots(7'(mask)),
                     pattern,OS_TILES,0,0,0,pattern==0);
        end
      end
      $display("precision=%0d W%0dA%0d splits/sign=%0d",p,wbits(p),abits(p),legal_count);
      case(wbits(p))
        2: begin standard_slots=24'h208208; standard_en=8'h55; standard_split=7'h07; end
        4: begin standard_slots=24'h688688; standard_en=8'h33; standard_split=7'h01; end
        default: begin standard_slots=24'hfac688; standard_en=8'h0f; standard_split=0; end
      endcase
      // Six chapter-4 schedules, both signs; K=128 per tile, high plane half 0.
      for(int s=0;s<2;s++) for(int mode=0;mode<6;mode++)
        run_case(p,1'(s),standard_split,standard_en,32'hffffffff,standard_slots,
                 0,mode<2 ? 1 : 2, mode%2==0 ? (mode==2 ? 1 : 2) : 0,
                 mode%2==1 ? (mode==3 ? 1 : 2) : 0,OUTPUT_BUFFER_DEPTH<2,0);
      // More contexts than output entries: force full, wrap and backpressure.
      r=OUTPUT_BUFFER_DEPTH+2;
      if(r>MAX_CONTEXTS) r=MAX_CONTEXTS;
      for(int s=0;s<2;s++) for(int mode=0;mode<2;mode++)
        run_case(p,1'(s),standard_split,standard_en,32'hffffffff,standard_slots,
                 0,2,mode==0 ? r : 0,mode==1 ? r : 0,1,1);
    end
    $fclose(manifest);
    if(reuse_cycles==0 || (OUTPUT_BUFFER_DEPTH<MAX_CONTEXTS &&
                          (full_cycles==0 || stalled_cycles==0)))
      $fatal(1,"Missing coverage: reuse=%0d full=%0d stalls=%0d",reuse_cycles,full_cycles,stalled_cycles);
    $display("PASS configurations=%0d cases=%0d depth/channel=%0d reuse=%0d full=%0d stalls=%0d seed=%08h",
      configurations,cases_run,OUTPUT_BUFFER_DEPTH,reuse_cycles,full_cycles,stalled_cycles,SEED);
    $finish;
  end
  initial begin #200000000; $fatal(1,"Global watchdog"); end
endmodule
