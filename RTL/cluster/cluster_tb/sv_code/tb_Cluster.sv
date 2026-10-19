`timescale 1ns/1ps
module tb_Cluster;
  import cluster_tb_pkg::*;
  parameter logic [7:0] EN_MASK=8'hff;
  parameter logic [31:0] OC_MASK=32'hffff_ffff;
  parameter int OS_TILES=1;
  parameter int PATTERNS=6;
  parameter int OUTPUT_BUFFER_DEPTH=4; // signed32 entries in EACH output channel
  parameter int PSUM_BUFFER_DEPTH=16; // Context entries per channel, separate from output FIFO
  parameter int TIMEOUT_CYCLES=4000;
  parameter logic [31:0] SEED=32'h19e2a407;
  localparam int MAX_CONTEXTS=16;
  logic clock=0;
  always #5 clock=~clock;
  logic reset=1;
  cluster_ctrl_t cmd_i='0;
  logic cmd_valid_i=0, out_ready_i=0;
  wire cmd_ready_o, out_valid_o;
  logic [1023:0] act_data_i='0;
  logic [7:0] weight_wen_i=0, weight_waddr_i=0;
  logic [8191:0] weight_wdata_i=0;
  wire [1023:0] psum_data_o;
  wire [31:0] psum_lane_valid_o;
  cluster_dut_adapter #(.OUTPUT_BUFFER_DEPTH(OUTPUT_BUFFER_DEPTH),
                       .MAX_CONTEXTS(MAX_CONTEXTS),.PSUM_BUFFER_DEPTH(PSUM_BUFFER_DEPTH)) dut(.*);
  logic [31:0] rng=SEED;
  int unsigned activation[0:255][0:MAX_CONTEXTS-1][0:255];
  longint signed expected[0:MAX_CONTEXTS-1][0:31];
  logic [31:0] expected_mask;
  int golden_group[0:7];
  int cases_run=0, configurations=0, canonical_count=0, manifest;
  int standard_case=0; // six distinct chapter-4 configurations
  int cycle=0, issue_count, raw_count, output_count;
  int case_os, case_ws, case_as, case_r, case_p, first_issue, last_issue;
  int case_used_digits;
  int final_due[0:MAX_CONTEXTS-1];
  int final_slot[0:MAX_CONTEXTS-1],lane_due[0:MAX_CONTEXTS-1][0:31];
  bit raw_seen[0:MAX_CONTEXTS-1], output_seen[0:MAX_CONTEXTS-1];
  bit monitoring=0, stress=0, exact_ii=0;
  int stalled_cycles=0, reuse_cycles=0, full_cycles=0;
  bit held_output=0;
  logic [1023:0] last_data;
  logic [31:0] last_mask;
  bit held_cmd=0, held_act_for_cmd=0;
  cluster_ctrl_t last_cmd;
  logic [1023:0] last_act;
  int buffer_gate_checks=0, high_depth_checks=0, os1_psum_hold_checks=0;
  int operation_trace;

  function automatic int unsigned rand32();
    rng=rng^(rng<<13); rng=rng^(rng>>17); rng=rng^(rng<<5); return rng;
  endfunction

  always @(posedge clock) begin : buffer_clock_scoreboard
    longint signed old_p[0:PSUM_BUFFER_DEPTH-1][0:31];
    longint signed old_t[0:MAX_CONTEXTS-1][0:31];
    bit want_p[0:PSUM_BUFFER_DEPTH-1][0:31];
    bit want_t[0:MAX_CONTEXTS-1][0:31];
    logic [31:0] want_input;
    int c,ph,ab;
    if(!reset) begin
      want_input=dut.capture_valid;
      for(int d=0;d<PSUM_BUFFER_DEPTH;d++) for(int l=0;l<32;l++) begin
        old_p[d][l]=dut.psum[d][l]; want_p[d][l]=0;
      end
      for(int d=0;d<MAX_CONTEXTS;d++) for(int l=0;l<32;l++) begin
        old_t[d][l]=dut.tmp_buffer[d][l]; want_t[d][l]=0;
      end
      for(int l=0;l<32;l++) if(dut.tmp_valid[l]) begin
        c=dut.tmp_tag[l].ctx; ph=dut.tmp_tag[l].ph;
        ab=abits(int'(dut.tmp_tag[l].cmd.precision));
        if(dut.tmp_tag[l].cmd.os_cnt==1)
          want_t[dut.tmp_tag[l].cmd.as_cnt>1 ? c : 0][l]=ab>4;
        else if(dut.tmp_tag[l].cmd.as_cnt>1) want_p[c][l]=1;
        else begin want_t[0][l]=ab>4; want_p[c][l]=ph==ab/4-1; end
      end
      #0.001;
      if(dut.tmp_input_clock!==want_input)
        $fatal(1,"Advance tmp-input ICG prediction mismatch");
      for(int d=0;d<PSUM_BUFFER_DEPTH;d++) for(int l=0;l<32;l++) begin
        if(dut.psum_clock[d][l]!==want_p[d][l])
          $fatal(1,"Advance Psum ICG mismatch depth=%0d lane=%0d",d,l);
        if(dut.batch_active && d>=dut.batch_contexts) begin
          if(dut.psum_depth_open[d] || dut.psum_clock[d][l])
            $fatal(1,"High address Psum depth was not gated for batch");
          high_depth_checks++;
        end
        buffer_gate_checks++;
      end
      for(int d=0;d<MAX_CONTEXTS;d++) for(int l=0;l<32;l++)
        if(dut.tmp_state_clock[d][l]!==want_t[d][l])
          $fatal(1,"Advance tmp-state ICG mismatch depth=%0d lane=%0d",d,l);
      #0.001;
      for(int d=0;d<PSUM_BUFFER_DEPTH;d++) for(int l=0;l<32;l++)
        if(!want_p[d][l]) begin
          if(dut.psum[d][l]!==old_p[d][l]) $fatal(1,"Gated Psum DFF changed");
          if(dut.batch_active && dut.batch_command.os_cnt==1) os1_psum_hold_checks++;
        end
      for(int d=0;d<MAX_CONTEXTS;d++) for(int l=0;l<32;l++)
        if(!want_t[d][l] && dut.tmp_buffer[d][l]!==old_t[d][l])
          $fatal(1,"Gated tmp-state DFF changed");
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
  function automatic int result_latency();
    int size,delay;
    delay=0;
    for(int g=0;g<8;g++) if(expected_mask[4*g+:4]!=0) begin
      size=0;
      for(int m=0;m<8;m++) if(golden_group[m]==g) size++;
      if((size<=2 ? 2 : size==4 ? 3 : 4)>delay) delay=size<=2 ? 2 : size==4 ? 3 : 4;
    end
    return delay+1; // tree -> tmp DFF -> arithmetic/storage
  endfunction
  function automatic int lane_latency(input int lane);
    int size;
    size=0;
    for(int m=0;m<8;m++) if(golden_group[m]==lane/4) size++;
    return size<=2 ? 3 : size==4 ? 4 : 5;
  endfunction

  // Check intermediate history independently of the DUT's route enables.
  // A mathematical running sum checks AS's reuse of the same Context entry;
  // a separate Tile sum checks WS's tmp history and final-only Psum writes.
  always @(posedge clock) begin : arithmetic_scoreboard
    longint signed tile_sum[0:MAX_CONTEXTS-1][0:31];
    longint signed running_sum[0:MAX_CONTEXTS-1][0:31];
    longint signed want[0:31], old_psum[0:31];
    int cx[0:31], ti[0:31];
    bit check_p[0:31], check_t[0:31], no_p[0:31];
    int ph,kt,c,ab;
    bit traced;
    string trace_row, op;
    if(!reset && monitoring) begin
      traced=0; trace_row="";
      for(int l=0;l<32;l++) begin
        check_p[l]=0; check_t[l]=0; no_p[l]=0;
        if(!dut.fusion_enable[l] && (dut.fusion_a[l]!==0 || dut.fusion_b[l]!==0))
          $fatal(1,"Unused fusion operands not isolated");
        if(!dut.acc_enable[l] && (dut.acc_a[l]!==0 || dut.acc_b[l]!==0))
          $fatal(1,"Unused acc operands not isolated");
        if(dut.tmp_valid[l]) begin
          c=dut.tmp_tag[l].ctx; ph=dut.tmp_tag[l].ph; kt=dut.tmp_tag[l].kt;
          ab=abits(int'(dut.tmp_tag[l].cmd.precision));
          cx[l]=c; ti[l]=dut.tmp_tag[l].cmd.as_cnt>1 ? c : 0;
          if(ph==0) tile_sum[c][l]=0;
          if(ph==0 && kt==0) running_sum[c][l]=0;
          tile_sum[c][l]+=dut.tmp_result[l] <<< (4*ph);
          running_sum[c][l]+=dut.tmp_result[l] <<< (4*ph);
          if(dut.tmp_tag[l].cmd.os_cnt==1) begin
            check_t[l]=ab>4; want[l]=tile_sum[c][l];
            no_p[l]=1; old_psum[l]=dut.psum[c][l];
            if(dut.psum_write[l] || dut.acc_enable[l])
              $fatal(1,"os=1 must bypass Psum state and acc");
          end else if(dut.tmp_tag[l].cmd.as_cnt>1) begin
            check_p[l]=1; want[l]=running_sum[c][l];
            if(dut.fusion_enable[l] && dut.acc_enable[l])
              $fatal(1,"AS must select fusion OR acc, never cascade");
            if(dut.acc_enable[l] !== (ph==0 && kt>0) ||
               dut.fusion_enable[l] !== (ph>0))
              $fatal(1,"AS phase/Tile route mismatch");
          end else begin
            check_t[l]=ab>4; want[l]=tile_sum[c][l];
            if(ph==ab/4-1) begin check_p[l]=1; end
            else begin no_p[l]=1; old_psum[l]=dut.psum[c][l]; end
          end
          if(dut.result_done[l] && dut.arithmetic_result[l]!==running_sum[c][l])
            $fatal(1,"Tmp arithmetic lost slice / prior Tile history");
          if(standard_case!=0 && !traced) begin
            op=dut.fusion_enable[l] ? (dut.acc_enable[l] ? "fusion+acc" : "fusion") :
               dut.acc_enable[l] ? "acc" : "seed";
            trace_row=$sformatf("%0d,%0d,%0d,%0d,%0d,%0d,%0d,%s,%0d,%0d,%0d,%0d,%0d,%0d,%0d",
              standard_case,int'(dut.tmp_tag[l].cmd.precision),int'(dut.tmp_tag[l].cmd.signed_en),
              kt,c,ph,l,op,dut.tmp_result[l],dut.fusion_a[l],dut.fusion_b[l],
              dut.acc_a[l],dut.acc_b[l],dut.arithmetic_result[l],int'(dut.result_done[l]));
            traced=1;
          end
        end
      end
      #2;
      if(traced) begin
        $fdisplay(operation_trace,"%0d,%s",cycle-first_issue,trace_row);
        $fflush(operation_trace);
      end
      for(int l=0;l<32;l++) begin
        if(check_t[l] && dut.tmp_buffer[ti[l]][l]!==tile_sum[cx[l]][l])
          $fatal(1,"Tmp fusion state mismatch ctx=%0d lane=%0d",cx[l],l);
        if(check_p[l] && dut.psum[cx[l]][l]!==running_sum[cx[l]][l])
          $fatal(1,"Psum history mismatch ctx=%0d lane=%0d",cx[l],l);
        if(no_p[l] && dut.psum[cx[l]][l]!==old_psum[l])
          $fatal(1,"Psum changed on a tmp-only step");
      end
    end
  end

  // Capture accepted compute events before NBA, inspect raw result after NBA.
  always @(posedge clock) begin : scoreboard
    int t,c,p,idx,tag;
    cycle=cycle+1;
    if(reset) begin held_output=0; end
    else if(monitoring) begin
      if(held_cmd && (!cmd_valid_i || cmd_i!==last_cmd))
        $fatal(1,"Command changed before ready");
      if(held_act_for_cmd && act_data_i!==last_act)
        $fatal(1,"ACT payload changed while its Command was stalled");
      held_cmd=cmd_valid_i && !cmd_ready_o; last_cmd=cmd_i;
      held_act_for_cmd=cmd_valid_i && !cmd_ready_o && dut.need_plane; last_act=act_data_i;
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
        else if(exact_ii && cycle!=last_issue+1)
          $fatal(1,"Unexpected bubble in v2.7 schedule");
        last_issue=cycle; issue_count++;
        if((dut.ren & ~dut.station)!=0) reuse_cycles++;
        if(p==case_p-1 && t==case_os-1) begin
          final_due[c]=cycle+result_latency(); final_slot[c]=dut.wr_ptr;
          for(int l=0;l<32;l++) if(expected_mask[l]) lane_due[c][l]=cycle+lane_latency(l);
        end
      end
      #1;
      // Verify actual per-channel output-buffer writes, including early lanes
      // of mixed trees, rather than checking only whole-Context publication.
      for(int cx=0;cx<case_r;cx++) for(int l=0;l<32;l++) if(lane_due[cx][l]>=cycle) begin
        if(cycle<lane_due[cx][l] && dut.ready_mask[final_slot[cx]][l])
          $fatal(1,"Premature terminal write ctx=%0d lane=%0d",cx,l);
        if(cycle==lane_due[cx][l] && (!dut.ready_mask[final_slot[cx]][l] ||
            dut.output_buffer[l][final_slot[cx]]!==32'(expected[cx][l])))
          $fatal(1,"Missing/incorrect direct terminal write ctx=%0d lane=%0d",cx,l);
      end
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
        if(final_due[c0]==cycle && !raw_seen[c0]) $fatal(1,"Missing raw output at terminal-dependent latency");
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
  task automatic send_compute(input cluster_ctrl_t d, input logic [1023:0] data, input int gap);
    @(negedge clock); repeat(gap) @(negedge clock);
    cmd_i=d; cmd_valid_i=1; act_data_i=data;
    for(int t=0;t<TIMEOUT_CYCLES;t++) begin
      @(posedge clock);
      if(cmd_ready_o) begin #1; cmd_valid_i=0; return; end
    end
    $fatal(1,"Command timeout");
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
      final_due[cx]=-1; raw_seen[cx]=0; output_seen[cx]=0;
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
    issue_count=0; raw_count=0; output_count=0; first_issue=-1; last_issue=-1;
    stress=pressure; exact_ii=!pressure && !bubbles;
    held_output=0; held_cmd=0; held_act_for_cmd=0;
    monitoring=1;
    for(int index=0;index<os*case_r*case_p;index++) begin
      t=index/(case_r*case_p);
      if(as_count>1) begin p=(index/case_r)%case_p; c=index%case_r; end
      else begin c=(index/case_p)%case_r; p=index%case_p; end
      d.weight_cim_raddr=8'('h20+16*t+(as_count>1 ? c : 0));
      plane='0;
      for(int k=0;k<used_digits;k++) plane[4*k+:4]=4'(activation[t][c][k]>>(4*p));
      // Reused AS Contexts must ignore external ACT entirely.
      send_compute(d,(as_count>1 && c>0) ? ~plane : plane,bubbles ? index%3 : 0);
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
    string data_dir;
    logic [23:0] standard_slots;
    logic [7:0] standard_en;
    logic [6:0] standard_split;
    if(OS_TILES<1 || OS_TILES>14 || PATTERNS<1 || PATTERNS>6 || SEED==0)
      $fatal(1,"Require OS_TILES 1..14 (distinct preload rows), PATTERNS 1..6, nonzero seed");
    if(OUTPUT_BUFFER_DEPTH<1) $fatal(1,"Depth must be >=1");
    for(int mask=0;mask<128;mask++) if(canonical(7'(mask))) canonical_count++;
    if(canonical_count!=26) $fatal(1,"Expected 26 canonical trees");
    data_dir=".";
    if($value$plusargs("DATA_DIR=%s",data_dir)) begin end
    manifest=$fopen($sformatf("%s/split_cases.csv",data_dir),"w");
    operation_trace=$fopen($sformatf("%s/buffer_operations.csv",data_dir),"w");
    if(!manifest || !operation_trace) $fatal(1,"Cannot open CSV output directory %s",data_dir);
    $fdisplay(operation_trace,"compute_cycle,case,precision,signed_en,tile,context,phase,lane,operation,tmp,fusion_a,fusion_b,acc_a,acc_b,result,done");
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
                     pattern,OS_TILES,1,1,0,pattern==0);
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
                 (mode==1 || mode==5) ? 2 : 1,OUTPUT_BUFFER_DEPTH<2,0);
      end
      standard_case=0;
      // More contexts than output entries: force full, wrap, Command gaps and backpressure.
      r=OUTPUT_BUFFER_DEPTH+2;
      if(r>MAX_CONTEXTS) r=MAX_CONTEXTS;
      if(r>PSUM_BUFFER_DEPTH) r=PSUM_BUFFER_DEPTH;
      for(int s=0;s<2;s++) for(int mode=0;mode<2;mode++)
        run_case(p,1'(s),standard_split,standard_en,32'hffffffff,standard_slots,
                 0,2,mode==0 ? r : 1,mode==1 ? r : 1,1,1);
      // Three Tiles and three interleaved Contexts: catch history overwrite
      // beyond the two-Tile/two-Context examples, with signed extrema too.
      for(int s=0;s<2;s++) for(int mode=0;mode<2;mode++)
        for(int pattern=4;pattern<6;pattern++)
          run_case(p,1'(s),standard_split,standard_en,32'hffffffff,standard_slots,
                   pattern,3,mode==0 ? (PSUM_BUFFER_DEPTH<3 ? PSUM_BUFFER_DEPTH : 3) : 1,
                             mode==1 ? (PSUM_BUFFER_DEPTH<3 ? PSUM_BUFFER_DEPTH : 3) : 1,1,1);
    end
    $fclose(manifest);
    $fclose(operation_trace);
    if(reuse_cycles==0 || (OUTPUT_BUFFER_DEPTH<MAX_CONTEXTS && OUTPUT_BUFFER_DEPTH<PSUM_BUFFER_DEPTH &&
                          (full_cycles==0 || stalled_cycles==0)))
      $fatal(1,"Missing coverage: reuse=%0d full=%0d stalls=%0d",reuse_cycles,full_cycles,stalled_cycles);
    for(int n=1;n<7;n++) begin
      if(dut.u_reduce.gated_checks[n]==0) $fatal(1,"No gated hold checks for node %0d",n);
      $display("CG node=t%0d active_edges=%0d gated_OC_checks=%0d",n,
        dut.u_reduce.active_edges[n],dut.u_reduce.gated_checks[n]);
    end
    if(dut.tmp_only_steps==0 || dut.as_seed_steps==0 || dut.as_fusion_steps==0 ||
       dut.as_acc_steps==0 || dut.ws_fusion_steps==0 || dut.ws_acc_steps==0 ||
       dut.ws_serial_steps==0 || dut.a4_acc_steps==0)
      $fatal(1,"Missing tmp/fusion/acc routing coverage");
    $display("TMP_ROUTES os1=%0d AS_seed=%0d AS_fusion=%0d AS_acc=%0d WS_fusion=%0d WS_acc=%0d WS_serial=%0d A4_acc=%0d",
      dut.tmp_only_steps,dut.as_seed_steps,dut.as_fusion_steps,dut.as_acc_steps,
      dut.ws_fusion_steps,dut.ws_acc_steps,dut.ws_serial_steps,dut.a4_acc_steps);
    if(buffer_gate_checks==0 || os1_psum_hold_checks==0 ||
       (PSUM_BUFFER_DEPTH>2 && high_depth_checks==0)) $fatal(1,"Missing buffer gate checks");
    $display("BUFFER_ICG checks=%0d high_depth=%0d os1_Psum_hold=%0d depth=%0d",
      buffer_gate_checks,high_depth_checks,os1_psum_hold_checks,PSUM_BUFFER_DEPTH);
    $display("PASS configurations=%0d cases=%0d depth/channel=%0d reuse=%0d full=%0d stalls=%0d seed=%08h",
      configurations,cases_run,OUTPUT_BUFFER_DEPTH,reuse_cycles,full_cycles,stalled_cycles,SEED);
    $finish;
  end
  initial begin #200000000; $fatal(1,"Global watchdog"); end
endmodule
