`timescale 1ns/1ps
// Handcut gate netlist. The empty MacroWeightSRAM black box has already been
// removed from this file; rtl/MacroWeightSRAM.sv is compiled beside it.
`default_nettype wire
`include "build/sdf/SingleMacro.handcut.sim.v"
`default_nettype none
// Numeric-zero sparsity stimulus/checker for the TWO-cycle SingleMacro netlist.
// Alternative TB: compile this OR the Toggle TB, not both (same top/scope).
// WS counts digit-phase issues: one refresh followed by WS-1 reuses.
// TOTAL_ACT counts COMPLETE activation vectors, not digit-phase issues.
// +define+SDF_FILE annotates the max SDF onto dut. +SAIF writes the measure window only.
// Default clock is 3.906 ns (256.02 MHz), matching the one-cycle gate sim.
module tb_WeightStationaryNetlist;
    localparam integer LATENCY=2;
    reg clock=0,reset=0;
    realtime clock_period=3.906,sample_delay=0.9765;
    reg configured=0;
    reg cim_ren=0,cim_station=0,cim_signed_en=1;
    reg [511:0] cim_idata=0;
    reg [7:0] cim_raddr=0,sram_waddr=0,sram_raddr=0;
    reg [3:0] cim_oc_mask=15,cim_result_mask=15,sram_wmask=0;
    reg [2:0] cim_precision=5;
    reg [1:0] cim_phase=0;
    reg sram_wen=0,sram_ren=0;
    reg [1023:0] sram_wdata=0;
    wire [1023:0] sram_rdata;
    wire [71:0] cim_odata;
    wire cim_odata_valid;
    wire [3:0] cim_odata_oc_mask;
    wire [1:0] cim_odata_phase;

    // Gate-level SingleMacro from the included handcut netlist.
    SingleMacro dut (
        .clock(clock),.reset(reset),.cim_ren(cim_ren),.cim_idata(cim_idata),
        .cim_raddr(cim_raddr),.cim_station(cim_station),.cim_oc_mask(cim_oc_mask),
        .cim_result_mask(cim_result_mask),.cim_precision(cim_precision),
        .cim_signed_en(cim_signed_en),.cim_phase(cim_phase),
        .sram_wen(sram_wen),.sram_waddr(sram_waddr),.sram_wdata(sram_wdata),
        .sram_wmask(sram_wmask),.sram_ren(sram_ren),.sram_raddr(sram_raddr),
        .sram_rdata(sram_rdata),.cim_odata(cim_odata),.cim_odata_valid(cim_odata_valid),
        .cim_odata_oc_mask(cim_odata_oc_mask),.cim_odata_phase(cim_odata_phase)
    );

    integer ws=16,total_act=256,precision=5,signed_mode=1,seed=20261114;
    integer unused,bw,abits,phases,total_issues,windows;
    // Sparsity counts zero FULL numeric elements, not zero bits or phases.
    integer sparsity_pct=50,act_sparsity_pct=50,wgt_sparsity_pct=50,act_width;
    integer act_budget=0,wgt_budget=0;
    reg [511:0] phase_payload[0:3];
    reg [2047:0] observed_full_act=0;
    longint unsigned act_vectors=0,wgt_samples=0;
    longint unsigned act_zeros=0,wgt_zeros=0,act_elements=0,wgt_elements=0;
    integer issued=0,received=0,completed_act=0,refreshes=0,reuses=0,cycle=0;
    integer expected_address,expected_phase_live;
    reg [31:0] weight_rng,act_rng,act_digest=0;
    reg [1023:0] rows[0:255];
    reg [2047:0] full_act=0;
    reg [LATENCY:0] pending='0;
    reg [71:0] expected_digit[0:LATENCY];
    reg [127:0] expected_full[0:LATENCY];
    integer tag_phase[0:LATENCY],tag_cycle[0:LATENCY],tag_act[0:LATENCY];
    longint signed accumulated[0:3];
    reg measure_active=0;
    realtime measure_start,measure_end;
    string wave_path,fsdb_path,trace_path,saif_path;
    integer trace_fd=0;

    initial begin
        wait(configured);
        forever #(clock_period/2.0) clock=~clock;
    end
    function automatic [31:0] next_random(input [31:0] state);
        reg [31:0] v;
        begin
            v=state ^ (state<<13);v=v ^ (v>>17);v=v ^ (v<<5);
            next_random=v;
        end
    endfunction
    // Draw nonzero numeric codes, then zero an exact random subset. Carry the
    // fractional element budget across vectors/rows (including the first one).
    task automatic make_sparse(input integer elements,input integer bits,
                               input integer pct,inout reg [31:0] rng,
                               inout integer budget,output reg [2047:0] value);
        integer indices[0:511];
        integer zeros,pick,swap_index;
        reg [31:0] code,mask;
        begin
            value=0;mask=(32'b1<<bits)-1;
            for(integer e=0;e<elements;e=e+1) begin
                // Excluding zero here prevents accidental extra sparsity.
                do begin
                    rng=next_random(rng);code=rng & mask;
                end while(code==0);
                for(integer b=0;b<bits;b=b+1) value[e*bits+b]=code[b];
                indices[e]=e;
            end
            budget=budget+elements*pct;
            zeros=budget/100;budget=budget%100;
            for(integer e=0;e<zeros;e=e+1) begin
                rng=next_random(rng);
                pick=e+(rng % (elements-e));
                swap_index=indices[e];indices[e]=indices[pick];indices[pick]=swap_index;
                for(integer b=0;b<bits;b=b+1) value[indices[e]*bits+b]=0;
            end
        end
    endtask
    function automatic integer count_zeros(input [2047:0] value,
                                             input integer elements,input integer bits);
        reg [2047:0] mask;
        integer count;
        begin
            mask=(2048'b1<<bits)-1;count=0;
            for(integer e=0;e<elements;e=e+1)
                if(((value>>(e*bits)) & mask)==0) count=count+1;
            count_zeros=count;
        end
    endfunction
    function automatic real percent(input longint unsigned count,input longint unsigned total);
        percent=(total==0) ? 0.0 : 100.0*real'(count)/real'(total);
    endfunction

    // Reassemble ACT from accepted phase payloads before counting full zeros.
    // WGT is counted from selected, preloaded SRAM rows on refresh only.
    task automatic observe_inputs;
        reg [1023:0] active_mask;
        begin
            active_mask=(1024'b1<<act_width)-1;
            if((^cim_idata)===1'bx || (cim_idata & ~active_mask)!==1024'b0)
                $fatal(1,"WS: unknown ACT or nonzero inactive ACT bits");
            if(cim_phase==0) observed_full_act=0;
            for(integer k=0;k<256/bw;k=k+1)
                observed_full_act[abits*k+4*cim_phase+:4]=cim_idata[4*k+:4];
            if(cim_phase==phases-1) begin
                if(observed_full_act !== full_act)
                    $fatal(1,"WS: transmitted ACT reconstruction mismatch");
                act_zeros=act_zeros+count_zeros(observed_full_act,256/bw,abits);
                act_elements=act_elements+256/bw;act_vectors=act_vectors+1;
                if(act_zeros!=act_elements*act_sparsity_pct/100)
                    $fatal(1,"WS: cumulative ACT sparsity mismatch");
            end
            if(cim_station) begin
                if((^rows[cim_raddr])===1'bx) $fatal(1,"WS: unknown selected weight row");
                wgt_zeros=wgt_zeros+count_zeros({1024'b0,rows[cim_raddr]},1024/bw,bw);
                wgt_elements=wgt_elements+1024/bw;wgt_samples=wgt_samples+1;
                if(wgt_zeros!=wgt_elements*wgt_sparsity_pct/100)
                    $fatal(1,"WS: cumulative WGT sparsity mismatch");
            end
        end
    endtask
    function automatic [71:0] golden_digit(input [1023:0] row,
                                           input [511:0] act,input integer ph);
        integer c,k,w,a,sum;
        reg [71:0] value;
        begin
            value=0;
            for(c=0;c<4;c=c+1) begin
                sum=0;
                for(k=0;k<256/bw;k=k+1) begin
                    w=(row>>(256*c+bw*k)) & ((1<<bw)-1);
                    if(signed_mode && w >= (1<<(bw-1))) w=w-(1<<bw);
                    a=act[4*k+:4];
                    if(signed_mode && ph==phases-1 && a>=8) a=a-16;
                    sum=sum+w*a;
                end
                value[18*c+:18]=sum;
            end
            golden_digit=value;
        end
    endfunction
    function automatic [127:0] golden_vector(input [1023:0] row,input [2047:0] act);
        integer c,k,w,a,sum;
        reg [127:0] value;
        begin
            value=0;
            for(c=0;c<4;c=c+1) begin
                sum=0;
                for(k=0;k<256/bw;k=k+1) begin
                    w=(row>>(256*c+bw*k)) & ((1<<bw)-1);
                    if(signed_mode && w >= (1<<(bw-1))) w=w-(1<<bw);
                    a=(act>>(abits*k)) & ((1<<abits)-1);
                    if(signed_mode && a >= (1<<(abits-1))) a=a-(1<<abits);
                    sum=sum+w*a;
                end
                value[32*c+:32]=sum;
            end
            golden_vector=value;
        end
    endfunction

    // Sample stimulus at the edge, outputs after adjustable clk-to-Q allowance.
    // This uses only public ports and an independent, fixed two-cycle contract.
    always @(posedge clock) begin
        cycle=cycle+1;
        if(reset) begin
            pending='0;
        end else begin
            for(integer d=LATENCY;d>0;d=d-1) begin
                pending[d]=pending[d-1];
                expected_digit[d]=expected_digit[d-1];
                expected_full[d]=expected_full[d-1];
                tag_phase[d]=tag_phase[d-1];
                tag_cycle[d]=tag_cycle[d-1];
                tag_act[d]=tag_act[d-1];
            end
            pending[0]=cim_ren;
            if(cim_ren) begin
                expected_address=(issued/ws)%256;
                expected_phase_live=issued%phases;
                if(cim_station !== (issued%ws==0) || cim_raddr !== 8'(expected_address) ||
                   cim_phase !== 2'(expected_phase_live)) $fatal(1,"WS: input schedule mismatch");
                if(cim_station) refreshes=refreshes+1; else reuses=reuses+1;
                observe_inputs();
                expected_digit[0]=golden_digit(rows[cim_raddr],cim_idata,cim_phase);
                expected_full[0]=golden_vector(rows[cim_raddr],full_act);
                tag_phase[0]=cim_phase;tag_cycle[0]=cycle;tag_act[0]=issued/phases;
                issued=issued+1;
            end
        end
        #(sample_delay);
        if(cim_odata_valid !== pending[LATENCY])
            $fatal(1,"WS: valid mismatch cycle=%0d got=%b expected=%b",cycle,cim_odata_valid,pending[LATENCY]);
        if(!reset && pending[LATENCY]) begin
            if(cycle-tag_cycle[LATENCY]!=LATENCY || cim_odata !== expected_digit[LATENCY] ||
               cim_odata_phase !== 2'(tag_phase[LATENCY]) || cim_odata_oc_mask !== 4'hf)
                $fatal(1,"WS: phase result mismatch cycle=%0d act=%0d phase=%0d got=%h expected=%h",
                    cycle,tag_act[LATENCY],tag_phase[LATENCY],cim_odata,expected_digit[LATENCY]);
            for(integer c=0;c<4;c=c+1) begin
                if(tag_phase[LATENCY]==0) accumulated[c]=0;
                accumulated[c]=accumulated[c]+(longint'($signed(cim_odata[18*c+:18])) << (4*tag_phase[LATENCY]));
                if(tag_phase[LATENCY]==phases-1 && accumulated[c] !==
                    longint'($signed(expected_full[LATENCY][32*c+:32])))
                    $fatal(1,"WS: full vector mismatch act=%0d OC=%0d",tag_act[LATENCY],c);
            end
            if(tag_phase[LATENCY]==phases-1) completed_act=completed_act+1;
            received=received+1;
        end
        if(trace_fd && measure_active)
            $fdisplay(trace_fd,"%0t,%0d,%b,%b,%0d,%0d,%0128h,%b,%0d,%018h",
                $time,cycle,cim_ren,cim_station,cim_raddr,cim_phase,cim_idata,
                cim_odata_valid,cim_odata_phase,cim_odata);
    end

    initial begin : stimulus
        reg [2047:0] sparse_payload;
        integer q;
        unused=$value$plusargs("WS=%d",ws);
        unused=$value$plusargs("TOTAL_ACT=%d",total_act);
        unused=$value$plusargs("PRECISION=%d",precision);
        unused=$value$plusargs("SIGNED=%d",signed_mode);
        unused=$value$plusargs("SEED=%d",seed);
        unused=$value$plusargs("SPARSITY_PCT=%d",sparsity_pct);
        act_sparsity_pct=sparsity_pct;wgt_sparsity_pct=sparsity_pct;
        unused=$value$plusargs("ACT_SPARSITY_PCT=%d",act_sparsity_pct);
        unused=$value$plusargs("WGT_SPARSITY_PCT=%d",wgt_sparsity_pct);
        if(sparsity_pct<0 || sparsity_pct>100 || act_sparsity_pct<0 || act_sparsity_pct>100 ||
           wgt_sparsity_pct<0 || wgt_sparsity_pct>100)
            $fatal(1,"WS: require SPARSITY_PCT and ACT/WGT_SPARSITY_PCT=0..100");
        if($test$plusargs("ACT_TOGGLE_PCT=") || $test$plusargs("WGT_TOGGLE_PCT=") ||
           $test$plusargs("STIM_MODE="))
            $fatal(1,"WS: sparsity TB does not accept toggle/STIM_MODE arguments");
        unused=$value$plusargs("CLK_PERIOD_NS=%f",clock_period);
        sample_delay=clock_period/4.0;
        unused=$value$plusargs("SAMPLE_DELAY_NS=%f",sample_delay);
        if(precision<0 || precision>6 || signed_mode<0 || signed_mode>1 || seed==0 ||
           total_act<1 || (ws!=2 && ws!=8 && ws!=16 && ws!=32))
            $fatal(1,"WS: require WS=2/8/16/32, TOTAL_ACT>0, PRECISION=0..6, SIGNED=0/1, SEED!=0");
        if(clock_period<=0 || sample_delay<=0 || sample_delay>=clock_period/2.0)
            $fatal(1,"WS: require 0 < SAMPLE_DELAY_NS < CLK_PERIOD_NS/2");
        if(!$value$plusargs("SAIF=%s",saif_path)) saif_path="activity.saif";
`ifdef SDF_FILE
        // Literal after +define+SDF_FILE. VCS rejects a runtime string here.
        // Each run starts in its own directory, so the log stays per group.
        $sdf_annotate(`SDF_FILE,dut,,"sdf_annotate.log","MAXIMUM");
`else
        $fatal(1,"WS: compile with +define+SDF_FILE=\\\"file.sdf\\\"");
`endif
        $set_toggle_region(dut);
        bw=precision<2 ? 2 : precision<5 ? 4 : 8;
        abits=(precision==0 || precision==2) ? 4 : (precision==4 || precision==6) ? 16 : 8;
        phases=abits/4;total_issues=total_act*phases;
        if(ws%phases!=0 || total_issues%ws!=0)
            $fatal(1,"WS: WS must contain whole ACT vectors; TOTAL_ACT*phases must divide into whole WS windows");
        windows=total_issues/ws;
        act_width=4*(256/bw);
        if(windows>256)
            $fatal(1,"WS: sparsity WGT requires at most 256 refresh windows (no address wrap)");
        cim_precision=precision;cim_signed_en=signed_mode;
        act_rng=seed;weight_rng=32'(seed)^32'h9e3779b9;
        if(weight_rng==0) weight_rng=32'h6d2b79f5;
        // Independent RNG streams ensure identical weights and ACT vectors
        // across WS settings with equal seed, precision and TOTAL_ACT.
        for(integer row=0;row<256;row=row+1) begin
            make_sparse(1024/bw,bw,wgt_sparsity_pct,weight_rng,wgt_budget,sparse_payload);
            rows[row]=sparse_payload[1023:0];
        end
        $display("WS_CONFIG ws=%0d total_act=%0d phase_issues=%0d windows=%0d precision=%0d signed=%0d clock_ns=%0.6f latency=%0d",
            ws,total_act,total_issues,windows,precision,signed_mode,clock_period,LATENCY);
        $display("WS_STIM mode=sparsity act_sparsity_pct=%0d wgt_sparsity_pct=%0d act_elements_per_vector=%0d act_bits=%0d wgt_elements_per_row=%0d wgt_bits=%0d seed=%0d",
            act_sparsity_pct,wgt_sparsity_pct,256/bw,abits,1024/bw,bw,seed);
        // Create a real reset edge after time zero, also for gate-level flops.
        #1;reset=1;configured=1;
        repeat(3) @(negedge clock);
        reset=0;
        // Same 256-cycle initialization for every WS setting, outside dumping.
        for(integer row=0;row<256;row=row+1) begin
            @(negedge clock);sram_wen=1;sram_waddr=row;sram_wdata=rows[row];
        end
        @(negedge clock);sram_wen=0;sram_wdata=0;
        if($value$plusargs("TRACE=%s",trace_path)) begin
            trace_fd=$fopen(trace_path,"w");
            if(!trace_fd) $fatal(1,"WS: unable to open TRACE file");
            $fdisplay(trace_fd,"time,cycle,ren,station,address,phase,activation_hex,out_valid,out_phase,output_hex");
        end
        @(negedge clock);
        if($value$plusargs("VCD=%s",wave_path)) begin
            $dumpfile(wave_path);$dumpvars(0,dut);$dumpvars(0,measure_active);
        end
`ifdef WS_FSDB
        if($value$plusargs("FSDB=%s",fsdb_path)) begin
            $fsdbDumpfile(fsdb_path);$fsdbDumpvars(0,dut);
        end
`else
        if($value$plusargs("FSDB=%s",fsdb_path))
            $fatal(1,"WS: compile with WS_FSDB and the FSDB PLI to use +FSDB");
`endif
        measure_active=1;measure_start=$realtime;
        $toggle_start;
        $display("WS_MEASURE_BEGIN ns=%0.6f",measure_start);
        for(integer a=0;a<total_act;a=a+1) begin
            // Sparsify the full A4/A8/A16 value before splitting into phases.
            make_sparse(256/bw,abits,act_sparsity_pct,act_rng,act_budget,sparse_payload);
            full_act=sparse_payload;
            for(integer w=0;w<(256/bw)*abits/32;w=w+1)
                act_digest={act_digest[30:0],act_digest[31]} ^ full_act[32*w+:32];
            for(integer ph=0;ph<phases;ph=ph+1) begin
                phase_payload[ph]=0;
                for(integer k=0;k<256/bw;k=k+1)
                    phase_payload[ph][4*k+:4]=full_act[abits*k+4*ph+:4];
            end
            for(integer ph=0;ph<phases;ph=ph+1) begin
                q=a*phases+ph;
                cim_ren=1;cim_station=(q%ws==0);cim_raddr=(q/ws)%256;cim_phase=ph;
                cim_idata=phase_payload[ph];
                @(negedge clock);
            end
        end
        cim_ren=0;cim_station=0;
        // Include two latency cycles and one valid-clearing cycle in the window.
        repeat(LATENCY+1) @(negedge clock);
        measure_end=$realtime;measure_active=0;
        $toggle_stop;
        // 1e-9 s matches the 1 ns timescale. PTPX strips this scope.
        $toggle_report(saif_path,1.0e-9,"tb_WeightStationaryNetlist.dut");
        $display("SAIF %s",saif_path);
        if(pending!='0 || cim_odata_valid!==0 || issued!=total_issues || received!=issued ||
           completed_act!=total_act || refreshes!=windows || reuses!=total_issues-windows)
            $fatal(1,"WS: final counts/drain mismatch");
        if(act_vectors!=total_act || wgt_samples!=refreshes ||
           act_elements!=act_vectors*(256/bw) || wgt_elements!=wgt_samples*(1024/bw))
            $fatal(1,"WS: sparsity monitor sample counts mismatch");
        $display("WS_SPARSITY ACT vectors=%0d elements=%0d zeros=%0d pct=%0.6f target_pct=%0d",
            act_vectors,act_elements,act_zeros,percent(act_zeros,act_elements),act_sparsity_pct);
        $display("WS_SPARSITY WGT_REFRESH rows=%0d elements=%0d zeros=%0d pct=%0.6f target_pct=%0d",
            wgt_samples,wgt_elements,wgt_zeros,percent(wgt_zeros,wgt_elements),wgt_sparsity_pct);
        $display("WS_MEASURE_END ns=%0.6f duration_ns=%0.6f",measure_end,measure_end-measure_start);
        $display("PASS WS=%0d TOTAL_ACT=%0d issued=%0d received=%0d completed_act=%0d refresh=%0d reuse=%0d weight_changes=%0d act_digest=%08h",
            ws,total_act,issued,received,completed_act,refreshes,reuses,refreshes-1,act_digest);
        if(trace_fd) $fclose(trace_fd);
        $finish;
    end
    initial begin
        wait(configured);
        #((total_issues+512)*clock_period);
        $fatal(1,"WS: watchdog timeout");
    end
endmodule
`default_nettype wire
