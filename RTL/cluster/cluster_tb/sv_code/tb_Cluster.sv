`timescale 1ns/1ps
module tb_Cluster;
  import cluster_tb_pkg::*;
  parameter logic [7:0] EN_MASK=8'hff;
  parameter logic [31:0] OC_MASK=32'hffff_ffff;
  parameter int OS_TILES=1;
  parameter int PATTERNS=6;
  parameter int OUTPUT_BUFFER_DEPTH=16; // Context entries per channel
  parameter int TIMEOUT_CYCLES=4000;
  parameter logic [31:0] SEED=32'h19e2a407;
  localparam int MAX_CONTEXTS=16;
  logic clock=0;
  always #5 clock=~clock;
  logic reset=1;
  cluster_ctrl_t cmd_i='0;
  logic cmd_valid_i=0;
  wire cmd_ready_o;
  wire [31:0] out_valid_o;
  logic [1023:0] act_data_i='0;
  logic [7:0] weight_wen_i=0, weight_waddr_i=0;
  logic [8191:0] weight_wdata_i=0;
  wire [1023:0] psum_data_o;
  cluster_dut_adapter #(.MAX_CONTEXTS(MAX_CONTEXTS),
                        .OUTPUT_BUFFER_DEPTH(OUTPUT_BUFFER_DEPTH)) dut(.*);
  logic [31:0] rng=SEED;
  int unsigned activation[0:255][0:MAX_CONTEXTS-1][0:255];
  longint signed expected[0:MAX_CONTEXTS-1][0:31];
  logic [31:0] expected_mask;
  int golden_group[0:7];
  int cases_run=0, configurations=0, canonical_count=0, manifest;
  int standard_case=0; // six distinct chapter-4 configurations
  int cycle=0, issue_count, raw_count;
  int case_os, case_ws, case_as, case_r, case_p, first_issue, last_issue;
  int case_used_digits;
  int first_external=-1,input_commands=0,act_planes_received=0;
  int external_trace;
  int lane_due[0:MAX_CONTEXTS-1][0:31];
  bit raw_seen[0:MAX_CONTEXTS-1][0:31];
  bit monitoring=0, exact_ii=0;
  int reuse_cycles=0;
  bit held_cmd=0, held_act_for_cmd=0;
  cluster_ctrl_t last_cmd;
  logic [1023:0] last_act;
  int buffer_gate_checks=0, high_depth_checks=0, bypass_psum_hold_checks=0;
  int operation_trace;

  function automatic int unsigned rand32();
    rng=rng^(rng<<13); rng=rng^(rng>>17); rng=rng^(rng<<5); return rng;
  endfunction

  always @(posedge clock) begin : buffer_clock_scoreboard
    longint signed old_p[0:OUTPUT_BUFFER_DEPTH-1][0:31];
    longint signed old_tmp[0:31], want_tmp[0:31];
    bit want_p[0:OUTPUT_BUFFER_DEPTH-1][0:31];
    logic [31:0] want_input;
    int c,ph,ab,writes;
    if(!reset) begin
      want_input=dut.capture_valid;
      for(int l=0;l<32;l++) begin
        old_tmp[l]=dut.tmp_result[l]; want_tmp[l]=dut.capture_data[l];
        if(dut.capture_valid[l] && dut.capture_tag[l].cmd.as_cnt<=1 && dut.capture_tag[l].ph>0)
          want_tmp[l]=old_tmp[l]+(dut.capture_data[l] <<< (4*dut.capture_tag[l].ph));
      end
      for(int d=0;d<OUTPUT_BUFFER_DEPTH;d++) for(int l=0;l<32;l++) begin
        old_p[d][l]=dut.psum[d][l]; want_p[d][l]=0;
      end
      for(int l=0;l<32;l++) if(dut.tmp_valid[l]) begin
        c=dut.tmp_tag[l].ctx; ph=dut.tmp_tag[l].ph;
        ab=abits(int'(dut.tmp_tag[l].cmd.precision));
        want_p[c][l]=dut.tmp_tag[l].cmd.as_cnt>1 ?
          (dut.tmp_tag[l].cmd.os_cnt>1 || ab>4) :
          (dut.tmp_tag[l].cmd.os_cnt>1 && ph==ab/4-1);
      end
      #0.001;
      if(dut.tmp_input_clock!==want_input) $fatal(1,"Advance tmp ICG mismatch");
      for(int l=0;l<32;l++) begin
        writes=0;
        for(int d=0;d<OUTPUT_BUFFER_DEPTH;d++) begin
          if(dut.psum_clock[d][l]!==want_p[d][l]) $fatal(1,"Psum ICG mismatch");
          if(dut.psum_clock[d][l]) writes++;
          if(dut.batch_active && d>=dut.batch_contexts) begin
            if(dut.psum_depth_open[d] || dut.psum_clock[d][l]) $fatal(1,"High Context entry not gated");
            high_depth_checks++;
          end
          buffer_gate_checks++;
        end
        if(writes>1) $fatal(1,"More than one Context entry clocked for one OC");
      end
      #0.001;
      for(int l=0;l<32;l++)
        if(dut.tmp_result[l] !== (want_input[l] ? want_tmp[l] : old_tmp[l]))
          $fatal(1,"Single tmp register data/hold mismatch lane=%0d",l);
      for(int d=0;d<OUTPUT_BUFFER_DEPTH;d++) for(int l=0;l<32;l++) if(!want_p[d][l]) begin
        if(dut.psum[d][l]!==old_p[d][l]) $fatal(1,"Gated Psum DFF changed");
        if(dut.batch_active && dut.batch_command.os_cnt==1 &&
           (dut.batch_command.as_cnt<=1 || abits(int'(dut.batch_command.precision))==4))
          bypass_psum_hold_checks++;
      end
    end
  end
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
  function automatic int lane_latency(input int lane);
    int size;
    size=0;
    for(int m=0;m<8;m++) if(golden_group[m]==lane/4) size++;
    return size<=2 ? 3 : size==4 ? 4 : 5;
  endfunction

  // Independent arithmetic history; debug snapshots are TB-only, not DUT state.
  always @(posedge clock) begin : arithmetic_scoreboard
    longint signed running_sum[0:MAX_CONTEXTS-1][0:31];
    longint signed raw_slice[0:31], saved_fa[0:31], saved_fb[0:31];
    longint signed want[0:31], fa,fb,aa,bb;
    int cx[0:31], ph,kt,c,fc;
    bit check_p[0:31],traced,is_as,acc,fusion,trace_as;
    string trace_row,op;
    if(!reset && monitoring) begin
      traced=0;trace_row="";
      for(int l=0;l<32;l++) begin
        check_p[l]=0;
        if(!dut.fusion_enable[l] && (dut.fusion_a[l]!==0 || dut.fusion_b[l]!==0))
          $fatal(1,"Unused fusion operands not isolated");
        if(!dut.acc_enable[l] && (dut.acc_a[l]!==0 || dut.acc_b[l]!==0))
          $fatal(1,"Unused acc operands not isolated");
        if(dut.tmp_valid[l]) begin
          c=dut.tmp_tag[l].ctx;ph=dut.tmp_tag[l].ph;kt=dut.tmp_tag[l].kt;
          is_as=dut.tmp_tag[l].cmd.as_cnt>1;cx[l]=c;
          if(ph==0 && kt==0) running_sum[c][l]=0;
          running_sum[c][l]+=raw_slice[l] <<< (4*ph);want[l]=running_sum[c][l];
          check_p[l]=is_as ? (dut.tmp_tag[l].cmd.os_cnt>1 || abits(int'(dut.tmp_tag[l].cmd.precision))>4) :
            (dut.tmp_tag[l].cmd.os_cnt>1 && ph==abits(int'(dut.tmp_tag[l].cmd.precision))/4-1);
          if(dut.psum_write[l]!==check_p[l]) $fatal(1,"Psum write phase mismatch");
          acc=kt>0 && (is_as ? ph==0 : check_p[l]);fusion=ph>0;
          if(dut.acc_enable[l]!==acc) $fatal(1,"Acc phase mismatch");
          if(is_as && (dut.fusion_enable[l]!==fusion)) $fatal(1,"AS fusion phase mismatch");
          if((check_p[l] || dut.result_done[l]) && dut.arithmetic_result[l]!==want[l])
            $fatal(1,"Running Context arithmetic mismatch");
          if(standard_case!=0 && !traced) begin
            fa=is_as ? dut.fusion_a[l] : saved_fa[l];fb=is_as ? dut.fusion_b[l] : saved_fb[l];
            aa=dut.acc_a[l];bb=dut.acc_b[l];trace_as=is_as;
            op=fusion ? (acc ? "fusion_then_acc" : "fusion") : acc ? "acc" : "seed";
            trace_row=$sformatf("%0d,%0d,%0d,%0d,%0d,%0d,%0d,%s,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",
              standard_case,int'(dut.tmp_tag[l].cmd.precision),int'(dut.tmp_tag[l].cmd.signed_en),kt,c,ph,l,op,
              raw_slice[l],fa,fb,aa,bb,dut.arithmetic_result[l],int'(dut.result_done[l]),dut.tmp_result[l]);
            traced=1;
          end
        end
      end
      // Save incoming reduction and WS fusion operands for the next tagged tmp consumer.
      for(int l=0;l<32;l++) if(dut.capture_valid[l]) begin
        raw_slice[l]=dut.capture_data[l];saved_fa[l]=dut.fusion_a[l];saved_fb[l]=dut.fusion_b[l];
      end
      #2;
      if(traced) begin
        fc=cycle-first_external-(trace_as ? 0 : 1);
        $fdisplay(operation_trace,"%0d,%s,%0d",cycle-first_external,trace_row,fc);$fflush(operation_trace);
      end
      for(int l=0;l<32;l++) if(check_p[l] && dut.psum[cx[l]][l]!==want[l])
        $fatal(1,"Psum history mismatch ctx=%0d lane=%0d",cx[l],l);
    end
  end

  // Capture accepted compute events before NBA, inspect raw result after NBA.
  always @(posedge clock) begin : scoreboard
    int t,c,p,idx,tag,external_ctx,external_ph;
    bit act_sample,command_sample;
    cycle=cycle+1;
    if(!reset && monitoring) begin
      if(held_cmd && (!cmd_valid_i || cmd_i!==last_cmd))
        $fatal(1,"Command changed before ready");
      if(held_act_for_cmd && act_data_i!==last_act)
        $fatal(1,"ACT payload changed while its Command was stalled");
      held_cmd=cmd_valid_i && !cmd_ready_o; last_cmd=cmd_i;
      held_act_for_cmd=cmd_valid_i && !cmd_ready_o && dut.need_plane; last_act=act_data_i;
      if(cmd_valid_i && cmd_ready_o) begin
        if(first_external<0) first_external=cycle;
        input_commands++;
      end
      command_sample=cmd_valid_i && cmd_ready_o;
      act_sample=dut.act_loading || (command_sample && !dut.packet_active);
      if(act_sample) act_planes_received++;
      external_ctx=case_as>1 ? (dut.packet_active ? dut.command_count : 0) : dut.context_idx;
      external_ph=dut.act_loading ? dut.external_phase : 0;
      if(standard_case!=0 && (command_sample || act_sample))
        $fdisplay(external_trace,"%0d,%0d,%0d,%0d,%0d,%0d,%0d,%02h,%0d,%0d,%s",
          cycle-first_external,standard_case,int'(cmd_i.precision),int'(cmd_i.signed_en),dut.tile,
          int'(command_sample),command_sample ? external_ctx : -1,cmd_i.weight_cim_raddr,
          int'(act_sample),act_sample ? external_ph : -1,
          act_sample ? $sformatf("%0256h",act_data_i) : "");
      if(dut.issue) begin
        idx=issue_count; t=idx/(case_r*case_p);
        if(case_as>1) begin p=(idx/case_r)%case_p; c=idx%case_r; end
        else begin c=(idx/case_p)%case_r; p=idx%case_p; end
        if(dut.phase!=p || dut.context_idx!=c || dut.tile!=t)
          $fatal(1,"Issue order differs from spec at index %0d",idx);
        // Check the consumed Plane, including AS reuse while external ACT
        // deliberately carries unrelated data. Sampling is tied to cmd_fire.
        for(int k=0;k<256;k++)
          if(dut.plane[4*k+:4] !== (k<case_used_digits ? 4'(activation[t][c][k]>>(4*p)) : 4'd0))
            $fatal(1,"ACT Plane sampling/reuse mismatch tile=%0d ctx=%0d phase=%0d digit=%0d",t,c,p,k);
        if(dut.command.weight_cim_raddr!==8'('h20+16*t+(case_as>1 ? c : 0)))
          $fatal(1,"Descriptor weight address mismatch");
        if(issue_count==0) first_issue=cycle;
        if(exact_ii) begin
          if(case_as>1) begin
            if(cycle-first_external != t*((case_p>case_r ? case_p : case_r)+case_r*case_p)+
                (case_p>case_r ? case_p : case_r)+p*case_r+c)
              $fatal(1,"AS external-load/internal-issue timing mismatch");
          end else if(cycle-first_external != (t*case_r+c)*2*case_p+case_p+p)
            $fatal(1,"WS external-load/internal-issue timing mismatch");
        end
        last_issue=cycle; issue_count++;
        if((dut.ren & ~dut.station)!=0) reuse_cycles++;
        if(p==case_p-1 && t==case_os-1)
          for(int l=0;l<32;l++) if(expected_mask[l]) lane_due[c][l]=cycle+lane_latency(l);
      end
      #1;
      // Per-OC publication: every lane leaves the Cluster on its own endpoint
      // latency. Premature completion is checked against the per-Context done
      // bits; the due-cycle pulse against the published lane value.
      for(int cx=0;cx<case_r;cx++) for(int l=0;l<32;l++) if(lane_due[cx][l]>=cycle) begin
        if(cycle<lane_due[cx][l] && dut.result_ready[cx][l])
          $fatal(1,"Premature terminal write ctx=%0d lane=%0d",cx,l);
        if(cycle==lane_due[cx][l] && (!dut.result_ready[cx][l] || !dut.raw_valid[l]))
          $fatal(1,"Missing direct terminal write ctx=%0d lane=%0d",cx,l);
      end
      if(dut.raw_valid!=0) begin
        if((dut.raw_valid & ~expected_mask)!=0) $fatal(1,"Raw valid on masked lane");
        for(int l=0;l<32;l++) if(out_valid_o[l]) begin
          tag=dut.raw_context[l];
          if(tag<0 || tag>=case_r) $fatal(1,"Raw context out of range %0d",tag);
          if(raw_seen[tag][l] || lane_due[tag][l]!=cycle)
            $fatal(1,"Raw latency/seen mismatch ctx=%0d lane=%0d due=%0d actual=%0d",
                   tag,l,lane_due[tag][l],cycle);
          if(psum_data_o[32*l+:32]!==32'(expected[tag][l]))
            $fatal(1,"Raw mismatch case=%0d p=%0d sign=%0d ctx=%0d lane=%0d got=%0d expected=%0d",
                cases_run,cmd_i.precision,cmd_i.signed_en,tag,l,
                $signed(dut.raw_data[32*l+:32]),expected[tag][l]);
          raw_seen[tag][l]=1; raw_count++;
        end
      end
    end
  end
  task automatic send_compute(input cluster_ctrl_t d, input logic [1023:0] data, input int gap);
    @(negedge clock); repeat(gap) @(negedge clock);
    cmd_i=d; cmd_valid_i=1; act_data_i=data;
    for(int t=0;t<TIMEOUT_CYCLES;t++) begin
      @(posedge clock);
      if(cmd_ready_o) begin #1; cmd_valid_i=0; return; end
    end
    $fatal(1,"Command timeout");
  endtask

  task automatic send_address(input cluster_ctrl_t d,input int gap);
    @(negedge clock);repeat(gap) @(negedge clock);
    cmd_i=d;cmd_valid_i=1;
    for(int q=0;q<TIMEOUT_CYCLES;q++) begin
      @(posedge clock);if(cmd_ready_o) begin #1;cmd_valid_i=0;return;end
    end
    $fatal(1,"AS descriptor timeout");
  endtask
  task automatic send_act_frame(input cluster_ctrl_t descriptor,input logic [4095:0] data,
                                input int kt,gap,input bit bubbles);
    cluster_ctrl_t d;
    int pcount,rcount;
    d=descriptor;pcount=abits(int'(d.precision))/4;rcount=d.as_cnt>1 ? int'(d.as_cnt) : 1;
    send_compute(d,data[0+:1024],gap);
    fork
      begin
        for(int ph=1;ph<pcount;ph++) begin
          @(negedge clock);act_data_i=data[1024*ph+:1024];
          @(posedge clock);#1;
        end
      end
      begin
        for(int cx=1;cx<rcount;cx++) begin
          d.weight_cim_raddr=8'('h20+16*kt+cx);
          send_address(d,bubbles ? cx%3 : 0);
        end
      end
    join
  endtask

  task automatic run_case(input int precision, input bit sign_en,
      input logic [6:0] split, input logic [7:0] en,
      input logic [31:0] oc, input logic [23:0] slots,
      input int pattern,os,ws,as_count, input bit bubbles);
    cluster_ctrl_t d;
    logic [1023:0] plane, row;
    logic [4095:0] full_act;
    int wb,ab,kr,l,slot,a_ctx,c,p,t,groups,used_digits;
    int unsigned raw;
    longint signed w,a;
    wb=wbits(precision); ab=abits(precision); kr=256/wb;
    case_os=os; case_ws=ws; case_as=as_count;
    if(os<1 || ws<1 || as_count<1 || (ws>1 && as_count>1))
      $fatal(1,"Counts must be >=1; simultaneous WS/AS reuse is not defined");
    case_r=ws>1 ? ws : as_count; case_p=ab/4;
    d='0; d.os_cnt=16'(os); d.ws_cnt=16'(ws); d.as_cnt=16'(as_count);
    d.precision=3'(precision); d.signed_en=sign_en; d.reduce_split_mask=split;
    d.macro_en_mask=en; d.macro_oc_mask=oc; d.act_slot_sel=slots;
    used_digits=0;
    for(int m=0;m<8;m++) if(en[m] && (int'(slots[3*m+:3])+1)*kr>used_digits)
      used_digits=(int'(slots[3*m+:3])+1)*kr;
    case_used_digits=used_digits;
    groups=0; decode_groups(split,0,0,8,groups);
    expected_mask='0;
    for(int cx=0;cx<case_r;cx++) begin
      for(int l=0;l<32;l++) raw_seen[cx][l]=0;
      for(int i=0;i<32;i++) begin expected[cx][i]=0; lane_due[cx][i]=-1; end
    end
    for(int kt=0;kt<os;kt++) for(int cx=0;cx<case_r;cx++)
      for(int k=0;k<256;k++) begin
        a_ctx=as_count>1 ? 0 : cx;
        if(cx==0 || as_count<=1)
          activation[kt][cx][k]=sample_bits(ab,pattern,k+7*cx+kt,sign_en,0);
        else activation[kt][cx][k]=activation[kt][0][k];
        // Keep all positive W8A16 OS extrema within signed32; no saturation.
        if(!sign_en && wb==8 && ab==16)
          activation[kt][cx][k]%= (32768/os);
      end
    // Preload every tile/context row before issuing any computation.
    for(int kt=0;kt<os;kt++) begin
      for(int wc=0;wc<(as_count>1 ? case_r : 1);wc++) begin
        @(negedge clock);
        weight_waddr_i=8'('h20+16*kt+wc); weight_wen_i=8'hff;
        for(int m=0;m<8;m++) begin
          row='0;
          for(int ocid=0;ocid<4;ocid++) for(int j=0;j<kr;j++) begin
            raw=sample_bits(wb,pattern,j+m*7+ocid*3+kt+wc*11,sign_en,1);
            for(int b=0;b<wb;b++) row[256*ocid+wb*j+b]=(raw>>b)&1;
            if(en[m] && oc[4*m+ocid]) begin
              l=4*golden_group[m]+ocid; slot=int'(slots[3*m+:3]);
              for(int cx=0;cx<case_r;cx++) if(as_count<=1 || cx==wc) begin
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
    issue_count=0;raw_count=0;first_issue=-1;last_issue=-1;first_external=-1;input_commands=0;act_planes_received=0;
    exact_ii=!bubbles;
    held_cmd=0; held_act_for_cmd=0;
    monitoring=1;
    for(int kt=0;kt<os;kt++) for(int cx=0;cx<(as_count>1 ? 1 : case_r);cx++) begin
      d.weight_cim_raddr=8'('h20+16*kt);
      full_act='0;
      for(int ph=0;ph<case_p;ph++) for(int k=0;k<used_digits;k++)
        full_act[1024*ph+4*k+:4]=4'(activation[kt][cx][k]>>(4*ph));
      send_act_frame(d,full_act,kt,bubbles ? (kt+cx)%3 : 0,bubbles);
    end
    // Internal distribution must use the saved ACT, not these external pins.
    @(negedge clock);act_data_i=~full_act[0+:1024];
    for(int wait_cycles=0;wait_cycles<TIMEOUT_CYCLES;wait_cycles++) begin
      @(negedge clock);
      if(raw_count==case_r*$countones(expected_mask)) break;
      if(wait_cycles==TIMEOUT_CYCLES-1) $fatal(1,"Output timeout");
    end
    if(raw_count!=case_r*$countones(expected_mask) || issue_count!=os*case_r*case_p || input_commands!=os*case_r)
      $fatal(1,"Lost/duplicate compute or result");
    if(act_planes_received!=os*(as_count>1 ? 1 : case_r)*case_p)
      $fatal(1,"ACT frame slice count mismatch");
    repeat(6) @(negedge clock);
    if(dut.raw_valid!=0 || dut.batch_active)
      $fatal(1,"Unexpected output after the final Context published");
    monitoring=0; cases_run++;
  endtask

  initial begin : regression
    int legal_count,n,r;
    string data_dir;
    logic [23:0] standard_slots;
    logic [7:0] standard_en;
    logic [6:0] standard_split;
    if(OS_TILES<1 || OS_TILES>14 || PATTERNS<1 || PATTERNS>6 || SEED==0)
      $fatal(1,"Require OS_TILES 1..14 (distinct preload rows), PATTERNS 1..6, nonzero seed");
    for(int mask=0;mask<128;mask++) if(canonical(7'(mask))) canonical_count++;
    if(canonical_count!=26) $fatal(1,"Expected 26 canonical trees");
    data_dir=".";
    if($value$plusargs("DATA_DIR=%s",data_dir)) begin end
    manifest=$fopen($sformatf("%s/split_cases.csv",data_dir),"w");
    operation_trace=$fopen($sformatf("%s/buffer_operations.csv",data_dir),"w");
    external_trace=$fopen($sformatf("%s/external_inputs.csv",data_dir),"w");
    if(!manifest || !operation_trace || !external_trace) $fatal(1,"Cannot open CSV output directory %s",data_dir);
    $fdisplay(external_trace,"input_cycle,case,precision,signed_en,tile,command,context,weight_address,act_sample,phase,act_hex");
    $fdisplay(operation_trace,"compute_cycle,case,precision,signed_en,tile,context,phase,lane,operation,tmp,fusion_a,fusion_b,acc_a,acc_b,result,done,tmp_stored,fusion_cycle");
    $fdisplay(manifest,"precision,signed_en,split_mask_hex,en_mask_hex,oc_mask_hex,slots_hex,group0_K,group1_K,group2_K,group3_K,group4_K,group5_K,group6_K,group7_K");
    repeat(4) @(negedge clock); reset=0;
    repeat(2) @(negedge clock);
    if($test$plusargs("FULL_ACT_TEST")) begin
      for(int sign_mode=0;sign_mode<2;sign_mode++) for(int tiles=1;tiles<=2;tiles++)
        for(int mode=0;mode<3;mode++)
          run_case(6,1'(sign_mode),7'h00,8'hff,32'hffffffff,24'hfac688,
                   0,tiles,mode==1 ? 2 : 1,mode==2 ? 2 : 1,0);
      $display("PASS full_act_4096 cases=%0d",cases_run);$finish;
    end
    // Separate directed suite: mixed pair/quad endpoints may publish
    // different Contexts on the same edge. Keep standard case IDs unchanged.
    if($test$plusargs("MIXED_CONTEXT_TEST")) begin
      for(int p=2;p<=4;p++) for(int sign_mode=0;sign_mode<2;sign_mode++)
        for(int tiles=1;tiles<=2;tiles++) for(int mode=0;mode<2;mode++)
          run_case(p,1'(sign_mode),7'h03,8'h55,32'hffffffff,24'h040000,
                   0,tiles,mode==0 ? 2 : 1,mode==1 ? 2 : 1,0);
      $fclose(manifest); $fclose(operation_trace);
      $display("PASS mixed_context cases=%0d",cases_run);
      $finish;
    end
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
                     pattern,OS_TILES,1,1,pattern==0);
        end
      end
      $display("precision=%0d W%0dA%0d splits/sign=%0d",p,wbits(p),abits(p),legal_count);
      case(wbits(p))
        2: begin standard_slots=24'h208208; standard_en=8'h55; standard_split=7'h07; end
        4: begin standard_slots=24'h688688; standard_en=8'h33; standard_split=7'h01; end
        default: begin standard_slots=24'hfac688; standard_en=8'h0f; standard_split=0; end
      endcase
      // Six chapter-4 schedules, both signs; K=128 per tile, high plane half 0.
      for(int s=0;s<2;s++) for(int mode=0;mode<6;mode++) begin
        standard_case=mode+1;
        run_case(p,1'(s),standard_split,standard_en,32'hffffffff,standard_slots,
                 0,mode<3 ? 1 : 2, (mode==2 || mode==4) ? 2 : 1,
                 (mode==1 || mode==5) ? 2 : 1,0);
      end
      standard_case=0;
      // Six interleaved Contexts keep several raw vectors in flight at once:
      // check ordered publication with Command gaps, downstream always ready.
      r=6;
      if(r>MAX_CONTEXTS) r=MAX_CONTEXTS;
      if(r>OUTPUT_BUFFER_DEPTH) r=OUTPUT_BUFFER_DEPTH;
      for(int s=0;s<2;s++) for(int mode=0;mode<2;mode++)
        run_case(p,1'(s),standard_split,standard_en,32'hffffffff,standard_slots,
                 0,2,mode==0 ? r : 1,mode==1 ? r : 1,1);
      // Three Tiles and three interleaved Contexts: catch history overwrite
      // beyond the two-Tile/two-Context examples, with signed extrema too.
      for(int s=0;s<2;s++) for(int mode=0;mode<2;mode++)
        for(int pattern=4;pattern<6;pattern++)
          run_case(p,1'(s),standard_split,standard_en,32'hffffffff,standard_slots,
                   pattern,3,mode==0 ? (OUTPUT_BUFFER_DEPTH<3 ? OUTPUT_BUFFER_DEPTH : 3) : 1,
                             mode==1 ? (OUTPUT_BUFFER_DEPTH<3 ? OUTPUT_BUFFER_DEPTH : 3) : 1,1);
    end
    $fclose(manifest);
    $fclose(operation_trace);
    $fclose(external_trace);
    if(reuse_cycles==0)
      $fatal(1,"Missing coverage: reuse=%0d",reuse_cycles);
    for(int n=1;n<7;n++) begin
      if(dut.u_reduce.gated_checks[n]==0) $fatal(1,"No gated hold checks for node %0d",n);
      $display("CG node=t%0d active_edges=%0d gated_OC_checks=%0d",n,
        dut.u_reduce.active_edges[n],dut.u_reduce.gated_checks[n]);
    end
    if(dut.tmp_only_steps==0 || dut.as_seed_steps==0 || dut.as_fusion_steps==0 ||
       dut.as_acc_steps==0 || dut.ws_fusion_steps==0 || dut.ws_acc_steps==0 ||
       dut.ws_tile_commits==0 || dut.a4_acc_steps==0)
      $fatal(1,"Missing tmp/fusion/acc routing coverage");
    $display("TMP_ROUTES os1=%0d AS_seed=%0d AS_fusion=%0d AS_acc=%0d WS_fusion=%0d WS_acc=%0d WS_tile_commit=%0d A4_acc=%0d",
      dut.tmp_only_steps,dut.as_seed_steps,dut.as_fusion_steps,dut.as_acc_steps,
      dut.ws_fusion_steps,dut.ws_acc_steps,dut.ws_tile_commits,dut.a4_acc_steps);
    if(buffer_gate_checks==0 || bypass_psum_hold_checks==0 ||
       (OUTPUT_BUFFER_DEPTH>2 && high_depth_checks==0)) $fatal(1,"Missing buffer gate checks");
    $display("BUFFER_ICG checks=%0d high_depth=%0d bypass_Psum_hold=%0d depth=%0d",
      buffer_gate_checks,high_depth_checks,bypass_psum_hold_checks,OUTPUT_BUFFER_DEPTH);
    $display("PASS configurations=%0d cases=%0d reuse=%0d seed=%08h",
      configurations,cases_run,reuse_cycles,SEED);
`ifdef CLUSTER_FSDB
    $fsdbDumpoff;
`endif
    $finish;
  end
  initial begin #200000000; $fatal(1,"Global watchdog"); end
  // FSDB waveform dump for Verdi (tasks registered via -P novas.tab in Makefile)
`ifdef CLUSTER_FSDB
  initial begin : fsdb_dump
    $display("The simulation started.");
    $fsdbDumpfile("tb_Cluster_2026.fsdb");
    $fsdbDumpvars(0, tb_Cluster, "+all");
    $fsdbDumpon;
  end
`endif
endmodule
