// 回归目录：每个 task 只枚举一种 suite；单 case 行为由 compute_cases 实现。
// 本文件在父 TB 的 module 作用域内 include，不作为独立编译单元。
// 共享信号/计数器在父 TB 声明；不要添加 module 或额外 begin/end 层次。

  // 固定最左 OC mask：含不一致 mask、关闭 owner、全屏蔽和连续复用。
  task automatic run_oc_merge_suite();
      // Unequal masks at pair/quad/root/mixed endpoints, disabled owners,
      // completely masked batches, and immediate reuse by the next case.
      for(int p=5;p<=6;p++) for(int sign_mode=0;sign_mode<2;sign_mode++)
        for(int tree=0;tree<4;tree++) for(int em=0;em<2;em++)
          for(int om=0;om<3;om++) for(int mode=0;mode<3;mode++)
            run_case(p,1'(sign_mode),tree==0 ? 7'h00 : tree==1 ? 7'h01 :
                     tree==2 ? 7'h07 : 7'h03,em==0 ? 8'hff : 8'haa,
                     om==0 ? 32'h84218421 : om==1 ? 32'hfffffff0 : 32'h0,
                     24'hfac688,0,2,mode==1 ? 2 : 1,mode==2 ? 2 : 1,0);
      $display("PASS oc_merge_leftmost cases=%0d",cases_run);
  endtask

  // 完整 Plane 占用：七精度、符号、Tile/Context 数和命令空拍。
  task automatic run_act_buffer_suite();
    int r;
    logic [7:0] standard_en;
    logic [23:0] standard_slots;
      // Every precision/sign at full 256-digit plane occupancy, single/WS/AS,
      // 1/2/16 Contexts, one/two Tiles, and with/without address-command gaps.
      for(int p=0;p<7;p++) begin
        case(wbits(p))
          2: begin standard_en=8'h03; standard_slots=24'h000008; end
          4: begin standard_en=8'h0f; standard_slots=24'h000688; end
          default: begin standard_en=8'hff; standard_slots=24'hfac688; end
        endcase
        for(int sign_mode=0;sign_mode<2;sign_mode++)
          for(int tiles=1;tiles<=2;tiles++) for(int mode=0;mode<5;mode++) begin
            r=mode>=3 ? 16 : mode>=1 ? 2 : 1;
            if(r>OUTPUT_BUFFER_DEPTH) continue;
            for(int gaps=0;gaps<2;gaps++)
              run_case(p,1'(sign_mode),7'h00,standard_en,32'hffffffff,standard_slots,
                       0,tiles,(mode==1 || mode==3) ? r : 1,
                       (mode==2 || mode==4) ? r : 1,1'(gaps));
          end
      end
      if(max_act_planes!=4 || act_buffer_checks==0)
        $fatal(1,"Missing complete ACT bank coverage");
      $display("PASS act_buffer_capacity cases=%0d max_planes=%0d buffer_bits=4096 max_contexts=%0d checks=%0d",
               cases_run,max_act_planes,OUTPUT_BUFFER_DEPTH,act_buffer_checks);
  endtask

  // W8A16/K256：完整 4096-bit ACT 的 WS/AS/单 Context。
  task automatic run_full_act_suite();
      for(int sign_mode=0;sign_mode<2;sign_mode++) for(int tiles=1;tiles<=2;tiles++)
        for(int mode=0;mode<3;mode++)
          run_case(6,1'(sign_mode),7'h00,8'hff,32'hffffffff,24'hfac688,
                   0,tiles,mode==1 ? 2 : 1,mode==2 ? 2 : 1,0);
      $display("PASS full_act_4096 cases=%0d",cases_run);
  endtask

  // 混合 pair/quad 终点：同拍允许不同 channel 发布不同 Context。
  task automatic run_mixed_context_suite();
      for(int p=2;p<=4;p++) for(int sign_mode=0;sign_mode<2;sign_mode++)
        for(int tiles=1;tiles<=2;tiles++) for(int mode=0;mode<2;mode++)
          run_case(p,1'(sign_mode),7'h03,8'h55,32'hffffffff,24'h040000,
                   0,tiles,mode==0 ? 2 : 1,mode==1 ? 2 : 1,0);
      $fclose(manifest); $fclose(operation_trace);
      $display("PASS mixed_context cases=%0d",cases_run);
  endtask

  // 默认回归：合法 split 穷举 + 六种标准时序 + 多 Context/多 Tile 极值。
  // 各 suite 共用 run_case，避免维护第二套驱动和数值预期。
  task automatic run_default_suite();
    int legal_count,n,r;
    logic [23:0] standard_slots;
    logic [7:0] standard_en;
    logic [6:0] standard_split;
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
  endtask
