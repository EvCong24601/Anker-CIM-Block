`timescale 1ns/1ps
`default_nettype none
module tb_SingleMacro;
    parameter bit CLOCK_GATING = 1'b1;
    logic clock = 1'b0;
    always #5 clock = ~clock;
    logic reset = 1'b0;
    logic cim_ren = 0, cim_station = 1, cim_signed_en = 0, sram_wen = 0;
    logic [511:0] cim_idata = '0;
    logic [7:0] cim_raddr = '0, sram_waddr = '0;
    logic [3:0] cim_oc_mask = '0;
    logic [2:0] cim_precision = '0;
    logic [1:0] cim_phase = '0;
    logic [1023:0] sram_wdata = '0;
    wire [71:0] cim_odata;
    wire cim_odata_valid;
    wire [3:0] cim_odata_oc_mask;
    wire [1:0] cim_odata_phase;
    logic [3:0] sram_wmask = 0, cim_result_mask = 15;
    logic sram_ren = 0;
    logic [7:0] sram_raddr = 0;
    wire [1023:0] sram_rdata;
    logic legacy_compare = 1;
    logic negative_mode = 0;
    SingleMacro #(.USE_CLOCK_GATING(CLOCK_GATING)) dut (.*);
    wire [71:0] github_data;
    wire github_valid;
    wire [3:0] github_mask;
    wire [1:0] github_phase;
    wire [1023:0] github_rdata;
    // Opposite gating setting checks arithmetic AND gating/bypass equivalence.
    GithubSingleMacro #(.USE_CLOCK_GATING(!CLOCK_GATING)) github_baseline (
        .clock(clock), .reset(reset), .cim_ren(cim_ren && !negative_mode), .cim_station(cim_station),
        .cim_signed_en(cim_signed_en), .cim_idata(cim_idata), .cim_raddr(cim_raddr),
        .cim_oc_mask(cim_oc_mask), .cim_result_mask(cim_result_mask),
        .cim_precision(cim_precision), .cim_phase(cim_phase),
        .sram_wen(sram_wen && !negative_mode), .sram_waddr(sram_waddr), .sram_wdata(sram_wdata),
        .sram_wmask(sram_wmask), .sram_ren(sram_ren && !negative_mode), .sram_raddr(sram_raddr),
        .sram_rdata(github_rdata), .cim_odata(github_data),
        .cim_odata_valid(github_valid), .cim_odata_oc_mask(github_mask),
        .cim_odata_phase(github_phase)
    );

    // Frozen V0.2: compare tags and active OC arithmetic on legacy traffic.
    wire [71:0] baseline_data;
    wire baseline_valid;
    wire [3:0] baseline_mask;
    wire [1:0] baseline_phase;
    V02SingleMacro #(.USE_CLOCK_GATING(CLOCK_GATING)) baseline (
        .clock(clock), .reset(reset), .cim_ren(cim_ren && legacy_compare && !negative_mode), .cim_station(cim_station),
        .cim_signed_en(cim_signed_en), .cim_wen(sram_wen && legacy_compare && !negative_mode), .cim_idata(cim_idata),
        .cim_raddr(cim_raddr), .cim_waddr(sram_waddr), .cim_wdata(sram_wdata),
        .cim_oc_mask(cim_oc_mask), .cim_precision(cim_precision), .cim_phase(cim_phase),
        .cim_odata(baseline_data), .cim_odata_valid(baseline_valid),
        .cim_odata_oc_mask(baseline_mask), .cim_odata_phase(baseline_phase)
    );

    // Exhaustively test actual PP outputs, including post-inversion isolation.
    logic [1:0] mul_w = 0;
    logic [3:0] mul_a = 0;
    logic mul_sw = 0, mul_sa = 0;
    logic mul_enable = 1;
    wire [7:0] mul_pp;
    MacroPartialProducts2x4 primitive_dut (
        .weight_bits(mul_w), .activation_bits(mul_a),
        .weight_signed(mul_sw), .activation_signed(mul_sa),
        .enable(mul_enable), .pp(mul_pp)
    );

    logic [1023:0] reference_memory [0:255];
    logic [1023:0] reference_hold;
    logic [7:0] reference_hold_address;
    logic reference_hold_valid = 0;
    // Independent interface expectation: never import the DUT latency constant.
    localparam int EXPECTED_LATENCY = 1;
    logic [EXPECTED_LATENCY:0] expected_valid = 0;
    logic [71:0] expected_data [0:EXPECTED_LATENCY];
    logic [3:0] expected_mask [0:EXPECTED_LATENCY];
    logic [1:0] expected_phase [0:EXPECTED_LATENCY];
    logic [3:0] expected_result_mask [0:EXPECTED_LATENCY];
    logic [511:0] expected_act = 0;
    logic [1023:0] expected_read = 0;
    integer ordinary_reads = 0, partial_writes = 0, suppressed_results = 0;
    logic [71:0] last_data = 0;
    logic [3:0] last_mask = 0;
    logic [1:0] last_phase = 0;
    integer cycle_count = 0, accepted_count = 0, result_count = 0, cancelled_count = 0;
    integer bubble_count = 0, zero_mask_count = 0, primitive_count = 0;
    string negative_case;
    logic [31:0] random_state = 32'h13579bdf;
    logic collect_context = 0;
    integer context_id_in = 0;
    logic [1:0] context_valid = 0;
    integer context_id_pipe [0:1];
    longint signed context_sum [0:1][0:3];

    // Optional simulation heartbeat, useful with large explicit gate networks.
    always @(negedge clock)
        if ($test$plusargs("PROGRESS") && cycle_count % 100 == 0)
            $display("PROGRESS cycle=%0d accepted=%0d", cycle_count, accepted_count);

    always @(posedge clock or posedge reset) begin
        #1;
        if (!negative_mode) begin
            if ({cim_odata, cim_odata_valid, cim_odata_oc_mask, cim_odata_phase, sram_rdata} !==
                {github_data, github_valid, github_mask, github_phase, github_rdata})
                $fatal(1, "TB: GitHub/V1.1 complete output trace mismatch");
            if (legacy_compare) begin
                if ({cim_odata_valid, cim_odata_oc_mask, cim_odata_phase} !==
                    {baseline_valid, baseline_mask, baseline_phase})
                    $fatal(1, "TB: legacy valid/tag mismatch");
                for (int c = 0; c < 4; c++)
                    if (cim_odata_valid && cim_odata_oc_mask[c] &&
                        cim_odata[18*c+:18] !== baseline_data[18*c+:18])
                        $fatal(1, "TB: legacy active OC arithmetic mismatch");
            end
        end
    end

    function automatic logic [31:0] random_word();
        random_state = random_state ^ (random_state << 13);
        random_state = random_state ^ (random_state >> 17);
        random_state = random_state ^ (random_state << 5);
        return random_state;
    endfunction
    function automatic logic [1023:0] random_row();
        logic [1023:0] value;
        for (int i = 0; i < 32; i++) value[32*i +: 32] = random_word();
        return value;
    endfunction
    function automatic logic [511:0] random_activation();
        logic [511:0] value;
        for (int i = 0; i < 16; i++) value[32*i +: 32] = random_word();
        return value;
    endfunction
    function automatic int activation_bits(input int precision);
        case (precision)
            0,2: return 4;
            1,3,5: return 8;
            default: return 16;
        endcase
    endfunction
    function automatic int weight_bits(input int precision);
        case (precision)
            0,1: return 2;
            2,3,4: return 4;
            default: return 8;
        endcase
    endfunction
    function automatic logic [511:0] padded_activation(
        input logic [511:0] value, input int precision
    );
        case (weight_bits(precision))
            2: return value;
            4: return {256'b0, value[255:0]};
            default: return {384'b0, value[127:0]};
        endcase
    endfunction

    // Independent golden: decode whole W2/W4/W8 integers and compute a dot
    // product. It deliberately does not reproduce slice routing or bit fusion.
    function automatic logic [71:0] golden_phase(
        input logic [1023:0] row,
        input logic [511:0] activation,
        input logic [2:0] precision,
        input logic signed_en,
        input logic [1:0] phase,
        input logic [3:0] mask
    );
        int bw, ba, w, a, sum;
        logic [71:0] result;
        bw = weight_bits(int'(precision));
        ba = activation_bits(int'(precision));
        result = '0;
        for (int c = 0; c < 4; c++) begin
            sum = 0;
            if (mask[c]) begin
                for (int j = 0; j < 256/bw; j++) begin
                    case (bw)
                        2: w = int'({1'b0, row[256*c+2*j +: 2]});
                        4: w = int'({1'b0, row[256*c+4*j +: 4]});
                        default: w = int'({1'b0, row[256*c+8*j +: 8]});
                    endcase
                    if (signed_en && w >= (1 << (bw-1))) w -= (1 << bw);
                    a = int'({1'b0, activation[4*j +: 4]});
                    if (signed_en && int'(phase) == ba/4-1 && a >= 8) a -= 16;
                    sum += w*a;
                end
            end
            if (sum < -131072 || sum > 131071)
                $fatal(1, "TB: golden outside signed18");
            result[18*c +: 18] = sum[17:0];
        end
        return result;
    endfunction

    // Drive only at falling edges; sample registered outputs after NBA.
    task automatic idle_cycle();
        @(negedge clock);
        cim_ren = 0;
        sram_wen = 0;
        sram_ren = 0;
    endtask
    task automatic drain();
        repeat (3) idle_cycle();
    endtask
    task automatic write_row(input logic [7:0] address, input logic [1023:0] data);
        @(negedge clock);
        cim_ren = 0;
        sram_wen = 1;
        sram_ren = 0;
        sram_wmask = 0;
        sram_waddr = address;
        sram_wdata = data;
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
        @(negedge clock);
        cim_ren = 1;
        sram_wen = 0;
        sram_ren = 0;
        cim_precision = precision;
        cim_phase = phase;
        cim_signed_en = signed_en;
        cim_oc_mask = mask;
        cim_result_mask = 15;
        cim_raddr = address;
        cim_station = station;
        cim_idata = data;
    endtask
    task automatic read_row(input logic [7:0] address);
        @(negedge clock);
        cim_ren = 0;
        sram_wen = 0;
        sram_ren = 1;
        sram_raddr = address;
    endtask
    task automatic async_reset();
        @(negedge clock);
        cim_ren = 0;
        sram_wen = 0;
        sram_ren = 0;
        #2 reset = 1;
        #1;
        if (cim_odata_valid !== 0 || cim_odata !== 0 ||
            cim_odata_oc_mask !== 0 || cim_odata_phase !== 0)
            $fatal(1, "TB: asynchronous reset did not immediately clear outputs");
        @(negedge clock);
        reset = 0;
    endtask

    always @(posedge clock or posedge reset) begin : scoreboard
        logic [1023:0] row;
        if (reset) begin
            for (int i = 0; i < EXPECTED_LATENCY; i++)
                if (expected_valid[i] === 1'b1) cancelled_count++;
            expected_valid = '0;
            for (int i = 0; i <= EXPECTED_LATENCY; i++) begin
                expected_data[i] = '0;
                expected_mask[i] = '0;
                expected_result_mask[i] = '0;
                expected_phase[i] = '0;
            end
            last_data = 0;
            last_mask = 0;
            last_phase = 0;
            reference_hold_valid = 0;
            expected_act = 0;
            expected_read = 0;
            context_valid = 0;
        end else if (!negative_mode) begin
            cycle_count++;
            context_valid[1] = context_valid[0];
            context_id_pipe[1] = context_id_pipe[0];
            context_valid[0] = collect_context && cim_ren && (|cim_oc_mask);
            context_id_pipe[0] = context_id_in;
            for (int i = EXPECTED_LATENCY; i > 0; i--) begin
                expected_valid[i] = expected_valid[i-1];
                expected_data[i] = expected_data[i-1];
                expected_mask[i] = expected_mask[i-1];
                expected_result_mask[i] = expected_result_mask[i-1];
                expected_phase[i] = expected_phase[i-1];
            end
            expected_valid[0] = cim_ren && (|cim_oc_mask);
            if (sram_wen && sram_wmask != 15) begin
                for (int c = 0; c < 4; c++)
                    if (!sram_wmask[c]) reference_memory[sram_waddr][256*c+:256] = sram_wdata[256*c+:256];
                reference_hold_valid = 0;
                if (sram_wmask != 0) partial_writes++;
            end
            expected_read = 0;
            if (sram_ren) begin
                expected_read = reference_memory[sram_raddr];
                reference_hold = expected_read;
                reference_hold_address = sram_raddr;
                reference_hold_valid = 1;
                ordinary_reads++;
            end
            if (expected_valid[0]) begin
                accepted_count++;
                if (cim_station) begin
                    row = reference_memory[cim_raddr];
                    reference_hold = row;
                    reference_hold_address = cim_raddr;
                    reference_hold_valid = 1;
                end else begin
                    if (!reference_hold_valid || cim_raddr != reference_hold_address)
                        $fatal(1, "TB: legal stimulus reused invalid reference hold");
                    row = reference_hold;
                end
                expected_data[0] = golden_phase(row, cim_idata, cim_precision,
                                               cim_signed_en, cim_phase, cim_oc_mask);
                expected_mask[0] = cim_oc_mask;
                expected_result_mask[0] = cim_result_mask;
                if ((cim_oc_mask & ~cim_result_mask) != 0) suppressed_results++;
                expected_act[127:0] = cim_idata[127:0];
                if (weight_bits(int'(cim_precision)) != 8) expected_act[255:128] = cim_idata[255:128];
                if (weight_bits(int'(cim_precision)) == 2) expected_act[511:256] = cim_idata[511:256];
                expected_phase[0] = cim_phase;
            end else if (cim_ren) zero_mask_count++;
            else bubble_count++;
            #1;
            if (dut.activation_in !== expected_act)
                $fatal(1, "TB: ACT bank capture/hold mismatch");
            if (sram_rdata !== expected_read)
                $fatal(1, "TB: ordinary SRAM read/qualification mismatch");
            if (cim_odata_valid !== expected_valid[EXPECTED_LATENCY])
                $fatal(1, "TB: latency/valid mismatch cycle=%0d expected=%b got=%b",
                       cycle_count, expected_valid[EXPECTED_LATENCY], cim_odata_valid);
            if (expected_valid[EXPECTED_LATENCY]) begin
                result_count++;
                for (int c = 0; c < 4; c++)
                    if (expected_mask[EXPECTED_LATENCY][c] && expected_result_mask[EXPECTED_LATENCY][c])
                        last_data[18*c+:18] = expected_data[EXPECTED_LATENCY][18*c+:18];
                last_mask = expected_mask[EXPECTED_LATENCY];
                last_phase = expected_phase[EXPECTED_LATENCY];
                if (context_valid[1])
                    for (int c = 0; c < 4; c++)
                        context_sum[context_id_pipe[1]][c] +=
                            longint'($signed(cim_odata[18*c +: 18])) <<< (4*int'(cim_odata_phase));
            end
            if (cim_odata !== last_data || cim_odata_oc_mask !== last_mask ||
                cim_odata_phase !== last_phase)
                $fatal(1, "TB: data/tag/hold mismatch cycle=%0d expected=%h/%h/%h got=%h/%h/%h",
                       cycle_count, last_data, last_mask, last_phase,
                       cim_odata, cim_odata_oc_mask, cim_odata_phase);
        end
    end

    // A small external scheduler model: K=512 in 16 W8 tiles. Reconstruct two
    // full A16 contexts from already weight-fused outputs, with only one Psum
    // per context/OC. The real Cluster implementation is outside this project.
    task automatic check_multitile(input int order, input bit sg);
        logic [15:0] full_a [0:1][0:511];
        longint signed expected [0:1][0:3];
        logic [511:0] digits;
        int av, wv, tile, ph, ctx;
        drain();
        for (int k = 0; k < 512; k++)
            for (int id = 0; id < 2; id++) full_a[id][k] = 16'(random_word());
        for (int id = 0; id < 2; id++)
            for (int c = 0; c < 4; c++) begin
                expected[id][c] = 0;
                context_sum[id][c] = 0;
                for (int k = 0; k < 512; k++) begin
                    av = int'(full_a[id][k]);
                    if (sg && av >= 32768) av -= 65536;
                    wv = int'({1'b0, reference_memory[64+k/32][256*c+8*(k%32) +: 8]});
                    if (sg && wv >= 128) wv -= 256;
                    expected[id][c] += longint'(av)*longint'(wv);
                end
            end
        collect_context = 1;
        for (int index = 0; index < 128; index++) begin
            case (order)
                0: begin ctx = index/64; tile = (index/4)%16; ph = index%4; end // OS
                1: begin tile = index/8; ctx = (index/4)%2; ph = index%4; end // WS
                default: begin ph = index/32; tile = (index/2)%16; ctx = index%2; end // AS
            endcase
            digits = '0;
            for (int j = 0; j < 32; j++) digits[4*j +: 4] = full_a[ctx][32*tile+j][4*ph +: 4];
            send_phase(6, 2'(ph), sg, 15, 8'(64+tile),
                order == 0 ? ph == 0 : order == 1 ? (ph == 0 && ctx == 0) : ctx == 0,
                digits);
            context_id_in = ctx;
        end
        drain();
        collect_context = 0;
        for (int id = 0; id < 2; id++)
            for (int c = 0; c < 4; c++)
                if (context_sum[id][c] != expected[id][c])
                    $fatal(1, "TB: K512 stationary mismatch order=%0d sg=%0d ctx=%0d oc=%0d got=%0d expected=%0d",
                           order,sg,id,c,context_sum[id][c],expected[id][c]);
    endtask

    task automatic run_negative(input string test_name);
        write_row(8'd0, {128{8'hff}});
        idle_cycle();
        if (test_name == "precision") send_phase(7,0,0,15,0,1,'0);
        else if (test_name == "phase") send_phase(0,1,0,15,0,1,'0);
        else if (test_name == "hold_invalid") send_phase(0,0,0,15,0,0,'0);
        else if (test_name == "uninitialized") send_phase(0,0,0,15,255,1,'0);
        else if (test_name == "hold_address") begin
                send_phase(0,0,0,15,0,1,'0);
                send_phase(0,0,0,15,1,0,'0);
            end
        else if (test_name == "hold_address_pending") begin
                write_row(8'd1, {128{8'h12}});
                send_phase(0,0,0,15,0,1,'0);
                send_phase(0,0,0,15,1,1,'0);
                // Row1 was captured at the preceding input edge; Row0 is stale.
                send_phase(0,0,0,15,0,0,'0);
            end
        else if (test_name == "unknown_write") begin
                write_row(0,'0);
                sram_wdata[1000] = 1'bx;
            end
        else if (test_name == "unknown_activation") begin
                send_phase(0,0,0,15,0,1,'0);
                cim_idata[300] = 1'bx;
            end
        else if (test_name == "unknown_control") begin
                send_phase(0,0,0,15,0,1,'0);
                cim_signed_en = 1'bz;
            end
        else if (test_name == "read_write") begin
                send_phase(0,0,0,15,0,1,'0);
                sram_wen = 1;
            end
        else if (test_name == "write_busy") begin
                send_phase(0,0,0,15,0,1,'0);
                write_row(0,'0);
            end
        else if (test_name == "hold_after_write") begin
                send_phase(0,0,0,15,0,1,'0);
                drain();
                write_row(0,'0);
                send_phase(0,0,0,15,0,0,'0);
            end
        else if (test_name == "hold_after_reset") begin
                send_phase(0,0,0,15,0,1,'0);
                drain();
                async_reset();
                send_phase(0,0,0,15,0,0,'0);
            end
        else if (test_name == "unknown_wmask") begin
                write_row(0, '0); sram_wmask[0] = 1'bx;
            end
        else if (test_name == "unknown_result_mask") begin
                send_phase(0,0,0,15,0,1,'0); cim_result_mask[1] = 1'bx;
            end
        else if (test_name == "regular_compute") begin
                send_phase(0,0,0,15,0,1,'0); sram_ren = 1;
            end
        else if (test_name == "regular_busy") begin
                send_phase(0,0,0,15,0,1,'0); read_row(0);
            end
        else if (test_name == "regular_write") begin
                write_row(0,'0); sram_ren = 1;
            end
        else if (test_name == "partial_uninitialized" || test_name == "partial_reuse_uninitialized") begin
                write_row(254, '1); sram_wmask = 4'b1110;
                if (test_name == "partial_reuse_uninitialized") read_row(254);
                send_phase(0,0,0,2,254,test_name == "partial_uninitialized",'1);
            end
        else if (test_name == "full_mask_write_busy") begin
                send_phase(0,0,0,15,0,1,'0); write_row(0,'0); sram_wmask = 15;
            end
        else if (test_name == "hold_after_partial_write") begin
                send_phase(0,0,0,15,0,1,'0); drain();
                write_row(0,'0); sram_wmask = 14;
                send_phase(0,0,0,1,0,0,'0);
            end
        else $fatal(1, "TB: unknown negative case");
        drain();
        $fatal(1, "TB: negative test was not rejected");
    endtask

    initial begin : stimulus
        int w_value, a_value, primitive_expected, primitive_x, correction, ba;
        logic [1023:0] row;
        logic [511:0] activation;
        logic [31:0] random_control;
        logic [7:0] address;
        logic station;
        logic [2:0] precision;
        logic [1:0] phase;
        if ($value$plusargs("SEED=%d", random_state)) begin end
        if ($value$plusargs("NEGATIVE=%s", negative_case)) negative_mode = 1;
        // Generate a real asynchronous assertion edge even if the functional
        // clock gate remains closed throughout reset.
        #1 reset = 1;

        for (int sw = 0; sw < 2; sw++)
            for (int sa = 0; sa < 2; sa++)
                for (int w = 0; w < 4; w++)
                    for (int a = 0; a < 16; a++) begin
                        mul_sw = (sw != 0); mul_sa = (sa != 0);
                        mul_w = w[1:0]; mul_a = a[3:0];
                        w_value = (sw && w >= 2) ? w-4 : w;
                        a_value = (sa && a >= 8) ? a-16 : a;
                        primitive_expected = w_value*a_value;
                        correction = 14*sw + 8*sa + 16*(sw ^ sa);
                        mul_enable = 1;
                        #1;
                        primitive_x = int'(mul_pp[0]) + 2*int'(mul_pp[1])
                            + 4*int'(mul_pp[2]) + 8*int'(mul_pp[3])
                            + 2*int'(mul_pp[4]) + 4*int'(mul_pp[5])
                            + 8*int'(mul_pp[6]) + 16*int'(mul_pp[7]);
                        if (primitive_x - correction != primitive_expected)
                            $fatal(1, "TB: 2x4 PP identity mismatch");
                        mul_enable = 0;
                        #1;
                        if (mul_pp !== 8'd0)
                            $fatal(1, "TB: PP isolation mismatch");
                        primitive_count++;
                    end
        @(negedge clock);
        reset = 0;
        if (negative_mode) run_negative(negative_case);

        // Fresh SRAM: a partial write initializes only the selected OC. Each
        // prefix can compute immediately, even while other OC sectors are X.
        legacy_compare = 0;
        for (int c = 0; c < 4; c++) begin
            write_row(240, random_row()); sram_wmask = ~(4'b0001 << c);
            send_phase(0,0,1,4'((1 << (c+1))-1),240,1,random_activation());
            drain();
            read_row(240);
            send_phase(5,1,1,4'((1 << (c+1))-1),240,0,random_activation());
            drain();
        end
        async_reset();
        legacy_compare = 1;

        // All 256 rows, including boundary addresses, with consecutive writes.
        for (int i = 0; i < 256; i++) begin
            case (i)
                0: row = '0;
                1: row = '1;
                2: row = {128{8'haa}};
                3: row = {128{8'h88}};
                4: row = {128{8'h80}};
                5: row = {128{8'h77}};
                6: row = {128{8'h7f}};
                default: row = random_row();
            endcase
            write_row(i[7:0], row);
        end
        // Immediate first read after last write, then consecutive reuse.
        send_phase(6,0,0,15,255,1,padded_activation('1,6));
        send_phase(6,1,0,15,255,0,padded_activation('1,6));

        // All precision/sign/phase/OC-mask combinations, back-to-back.
        for (int p = 0; p < 7; p++)
            for (int sg = 0; sg < 2; sg++)
                for (int ph = 0; ph < activation_bits(p)/4; ph++)
                    for (int mask = 0; mask < 16; mask++) begin
                        activation = padded_activation(random_activation(), p);
                        send_phase(p[2:0], ph[1:0], (sg != 0), mask[3:0],
                                   8'(p*16+mask), 1, activation);
                    end
        // Explicit unsigned maximum and signed minimum patterns.
        send_phase(5,0,0,15,1,1,padded_activation('1,5));
        send_phase(5,1,0,15,1,0,padded_activation('1,5));
        send_phase(6,3,1,15,4,1,padded_activation({128{4'h8}},6));
        send_phase(0,0,1,15,2,1,{128{4'h8}});
        send_phase(2,0,1,15,3,1,padded_activation({128{4'h8}},2));

        // Signed zero products must cancel the nonzero inverted-bit offsets.
        for (int p = 0; p < 7; p++)
            for (int ph = 0; ph < activation_bits(p)/4; ph++)
                for (int mask = 1; mask < 16; mask++) begin
                    send_phase(3'(p),2'(ph),1,4'(mask),1,1,'0);
                    send_phase(3'(p),2'(ph),1,4'(mask),0,1,padded_activation('1,p));
                end
        drain();

        // Walking weight bits cover every digit and K index, across all OCs.
        for (int mode = 0; mode < 3; mode++) begin
            precision = mode == 0 ? 3'd1 : mode == 1 ? 3'd3 : 3'd5;
            for (int bit_index = 0; bit_index < 256; bit_index++) begin
                row = '0;
                for (int c = 0; c < 4; c++) row[256*c+(bit_index+17*c)%256] = 1;
                write_row(250,row);
                activation = '0;
                for (int j = 0; j < 256/weight_bits(int'(precision)); j++)
                    activation[4*j +: 4] = 4'(1+(j%15));
                send_phase(precision,0,1,15,250,1,activation);
                send_phase(precision,1,1,15,250,0,activation);
                drain();
            end
        end
        // Minimal negative W8 and UINT maximum exercise result extremes.
        write_row(250,{128{8'h80}});
        send_phase(5,0,1,15,250,1,padded_activation('1,5));
        drain();

        for (int order = 0; order < 3; order++)
            for (int sg = 0; sg < 2; sg++) check_multitile(order,sg != 0);

        // Hold preserves masked-off OC data and ignores zero-mask refreshes.
        send_phase(3,0,1,1,5,1,padded_activation(random_activation(),3));
        send_phase(3,1,1,15,5,0,padded_activation(random_activation(),3));
        send_phase(7,3,1,0,6,1,random_activation());
        send_phase(6,3,1,13,5,0,padded_activation(random_activation(),6));
        drain();

        // A completing refresh survives a zero-mask or ren=0 input. Ensure a
        // different old Hold cannot conceal a dropped refresh.
        send_phase(5,0,0,15,1,1,padded_activation('1,5));
        send_phase(7,3,1,0,255,1,'0);
        send_phase(5,1,0,15,1,0,padded_activation('1,5));
        send_phase(3,0,1,3,5,1,padded_activation(random_activation(),3));
        idle_cycle();
        // Poison live inputs during the accepted request's computation. The
        // registered request must still complete and refresh Row5 correctly.
        cim_idata = '0;
        cim_raddr = 8'd254;
        cim_station = 0;
        cim_precision = 7;
        cim_signed_en = 0;
        cim_phase = 3;
        cim_oc_mask = 15;
        send_phase(3,1,1,15,5,0,padded_activation(random_activation(),3));
        drain();
        // Known unused upper ACT bits must not enter the arithmetic.
        send_phase(5,0,0,15,6,1,'1);

        // Independent consecutive requests with bubbles and dynamic controls.
        for (int i = 0; i < 2000; i++) begin
            // The preceding request was driven at a falling edge, not yet
            // accepted. Wait for that acceptance before choosing a reuse row.
            // The next drive is still the immediately following falling edge.
            @(posedge clock);
            #2;
            random_control = random_word();
            if (random_control[3:0] == 0) idle_cycle();
            else begin
                precision = 3'(random_control % 7);
                ba = activation_bits(int'(precision));
                phase = 2'((random_control >> 8) % (ba/4));
                station = random_control[12] || !(reference_hold_valid);
                // The most recent accepted SRAM read already established Hold.
                address = station ? random_control[23:16] : reference_hold_address;
                activation = padded_activation(random_activation(), int'(precision));
                send_phase(precision, phase, random_control[13], random_control[7:4],
                           address, station, activation);
            end
        end
        drain();

        // Legal earliest write: last issue n; complete n+1; write at n+2
        // while the previous output is sampled. Also write again at n+3.
        send_phase(5,0,0,15,255,1,padded_activation('1,5));
        idle_cycle();
        write_row(255,{128{8'h12}});
        write_row(254,{128{8'h34}});
        send_phase(5,0,0,15,254,1,padded_activation('1,5));
        send_phase(5,0,0,15,255,1,padded_activation('1,5));
        drain();

        // Interrupt valid transactions asynchronously, retaining SRAM rows.
        for (int i = 0; i < 6; i++)
            send_phase(4,i[1:0],1,15,200,1,padded_activation(random_activation(),4));
        async_reset();
        send_phase(4,3,1,15,200,1,padded_activation(random_activation(),4));
        send_phase(4,0,0,15,200,0,padded_activation(random_activation(),4));
        drain();
        // Reset also works with an idle, stopped functional clock gate.
        async_reset();
        send_phase(0,0,0,15,0,1,'1);
        drain();
        legacy_compare = 0;
        // Ordinary reads: back-to-back addresses, output qualification, read->reuse.
        read_row(255);
        read_row(254);
        send_phase(5,0,0,15,254,0,'1);
        idle_cycle();
        // Earliest ordinary read is n+2, while the old result is already valid.
        read_row(254);
        idle_cycle();
        // Full-mask writes leave both memory and the retained-read tag intact.
        write_row(254,'0); sram_wmask = 15;
        send_phase(5,1,1,15,254,0,'1);
        drain();
        // All write masks: independently verify preserved sectors through reads.
        for (int wm = 0; wm < 16; wm++) begin
            write_row(240, random_row()); sram_wmask = 4'(wm);
            read_row(240);
            send_phase(3,1,1,15,240,0,random_activation());
            drain();
        end
        // All compute/result-mask combinations, precision transitions and poison
        // upper ACT bits; masks are sampled per request, not used live at output.
        for (int p = 0; p < 7; p++)
            for (int sg = 0; sg < 2; sg++)
                for (int ph = 0; ph < activation_bits(p)/4; ph++)
                    for (int cm = 0; cm < 16; cm++)
                        for (int rm = 0; rm < 16; rm++) begin
                            send_phase(3'(p),2'(ph),sg != 0,4'(cm),240,0,random_activation());
                            cim_result_mask = 4'(rm);
                        end
        drain();
        // Unneeded results still issue, refresh Hold, return valid/mask/phase.
        send_phase(5,0,0,15,255,1,'1); cim_result_mask = 0;
        send_phase(0,0,1,15,255,0,random_activation());
        drain();
        // Reset suppresses ordinary-read qualification and invalidates Hold;
        // a post-reset ordinary read can re-establish Hold without a CIM refresh.
        read_row(240);
        async_reset();
        read_row(240);
        send_phase(6,3,1,15,240,0,'1);
        drain();
        @(posedge clock);
        #2;
        if (expected_valid != 0 || accepted_count != result_count + cancelled_count)
            $fatal(1, "TB: outstanding or lost transactions at finish");
        $display("PASS reads=%0d partial_writes=%0d suppressed_results=%0d", ordinary_reads, partial_writes, suppressed_results);
        $display("PASS clock_gating=%0d primitive=%0d accepted=%0d results=%0d cancelled=%0d bubbles=%0d zero_mask=%0d",
                 CLOCK_GATING, primitive_count, accepted_count, result_count,
                 cancelled_count, bubble_count, zero_mask_count);
        $finish;
    end
    initial begin
        #2000000;
        $fatal(1, "TB: timeout");
    end
endmodule
`default_nettype wire
