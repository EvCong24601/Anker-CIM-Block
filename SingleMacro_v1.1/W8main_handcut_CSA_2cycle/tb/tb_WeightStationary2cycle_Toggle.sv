`timescale 1ns/1ps
// Handcut gate netlist. The empty MacroWeightSRAM black box has already been
// removed from this file; rtl/MacroWeightSRAM.sv is compiled beside it.
`default_nettype wire
`include "build/sdf/SingleMacro.handcut.sim.v"
`default_nettype none
// Pin-only stimulus/checker for the TWO-cycle SingleMacro netlist.
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
    // Rates count both directions, per active bit, between accepted samples.
    // WGT rate is conditional on a refresh (held unchanged during reuse).
    string stim_mode="toggle";
    integer act_toggle_pct=50,wgt_toggle_pct=50,act_width;
    integer act_budget=0,wgt_budget=0;
    reg [1023:0] generated_act=0;
    reg [511:0] phase_payload[0:3];
    reg have_generated_act=0;
    reg [511:0] observed_act=0;
    reg [1023:0] observed_weight=0;
    longint unsigned act_samples=0,wgt_samples=0;
    longint unsigned act_flips=0,wgt_flips=0,act_ones=0,wgt_ones=0;
    longint unsigned act_opportunities=0,wgt_opportunities=0,wgt_issue_opportunities=0;
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
    // Uniform-index partial Fisher-Yates: each selected bit flips exactly once.
    // Modulo reduction of a 32-bit PRNG has negligible bias for widths <=1024.
    // The carried remainder bounds cumulative rounding error below one bit.
    task automatic make_payload(input integer width,input integer pct,
                                input bit first_sample,input [1023:0] previous,
                                inout reg [31:0] rng,inout integer budget,
                                output reg [1023:0] value);
        integer indices[0:1023];
        integer flips,pick,swap_index;
        begin
            value=0;
            if(first_sample) begin
                for(integer w=0;w<(width+31)/32;w=w+1) begin
                    rng=next_random(rng);value[32*w+:32]=rng;
                end
            end else begin
                value=previous;
                budget=budget+width*pct;
                flips=budget/100;budget=budget%100;
                for(integer b=0;b<width;b=b+1) indices[b]=b;
                for(integer b=0;b<flips;b=b+1) begin
                    rng=next_random(rng);
                    pick=b+(rng % (width-b));
                    swap_index=indices[b];indices[b]=indices[pick];indices[pick]=swap_index;
                    value[indices[b]]=~value[indices[b]];
                end
            end
            for(integer b=width;b<1024;b=b+1) value[b]=0;
        end
    endtask
    function automatic integer count_bits(input [1023:0] value,input integer width);
        integer count;
        begin
            count=0;
            for(integer b=0;b<width;b=b+1) count=count+integer'(value[b]);
            count_bits=count;
        end
    endfunction
    function automatic real percent(input longint unsigned count,input longint unsigned total);
        percent=(total==0) ? 0.0 : 100.0*real'(count)/real'(total);
    endfunction

    // Monitor accepted port payloads and the SRAM rows selected by the address,
    // independently of generator budgets. No DUT hierarchy is required.
    task automatic observe_inputs;
        reg [1023:0] active_mask;
        begin
            active_mask=(1024'b1<<act_width)-1;
            if((^cim_idata)===1'bx || (cim_idata & ~active_mask)!==1024'b0)
                $fatal(1,"WS: unknown ACT or nonzero inactive ACT bits");
            if(act_samples!=0)
                act_flips=act_flips+count_bits({512'b0,(cim_idata^observed_act)},act_width);
            act_ones=act_ones+count_bits({512'b0,cim_idata},act_width);
            observed_act=cim_idata;act_samples=act_samples+1;
            if(cim_station) begin
                if((^rows[cim_raddr])===1'bx) $fatal(1,"WS: unknown selected weight row");
                if(wgt_samples!=0)
                    wgt_flips=wgt_flips+count_bits(rows[cim_raddr]^observed_weight,1024);
                wgt_ones=wgt_ones+count_bits(rows[cim_raddr],1024);
                observed_weight=rows[cim_raddr];wgt_samples=wgt_samples+1;
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
        reg [31:0] word_value;
        reg [1023:0] next_payload,previous_weight;
        integer q;
        unused=$value$plusargs("WS=%d",ws);
        unused=$value$plusargs("TOTAL_ACT=%d",total_act);
        unused=$value$plusargs("PRECISION=%d",precision);
        unused=$value$plusargs("SIGNED=%d",signed_mode);
        unused=$value$plusargs("SEED=%d",seed);
        unused=$value$plusargs("STIM_MODE=%s",stim_mode);
        unused=$value$plusargs("ACT_TOGGLE_PCT=%d",act_toggle_pct);
        unused=$value$plusargs("WGT_TOGGLE_PCT=%d",wgt_toggle_pct);
        if((stim_mode!="toggle" && stim_mode!="random") ||
           act_toggle_pct<0 || act_toggle_pct>100 || wgt_toggle_pct<0 || wgt_toggle_pct>100)
            $fatal(1,"WS: require STIM_MODE=toggle/random and ACT/WGT_TOGGLE_PCT=0..100");
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
        if(stim_mode=="toggle" && windows>256)
            $fatal(1,"WS: controlled WGT requires at most 256 refresh windows (no address wrap)");
        cim_precision=precision;cim_signed_en=signed_mode;
        act_rng=seed;weight_rng=32'(seed)^32'h9e3779b9;
        if(weight_rng==0) weight_rng=32'h6d2b79f5;
        // Independent RNG streams ensure identical weights and ACT vectors
        // across WS settings with equal seed, precision and TOTAL_ACT.
        previous_weight=0;
        for(integer row=0;row<256;row=row+1) begin
            if(stim_mode=="toggle") begin
                make_payload(1024,wgt_toggle_pct,row==0,previous_weight,
                             weight_rng,wgt_budget,next_payload);
                rows[row]=next_payload;previous_weight=next_payload;
            end else begin
                for(integer w=0;w<32;w=w+1) begin
                    weight_rng=next_random(weight_rng);rows[row][32*w+:32]=weight_rng;
                end
            end
        end
        $display("WS_CONFIG ws=%0d total_act=%0d phase_issues=%0d windows=%0d precision=%0d signed=%0d clock_ns=%0.6f latency=%0d",
            ws,total_act,total_issues,windows,precision,signed_mode,clock_period,LATENCY);
        $display("WS_STIM mode=%s act_toggle_pct=%0d wgt_refresh_toggle_pct=%0d act_width=%0d seed=%0d",
            stim_mode,act_toggle_pct,wgt_toggle_pct,act_width,seed);
        if(stim_mode=="random") $display("WS_STIM random mode: toggle percentage settings are ignored");
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
            full_act=0;
            if(stim_mode=="toggle") begin
                // Generate in physical phase order, including vector boundaries.
                // Reconstruct the full vector before issuing any of its phases.
                for(integer ph=0;ph<phases;ph=ph+1) begin
                    make_payload(act_width,act_toggle_pct,!have_generated_act,generated_act,
                                 act_rng,act_budget,next_payload);
                    generated_act=next_payload;have_generated_act=1;
                    phase_payload[ph]=next_payload[511:0];
                    for(integer w=0;w<act_width/32;w=w+1)
                        act_digest={act_digest[30:0],act_digest[31]} ^ next_payload[32*w+:32];
                    for(integer k=0;k<256/bw;k=k+1)
                        full_act[abits*k+4*ph+:4]=phase_payload[ph][4*k+:4];
                end
            end else begin
                // Preserve the original independent-random sequence and digest.
                for(integer k=0;k<256/bw;k=k+1) begin
                    act_rng=next_random(act_rng);word_value=act_rng;
                    act_digest={act_digest[30:0],act_digest[31]} ^ word_value;
                    for(integer b=0;b<abits;b=b+1) full_act[abits*k+b]=word_value[b];
                end
                for(integer ph=0;ph<phases;ph=ph+1) begin
                    phase_payload[ph]=0;
                    for(integer k=0;k<256/bw;k=k+1)
                        phase_payload[ph][4*k+:4]=full_act[abits*k+4*ph+:4];
                end
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
        act_opportunities=(act_samples-1)*act_width;
        wgt_opportunities=(wgt_samples-1)*1024;
        wgt_issue_opportunities=(act_samples-1)*1024;
        if(act_samples!=issued || wgt_samples!=refreshes)
            $fatal(1,"WS: toggle monitor sample counts mismatch");
        if(stim_mode=="toggle" &&
           (act_flips!=act_opportunities*act_toggle_pct/100 ||
            wgt_flips!=wgt_opportunities*wgt_toggle_pct/100))
            $fatal(1,"WS: measured cumulative toggle budget mismatch");
        $display("WS_TOGGLE ACT samples=%0d width=%0d flips=%0d opportunities=%0d pct=%0.6f ones_pct=%0.6f",
            act_samples,act_width,act_flips,act_opportunities,percent(act_flips,act_opportunities),
            percent(act_ones,act_samples*act_width));
        $display("WS_TOGGLE WGT_REFRESH samples=%0d width=1024 flips=%0d opportunities=%0d pct=%0.6f ones_pct=%0.6f",
            wgt_samples,wgt_flips,wgt_opportunities,percent(wgt_flips,wgt_opportunities),
            percent(wgt_ones,wgt_samples*1024));
        $display("WS_TOGGLE WGT_PER_ISSUE flips=%0d opportunities=%0d pct=%0.6f",
            wgt_flips,wgt_issue_opportunities,percent(wgt_flips,wgt_issue_opportunities));
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
