`timescale 1ns/1ps
`default_nettype none
module tb_SingleMacro;
    parameter bit CLOCK_GATING = 1'b1;
    logic clock = 1'b0;
    always #5 clock = ~clock;
    logic reset = 1'b0;
    logic cim_ren = 0, cim_station = 1, cim_signed_en = 0, cim_wen = 0;
    logic [511:0] cim_idata = '0;
    logic [7:0] cim_raddr = '0, cim_waddr = '0;
    logic [3:0] cim_oc_mask = '0;
    logic [2:0] cim_precision = '0;
    logic [1:0] cim_phase = '0;
    logic [1023:0] cim_wdata = '0;
    wire [71:0] cim_odata;
    wire cim_odata_valid;
    wire [3:0] cim_odata_oc_mask;
    wire [1:0] cim_odata_phase;
    SingleMacro #(.USE_CLOCK_GATING(CLOCK_GATING)) dut (.*);

    // Exhaustive primitive test is independent of the macro datapath.
    logic [1:0] mul_w = 0;
    logic [3:0] mul_a = 0;
    logic mul_sw = 0, mul_sa = 0;
    wire signed [6:0] mul_product;
    MacroMul2x4 primitive_dut (
        .weight_bits(mul_w), .activation_bits(mul_a),
        .weight_signed(mul_sw), .activation_signed(mul_sa), .product(mul_product)
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
    logic pending_refresh = 0;
    logic [1023:0] pending_hold_row;
    logic [7:0] pending_hold_address;
    logic [71:0] last_data = 0;
    logic [3:0] last_mask = 0;
    logic [1:0] last_phase = 0;
    integer cycle_count = 0, accepted_count = 0, result_count = 0, cancelled_count = 0;
    integer bubble_count = 0, zero_mask_count = 0, primitive_count = 0;
    logic negative_mode = 0;
    string negative_case;
    logic [31:0] random_state = 32'h13579bdf;

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
        cim_wen = 0;
    endtask
    task automatic drain();
        repeat (3) idle_cycle();
    endtask
    task automatic write_row(input logic [7:0] address, input logic [1023:0] data);
        @(negedge clock);
        cim_ren = 0;
        cim_wen = 1;
        cim_waddr = address;
        cim_wdata = data;
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

    always @(posedge clock or posedge reset) begin : scoreboard
        logic [1023:0] row;
        if (reset) begin
            for (int i = 0; i < EXPECTED_LATENCY; i++)
                if (expected_valid[i] === 1'b1) cancelled_count++;
            expected_valid = '0;
            for (int i = 0; i <= EXPECTED_LATENCY; i++) begin
                expected_data[i] = '0;
                expected_mask[i] = '0;
                expected_phase[i] = '0;
            end
            last_data = 0;
            last_mask = 0;
            last_phase = 0;
            reference_hold_valid = 0;
            pending_refresh = 0;
        end else if (!negative_mode) begin
            cycle_count++;
            // Commit a previous refresh at its completion edge, BEFORE checking
            // this edge's new reuse. Reset cancels a pending refresh above.
            if (pending_refresh) begin
                reference_hold = pending_hold_row;
                reference_hold_address = pending_hold_address;
                reference_hold_valid = 1;
            end
            pending_refresh = 0;
            for (int i = EXPECTED_LATENCY; i > 0; i--) begin
                expected_valid[i] = expected_valid[i-1];
                expected_data[i] = expected_data[i-1];
                expected_mask[i] = expected_mask[i-1];
                expected_phase[i] = expected_phase[i-1];
            end
            expected_valid[0] = cim_ren && (|cim_oc_mask);
            if (cim_wen) begin
                reference_memory[cim_waddr] = cim_wdata;
                reference_hold_valid = 0;
            end
            if (expected_valid[0]) begin
                accepted_count++;
                if (cim_station) begin
                    row = reference_memory[cim_raddr];
                    pending_hold_row = row;
                    pending_hold_address = cim_raddr;
                    pending_refresh = 1;
                end else begin
                    if (!reference_hold_valid || cim_raddr != reference_hold_address)
                        $fatal(1, "TB: legal stimulus reused invalid reference hold");
                    row = reference_hold;
                end
                expected_data[0] = golden_phase(row, cim_idata, cim_precision,
                                               cim_signed_en, cim_phase, cim_oc_mask);
                expected_mask[0] = cim_oc_mask;
                expected_phase[0] = cim_phase;
            end else if (cim_ren) zero_mask_count++;
            else bubble_count++;
            #1;
            if (cim_odata_valid !== expected_valid[EXPECTED_LATENCY])
                $fatal(1, "TB: latency/valid mismatch cycle=%0d expected=%b got=%b",
                       cycle_count, expected_valid[EXPECTED_LATENCY], cim_odata_valid);
            if (expected_valid[EXPECTED_LATENCY]) begin
                result_count++;
                last_data = expected_data[EXPECTED_LATENCY];
                last_mask = expected_mask[EXPECTED_LATENCY];
                last_phase = expected_phase[EXPECTED_LATENCY];
            end
            if (cim_odata !== last_data || cim_odata_oc_mask !== last_mask ||
                cim_odata_phase !== last_phase)
                $fatal(1, "TB: data/tag/hold mismatch cycle=%0d expected=%h/%h/%h got=%h/%h/%h",
                       cycle_count, last_data, last_mask, last_phase,
                       cim_odata, cim_odata_oc_mask, cim_odata_phase);
        end
    end

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
                // Old Hold is Row0 before this edge, but Row1 commits now.
                send_phase(0,0,0,15,0,0,'0);
            end
        else if (test_name == "unknown_write") begin
                write_row(0,'0);
                cim_wdata[1000] = 1'bx;
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
                cim_wen = 1;
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
        else $fatal(1, "TB: unknown negative case");
        drain();
        $fatal(1, "TB: negative test was not rejected");
    endtask

    initial begin : stimulus
        int w_value, a_value, primitive_expected, ba;
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
                        #1;
                        if ($signed(mul_product) != primitive_expected)
                            $fatal(1, "TB: 2x4 primitive mismatch");
                        primitive_count++;
                    end
        @(negedge clock);
        reset = 0;
        if (negative_mode) run_negative(negative_case);

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
                station = random_control[12] || !(reference_hold_valid || pending_refresh);
                // At the next acceptance edge the pending refresh, if any,
                // commits and supersedes the old Hold address.
                address = station ? random_control[23:16]
                        : pending_refresh ? pending_hold_address : reference_hold_address;
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
        @(posedge clock);
        #2;
        if (expected_valid != 0 || accepted_count != result_count + cancelled_count)
            $fatal(1, "TB: outstanding or lost transactions at finish");
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
