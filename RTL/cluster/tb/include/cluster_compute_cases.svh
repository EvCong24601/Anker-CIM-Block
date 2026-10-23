// 单个计算 case：生成权重/ACT 与独立点积预期，驱动完整任务并检查完成。
// 本文件在父 TB 的 module 作用域内 include，不作为独立编译单元。
// 共享信号/计数器在父 TB 声明；不要添加 module 或额外 begin/end 层次。

  function automatic string pattern_name(input int pattern);
    case(pattern)
      0:return "random"; 1:return "all-zero"; 2:return "maximum";
      3:return "minimum"; 4:return "alternating-extremes";
      default:return "opposite-weight-ACT-extremes";
    endcase
  endfunction
  function automatic string cluster_suite();
    if($test$plusargs("REQUANT_TEST")) return "per-tensor-combinational-requant";
    if($test$plusargs("INPUT_OVERLAP_TEST")) return "same-packet-input-issue-overlap";
    if($test$plusargs("CONTEXT_STRESS_TEST")) return "OS1-WS64-AS64/OS2-WS8-AS8";
    if($test$plusargs("OC_MERGE_TEST")) return "leftmost-OC-mask";
    if($test$plusargs("ACT_BUFFER_TEST")) return "full-plane-ACT-capacity";
    if($test$plusargs("FULL_ACT_TEST")) return "W8A16-K256-full-ACT";
    if($test$plusargs("MIXED_CONTEXT_TEST")) return "mixed-endpoint-contexts";
    return standard_case!=0 ? "standard-cycle-timing" : "split-numeric-fusion-Psum";
  endfunction
  task automatic run_case(input int precision, input bit sign_en,
      input logic [6:0] split, input logic [7:0] en,
      input logic [31:0] oc, input logic [23:0] slots,
      input int pattern,os,ws,as_count, input bit bubbles);
    cluster_ctrl_t d;
    logic [1023:0] plane, row;
    logic [4095:0] full_act;
    int wb,ab,kr,l,slot,a_ctx,c,p,t,groups,used_digits,requant_checks_before;
    int unsigned raw;
    longint signed w,a;
    // 1. 记录 case 目的和配置；所有后续 scoreboard 使用这份固定配置。
    $display("[CASE_START] time=%0.3f ns suite=cluster case=%0d standard_case=%0d description=%s/%s mode=%s W%0dA%0d signed=%0d pattern=%0d os=%0d ws=%0d as=%0d split=%02h en=%02h oc=%08h slots=%06h bubbles=%0d depth=%0d seed=%08h",
      $realtime,cases_run,standard_case,cluster_suite(),pattern_name(pattern),ws>1 ? "WS" : as_count>1 ? "AS" : "SINGLE",
      wbits(precision),abits(precision),sign_en,pattern,os,ws,as_count,split,en,oc,slots,bubbles,OUTPUT_BUFFER_DEPTH,SEED);
    wb=wbits(precision); ab=abits(precision); kr=256/wb;
    configure_requant(cases_run);
    requant_checks_before=requant_checks;
    case_os=os; case_ws=ws; case_as=as_count;
    case_pattern=pattern; case_bubbles=bubbles;
    if(os<1 || os>255 || ws<1 || ws>255 || as_count<1 || as_count>255 || (ws>1 && as_count>1))
      $fatal(1,"Counts must be 1..255; simultaneous WS/AS reuse is not defined");
    case_r=ws>1 ? ws : as_count; case_p=ab/4;
    d='0; d.os_cnt=8'(os); d.ws_cnt=8'(ws); d.as_cnt=8'(as_count);
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
    // 2. 生成完整整数 ACT：AS 复用同一份，WS 各 Context 使用独立输入。
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
    // 3. 预加载真实 SRAM，同时按整数 w*a 累加 golden；不读取 DUT 输出。
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
            if(en[m] && golden_oc_path(m,ocid,oc)) begin
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
    act_issue_overlap=0;address_issue_overlap=0;address_wait_cycles=0;late_address_wait=0;
    held_cmd=0; held_act_for_cmd=0;
    // 4. 开启计算检查窗口；driver 负责握手/Plane 时序，scoreboard 负责判定。
    monitoring=1;
    for(int kt=0;kt<os;kt++) for(int cx=0;cx<(as_count>1 ? 1 : case_r);cx++) begin
      d.weight_cim_raddr=8'('h20+16*kt);
      full_act='0;
      for(int ph=0;ph<case_p;ph++) for(int k=0;k<used_digits;k++)
        full_act[1024*ph+4*k+:4]=4'(activation[kt][cx][k]>>(4*ph));
      send_act_frame(d,full_act,kt,bubbles ? (kt+cx)%3 : 0,bubbles);
    end
    // 5. 污染外部 ACT 后等待完成，证明内部使用已保存的完整 ACT。
    // Internal distribution must use the saved ACT, not these external pins.
    @(negedge clock);act_data_i=~full_act[0+:1024];
    for(int wait_cycles=0;wait_cycles<TIMEOUT_CYCLES;wait_cycles++) begin
      @(negedge clock);
      if(raw_count==case_r*$countones(expected_mask) &&
         issue_count==os*case_r*case_p && !dut.batch_active) break;
      if(wait_cycles==TIMEOUT_CYCLES-1) $fatal(1,"Output timeout");
    end
    if(raw_count!=case_r*$countones(expected_mask) || issue_count!=os*case_r*case_p || input_commands!=os*case_r)
      $fatal(1,"Lost/duplicate compute or result");
    if(act_planes_received!=os*(as_count>1 ? 1 : case_r)*case_p)
      $fatal(1,"ACT frame slice count mismatch");
    if(first_issue!=first_external+1)
      $fatal(1,"First issue did not follow the first registered Plane/address");
    if(case_p>1 && act_issue_overlap==0)
      $fatal(1,"Missing same-packet ACT load/issue overlap");
    if(as_count>1 && !bubbles && address_issue_overlap==0)
      $fatal(1,"Missing same-packet AS address/issue overlap");
    if(as_count>1 && bubbles && (case_p==1 || $test$plusargs("INPUT_OVERLAP_TEST")) && address_wait_cycles==0)
      $fatal(1,"Missing wait for delayed AS Context address");
    if($test$plusargs("INPUT_OVERLAP_TEST") && as_count>1 && bubbles && late_address_wait==0)
      $fatal(1,"Missing address wait after the full ACT stream was received");
    // 6. 排空后再检查无额外输出，防止重复结果混入下一个 case。
    repeat(6) @(negedge clock);
    if(dut.raw_valid!=0 || dut.batch_active || requant_valid_o!=0)
      $fatal(1,"Unexpected output after the final Context published");
    if(requant_checks-requant_checks_before!=raw_count)
      $fatal(1,"Missing/duplicate Requant result after drain");
    monitoring=0; cases_run++;
  endtask
