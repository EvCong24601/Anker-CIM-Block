`timescale 1ns/1ps
// Independent per-tap check: all 26 trees, 8 EN patterns, changing every cycle.
module tb_ClusterReduceTree;
  import cluster_tb_pkg::*;
  logic clock=0,reset=1;
  always #5 clock=~clock;
  logic early_valid_i=0,valid_i=0;
  logic [6:0] early_split_i=0,split_i=0;
  logic [7:0] early_en_i=0,en_i=0;
  logic [31:0] early_oc_i=0,oc_i=0;
  logic [575:0] early_data=0,macro_data_i=0;
  wire [2:0] tap_valid_o;
  wire [31:0] tap_mask_o[0:2];
  wire [671:0] tap_data_o[0:2];
  ClusterReduceTree dut(.*);
  int index=0,ids[0:2],events=0,expected_events=0;
  bit valids[0:2];
  int owners[0:7],depths[0:7],widths[0:7];
  int case_width[0:207][0:7];
  logic [7:0] case_en[0:207];
  logic [31:0] case_oc[0:207];
  logic [31:0] masks[0:207][0:2];
  longint signed expected[0:207][0:31];
  task automatic decode(input int node,first,size,input logic [6:0] s,inout int g);
    if(size==1 || !s[node]) begin
      for(int m=first;m<first+size;m++) begin
        owners[m]=g; depths[m]=size<=2 ? 0 : size==4 ? 1 : 2; widths[m]=size;
      end
      g++;
    end else begin
      decode(node*2+1,first,size/2,s,g);
      decode(node*2+2,first+size/2,size/2,s,g);
    end
  endtask
  always_ff @(posedge clock or posedge reset) begin
    if(reset) begin
      valid_i<=0; split_i<=0; en_i<=0; oc_i<=0; macro_data_i<=0;
      for(int d=0;d<3;d++) begin ids[d]<=0; valids[d]<=0; end
    end else begin
      valid_i<=early_valid_i; split_i<=early_split_i; en_i<=early_en_i;
      oc_i<=early_oc_i; macro_data_i<=early_data;
      ids[0]<=index; ids[1]<=ids[0]; ids[2]<=ids[1];
      valids[0]<=early_valid_i; valids[1]<=valids[0]; valids[2]<=valids[1];
    end
  end
  always @(posedge clock) begin : check
    logic [31:0] mask;
    logic [3:0] expected_gate;
    int id,stage,first,size;
    #2;
    if(!reset) for(int stage=0;stage<3;stage++) begin
      mask=valids[stage] ? masks[ids[stage]][stage] : 0;
      if(tap_valid_o[stage] !== (|mask) || tap_mask_o[stage]!==mask)
        $fatal(1,"Terminal tap valid/mask mismatch case=%0d stage=%0d",ids[stage],stage);
      if(tap_valid_o[stage]) begin
        for(int l=0;l<32;l++) if(mask[l] &&
            $signed(tap_data_o[stage][21*l+:21])!==expected[ids[stage]][l])
          $fatal(1,"Terminal tap data mismatch case=%0d stage=%0d lane=%0d",ids[stage],stage,l);
        events++;
      end
    end
    // Independent gate prediction from recursively decoded group widths,
    // rather than reusing the RTL's forward_mask function.
    if(!reset) for(int n=1;n<7;n++) begin
      stage=n<3 ? 1 : 0; id=ids[stage];
      size=n<3 ? 4 : 2; first=n<3 ? (n-1)*4 : (n-3)*2;
      expected_gate=0;
      if(valids[stage] && case_width[id][first]>size)
        for(int m=0;m<8;m++) if(m>=first && m<first+size)
          for(int c=0;c<4;c++) if(case_en[id][m] && case_oc[id][4*m+c]) expected_gate[c]=1;
      if(dut.reduce_cg_en[n]!== (|expected_gate) || dut.cg_channel_req[n]!==expected_gate)
        $fatal(1,"Incorrect forwarding gate at terminal/nonterminal node t%0d",n);
    end
  end
  initial begin : run
    int g,l,case_count;
    logic [7:0] test_en;
    case_count=0;
    repeat(3) @(negedge clock); reset=0;
    for(int mode=0;mode<8;mode++) begin
      case(mode)
        0:test_en=8'hff; 1:test_en=8'h0f; 2:test_en=8'hf0; 3:test_en=8'h55;
        4:test_en=8'haa; 5:test_en=8'h81; 6:test_en=8'h01; default:test_en=0;
      endcase
      for(int tree=0;tree<128;tree++) if(canonical(7'(tree))) begin
        @(negedge clock);
        index=case_count; early_valid_i=1; early_split_i=7'(tree); early_en_i=test_en;
        early_oc_i=index%3==0 ? 32'hffffffff : index%3==1 ? 32'h84218421 : 32'h12345678;
        g=0; decode(0,0,8,early_split_i,g);
        case_en[index]=early_en_i; case_oc[index]=early_oc_i;
        for(int m=0;m<8;m++) case_width[index][m]=widths[m];
        for(int d=0;d<3;d++) masks[index][d]='0;
        for(int i=0;i<32;i++) expected[index][i]=0;
        for(int m=0;m<8;m++) for(int c=0;c<4;c++) begin
          early_data[72*m+18*c+:18]=18'((index%2 ? -1 : 1)*(1000+index*17+m*31+c*13));
          if(early_en_i[m] && early_oc_i[4*m+c]) begin
            l=4*owners[m]+c; masks[index][depths[m]][l]=1;
            expected[index][l]+=$signed(early_data[72*m+18*c+:18]);
          end
        end
        for(int d=0;d<3;d++) if(masks[index][d]!=0) expected_events++;
        case_count++;
      end
      @(negedge clock); early_valid_i=0;
      repeat(2) @(negedge clock);
    end
    @(negedge clock); early_valid_i=0;
    repeat(6) @(negedge clock);
    if(case_count!=208 || events!=expected_events) $fatal(1,"Terminal tap lost/duplicate result");
    for(int n=1;n<7;n++) begin
      if(dut.active_edges[n]==0 || dut.gated_checks[n]==0) $fatal(1,"Missing gating coverage t%0d",n);
      $display("CG_UNIT forwarding_DFF=t%0d active_edges=%0d gated_checks=%0d",n,
               dut.active_edges[n],dut.gated_checks[n]);
    end
    for(int d=0;d<3;d++)
      if(dut.downstream_hold_checks[d]==0) $fatal(1,"Missing downstream adder hold check");
    $display("PASS reduce_clock_gating cases=%0d terminal_tap_events=%0d",case_count,events);
    $finish;
  end
  initial begin #100000; $fatal(1,"Reduce test timeout"); end
endmodule
