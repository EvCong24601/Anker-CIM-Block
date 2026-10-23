// 输入驱动与命令日志：下降沿驱动，上升沿握手；ACT 尾部 Plane 连续提供。
// 本文件在父 TB 的 module 作用域内 include，不作为独立编译单元。
// 共享信号/计数器在父 TB 声明；不要添加 module 或额外 begin/end 层次。

  // Log external descriptors, not the later internal Macro compute issues.
  // cases_run and input_commands are zero-based and match the scoreboard.
  task automatic display_command(input string event_name, input cluster_ctrl_t d);
    $display("[CMD_%s] time=%0.3f ns cycle=%0d case=%0d standard_case=%0d cmd=%0d tile=%0d context=%0d kind=%0s mode=%0s precision=%0d W%0dA%0d signed_en=%0d pattern=%0d bubbles=%0d os_cnt=%0d ws_cnt=%0d as_cnt=%0d reduce_split_mask=0x%02h macro_en_mask=0x%02h macro_oc_mask=0x%08h weight_cim_raddr=0x%02h act_slot_sel=0x%06h depth=%0d seed=0x%08h",
      event_name,$realtime,cycle,cases_run,standard_case,input_commands,
      input_commands/case_r,input_commands%case_r,
      (d.as_cnt>1 && input_commands%case_r!=0) ? "ADDRESS" : "ACT",
      d.as_cnt>1 ? "AS" : d.ws_cnt>1 ? "WS" : "SINGLE",
      d.precision,wbits(int'(d.precision)),abits(int'(d.precision)),d.signed_en,
      case_pattern,case_bubbles,d.os_cnt,d.ws_cnt,d.as_cnt,d.reduce_split_mask,
      d.macro_en_mask,d.macro_oc_mask,d.weight_cim_raddr,d.act_slot_sel,OUTPUT_BUFFER_DEPTH,SEED);
  endtask

  task automatic send_compute(input cluster_ctrl_t d, input logic [1023:0] data, input int gap);
    @(negedge clock); repeat(gap) @(negedge clock);
    cmd_i=d; cmd_valid_i=1; act_data_i=data;
    display_command("SEND",d);
    for(int t=0;t<TIMEOUT_CYCLES;t++) begin
      @(posedge clock);
      if(cmd_ready_o) begin #1; cmd_valid_i=0; return; end
    end
    $fatal(1,"Command timeout");
  endtask

  task automatic send_address(input cluster_ctrl_t d,input int gap);
    @(negedge clock);repeat(gap) @(negedge clock);
    cmd_i=d;cmd_valid_i=1;
    display_command("SEND",d);
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
          // The overlap suite deliberately withholds Context1 until after
          // the entire ACT stream, proving that only that Context stalls.
          send_address(d,bubbles ?
            (($test$plusargs("INPUT_OVERLAP_TEST") && cx==1) ? pcount : cx%3) : 0);
        end
      end
    join
  endtask
