// 日志与驱动：下降沿驱动写/计算，提供空拍、排空和异步复位任务。
// 本文件在父 TB 的 module 作用域内 include，不作为独立编译单元。
// 共享信号/计数器在父 TB 声明；不要添加 module 或额外 begin/end 层次。

    task automatic display_case(input string description);
        $display("[CASE_START] time=%0.3f ns suite=single_macro case=%0d description=%s clock_gating=%0d seed=%08h",
                 $realtime,test_case_id,description,CLOCK_GATING,random_state);
        test_case_id++;
    endtask
    // Drive only at falling edges; sample registered outputs after NBA.
    task automatic idle_cycle();
        @(negedge clock);
        cim_ren = 0;
        cim_wen = 0;
    endtask
    task automatic drain();
        repeat (3) idle_cycle();
    endtask
    task automatic write_row(input logic [7:0] address, input logic [1023:0] data,
                             input logic [3:0] write_mask=4'b0000);
        display_case($sformatf("%s/write-row address=%0d mask=%h",case_description,address,write_mask));
        @(negedge clock);
        cim_ren = 0;
        cim_wen = 1;
        cim_waddr = address;
        cim_wdata = data;
        cim_wmask = write_mask;
    endtask
    task automatic send_phase(
        input logic [2:0] precision,
        input logic [1:0] phase,
        input logic signed_en,
        input logic [3:0] mask,
        input logic [7:0] address,
        input logic station,
        input logic [511:0] data
    );
        display_case($sformatf("%s/phase W%0dA%0d signed=%0d phase=%0d oc_mask=%h row=%0d refresh=%0d",
          case_description,weight_bits(precision),activation_bits(precision),signed_en,phase,mask,address,station));
        @(negedge clock);
        cim_ren = 1;
        cim_wen = 0;
        cim_precision = precision;
        cim_phase = phase;
        cim_signed_en = signed_en;
        cim_oc_mask = mask;
        cim_raddr = address;
        cim_station = station;
        cim_idata = data;
    endtask
    task automatic async_reset();
        display_case("asynchronous-reset/cancel-inflight/retain-SRAM");
        @(negedge clock);
        cim_ren = 0;
        cim_wen = 0;
        #2 reset = 1;
        #1;
        if (cim_odata_valid !== 0 || cim_odata !== 0 ||
            cim_odata_oc_mask !== 0 || cim_odata_phase !== 0)
            $fatal(1, "TB: asynchronous reset did not immediately clear outputs");
        @(negedge clock);
        reset = 0;
    endtask
