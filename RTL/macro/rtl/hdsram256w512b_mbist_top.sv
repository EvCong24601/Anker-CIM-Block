`timescale 1ns/1ps
// SRAM MBIST for a single-write, single-read 256-WL x 512-BL macro.
//
// This is the original 18-case SRAM test sequence from
// FP4TE_CimMacro_merge_BIST.  The old 1W/2R implementation ran the complete
// sequence twice (REN0 and REN1).  A 1WR macro has only one read port, so this
// module runs the REN0 sequence once and removes only the duplicate REN1 scan.
module SRAM_MBIST #(
    parameter integer WL_DEPTH  = 256,
    parameter integer BL_WIDTH  = 512,
    parameter integer ADDR_WIDTH = 8
) (
    input                       clk,
    input                       rst_n,
    input                       test_memory_start,
    input      [BL_WIDTH-1:0]   sram_rdata,
    input                       redsbk0OUT,
    input                       redsbk1OUT,
    input                       redsbk2OUT,
    input                       redsbk3OUT,

    output reg                  testMemory,
    output reg [BL_WIDTH-1:0]   Mbist_pattern,
    output reg [ADDR_WIDTH-1:0] test_addr,
    output reg                  test_wen,
    output reg                  test_ren,
    output reg                  test_rst,

    // Compatibility aliases.  A 1WR macro uses the same address for all of
    // these signals.
    output reg [ADDR_WIDTH-1:0] test_waddr,
    output reg [ADDR_WIDTH-1:0] test_raddr,
    output reg [ADDR_WIDTH-1:0] test_r_act_id,

    // Direct hdsram256w512btop pins.  The macro uses active-low CEN and
    // active-low WEN: CEN=0 selects, WEN=0 writes, WEN=1 reads.
    output                      CEN,
    output                      WEN,
    output                      REN,
    output      [ADDR_WIDTH-1:0] ADDR,
    output      [BL_WIDTH-1:0]   DIN,

    output reg                  test_done,
    output reg                  test_busy,
    output reg                  test_memory_valid,
    output reg                  out_of_repair,
    // 512 logical BL bits plus the four observed spare-column bits.
    output reg [BL_WIDTH+3:0]   test_error_BL,
    // Four 8-bit repair reports: {valid, 7-bit bad-column address}.
    output reg [7:0]            test_error_sbk0_BL,
    output reg [7:0]            test_error_sbk1_BL,
    output reg [7:0]            test_error_sbk2_BL,
    output reg [7:0]            test_error_sbk3_BL
);

    localparam [ADDR_WIDTH-1:0] LAST_ADDR = WL_DEPTH - 1;
    localparam [BL_WIDTH-1:0] ALL_0 = {BL_WIDTH{1'b0}};
    localparam [BL_WIDTH-1:0] ALL_1 = {BL_WIDTH{1'b1}};
    // The original 32-bit patterns were 0xaaaaaaaa/0x55555555.
    localparam [BL_WIDTH-1:0] ALL_A = {BL_WIDTH/8{8'hAA}};
    localparam [BL_WIDTH-1:0] ALL_5 = {BL_WIDTH/8{8'h55}};
    localparam integer ERROR_WIDTH = BL_WIDTH + 4;
    localparam [ERROR_WIDTH-1:0] ERROR_0 = {ERROR_WIDTH{1'b0}};

    localparam [4:0]
        CASE1  = 5'd1,
        CASE2  = 5'd2,
        CASE3  = 5'd3,
        CASE4  = 5'd4,
        CASE5  = 5'd5,
        CASE6  = 5'd6,
        CASE7  = 5'd7,
        CASE9  = 5'd9,
        CASE10 = 5'd10,
        CASE11 = 5'd11,
        CASE12 = 5'd12,
        CASE13 = 5'd13,
        CASE14 = 5'd14,
        CASE16 = 5'd16,
        CASE17 = 5'd17;

    typedef enum logic [1:0] {ST_IDLE, ST_RUN, ST_RESULT, ST_DONE} state_t;
    state_t state;
    reg [4:0] case_id;
    reg [2:0] step;
    reg [ADDR_WIDTH-1:0] address;
    reg [BL_WIDTH-1:0] expected_data;

    wire [ERROR_WIDTH-1:0] observed_data = {sram_rdata,
                                               redsbk3OUT, redsbk2OUT,
                                               redsbk1OUT, redsbk0OUT};
    // The four low error bits are spare-column observations.  They are kept
    // in test_error_BL for the 128+1 repair analysis, but final BIST pass/fail
    // is qualified only by the 512 logical-bit portion [515:4].
    wire [ERROR_WIDTH-1:0] expected_compare = {expected_data,
                                                 {4{expected_data[126]}}};
    wire [ERROR_WIDTH-1:0] compare_error = observed_data ^ expected_compare;

    // This is the same encoding used by the original
    // FP4TE_CimMacro_merge_BIST.sv: report the first failing logical column
    // in each 128-bit bank as {valid, column[6:0]}.
    function automatic [6:0] first_error_position;
        input [127:0] data_in;
        integer i;
        begin
            first_error_position = 7'd0;
            for (i = 0; i < 128; i = i + 1)
                if (data_in[i]) first_error_position = i[6:0];
        end
    endfunction

    // Each repair bank has 128 logical columns plus one spare-column
    // observation bit.  The original BIST considers one bad bit in a bank
    // repairable; only two or more bad bits make the bank out of repair.
    wire [128:0] repair_error_bank0 = {test_error_BL[131:4], test_error_BL[0]};
    wire [128:0] repair_error_bank1 = {test_error_BL[259:132], test_error_BL[1]};
    wire [128:0] repair_error_bank2 = {test_error_BL[387:260], test_error_BL[2]};
    wire [128:0] repair_error_bank3 = {test_error_BL[515:388], test_error_BL[3]};
    wire bank0_multi_error = |(repair_error_bank0 & (repair_error_bank0 - 129'd1));
    wire bank1_multi_error = |(repair_error_bank1 & (repair_error_bank1 - 129'd1));
    wire bank2_multi_error = |(repair_error_bank2 & (repair_error_bank2 - 129'd1));
    wire bank3_multi_error = |(repair_error_bank3 & (repair_error_bank3 - 129'd1));
    wire any_multi_error = bank0_multi_error | bank1_multi_error |
                           bank2_multi_error | bank3_multi_error;
    wire [127:0] error_bank0 = test_error_BL[131:4];
    wire [127:0] error_bank1 = test_error_BL[259:132];
    wire [127:0] error_bank2 = test_error_BL[387:260];
    wire [127:0] error_bank3 = test_error_BL[515:388];

    assign CEN  = testMemory ? 1'b0 : 1'b1;
    assign WEN  = testMemory ? ~test_wen : 1'b1;
    assign REN  = testMemory ? test_ren : 1'b0;
    assign ADDR = test_addr;
    assign DIN  = Mbist_pattern;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state             <= ST_IDLE;
            case_id           <= CASE1;
            step              <= 3'd0;
            address           <= '0;
            expected_data     <= ALL_0;
            testMemory        <= 1'b0;
            Mbist_pattern     <= ALL_0;
            test_addr         <= '0;
            test_waddr        <= '0;
            test_raddr        <= '0;
            test_r_act_id     <= '0;
            test_wen          <= 1'b0;
            test_ren          <= 1'b0;
            test_rst          <= 1'b0;
            test_done         <= 1'b0;
            test_busy         <= 1'b0;
            test_memory_valid <= 1'b0;
            out_of_repair     <= 1'b0;
            test_error_BL     <= ERROR_0;
            test_error_sbk0_BL <= 8'd0;
            test_error_sbk1_BL <= 8'd0;
            test_error_sbk2_BL <= 8'd0;
            test_error_sbk3_BL <= 8'd0;
        end else begin
            case (state)
                ST_IDLE: begin
                    testMemory <= 1'b0;
                    test_wen   <= 1'b0;
                    test_ren   <= 1'b0;
                    if (test_memory_start) begin
                        // test_done is a level status signal: clear it only
                        // when a new BIST run is accepted.
                        test_done         <= 1'b0;
                        state             <= ST_RUN;
                        case_id           <= CASE1;
                        step              <= 3'd0;
                        address           <= '0;
                        expected_data     <= ALL_0;
                        test_error_BL     <= ERROR_0;
                        test_memory_valid <= 1'b0;
                        out_of_repair     <= 1'b0;
                        test_error_sbk0_BL <= 8'd0;
                        test_error_sbk1_BL <= 8'd0;
                        test_error_sbk2_BL <= 8'd0;
                        test_error_sbk3_BL <= 8'd0;
                        test_busy         <= 1'b1;
                    end
                end

                ST_RUN: begin
                    testMemory <= 1'b1;
                    test_rst   <= 1'b0;
                    test_addr  <= address;
                    test_waddr <= address;
                    test_raddr <= address;
                    test_r_act_id <= address;
                    test_wen   <= 1'b0;
                    test_ren   <= 1'b0;

                    case (case_id)
                        // case1: reset all cells to 0.
                        CASE1: begin
                            test_wen      <= 1'b1;
                            Mbist_pattern <= ALL_0;
                            if (address == LAST_ADDR) begin
                                address <= '0;
                                case_id <= CASE2;
                            end else address <= address + 1'b1;
                        end

                        // case2: (R0,W(A/5)) upward.
                        CASE2: begin
                            if (step == 0) begin
                                test_ren      <= 1'b1;
                                expected_data <= ALL_0;
                                step          <= 1;
                            end else begin
                                // Original case2 intentionally skipped the
                                // first comparison (latency == 18).
                                if (address != '0)
                                    test_error_BL <= test_error_BL | compare_error;
                                test_wen      <= 1'b1;
                                Mbist_pattern <= address[0] ? ALL_5 : ALL_A;
                                expected_data <= ALL_0;
                                step          <= 0;
                                if (address == LAST_ADDR) begin address <= '0; case_id <= CASE3; end
                                else address <= address + 1'b1;
                            end
                        end

                        // case3: (R(A/5),W(A/5)) upward.
                        CASE3: begin
                            if (step == 0) begin
                                test_ren      <= 1'b1;
                                expected_data <= address[0] ? ALL_5 : ALL_A;
                                step          <= 1;
                            end else begin
                                test_error_BL <= test_error_BL | compare_error;
                                test_wen      <= 1'b1;
                                Mbist_pattern <= address[0] ? ALL_5 : ALL_A;
                                expected_data <= address[0] ? ALL_A : ALL_5;
                                step          <= 0;
                                if (address == LAST_ADDR) begin address <= '0; case_id <= CASE4; end
                                else address <= address + 1'b1;
                            end
                        end

                        // case4: (R(A/5),W(5/A)) upward.
                        CASE4: begin
                            if (step == 0) begin
                                test_ren      <= 1'b1;
                                expected_data <= address[0] ? ALL_5 : ALL_A;
                                step          <= 1;
                            end else begin
                                test_error_BL <= test_error_BL | compare_error;
                                test_wen      <= 1'b1;
                                Mbist_pattern <= address[0] ? ALL_A : ALL_5;
                                expected_data <= address[0] ? ALL_A : ALL_5;
                                step          <= 0;
                                if (address == LAST_ADDR) begin address <= '0; case_id <= CASE5; end
                                else address <= address + 1'b1;
                            end
                        end

                        // case5: (R(5/A),W(5/A)) upward.
                        CASE5: begin
                            if (step == 0) begin
                                test_ren      <= 1'b1;
                                expected_data <= address[0] ? ALL_A : ALL_5;
                                step          <= 1;
                            end else begin
                                test_error_BL <= test_error_BL | compare_error;
                                test_wen      <= 1'b1;
                                Mbist_pattern <= address[0] ? ALL_A : ALL_5;
                                expected_data <= address[0] ? ALL_5 : ALL_A;
                                step          <= 0;
                                if (address == LAST_ADDR) begin address <= '0; case_id <= CASE6; end
                                else address <= address + 1'b1;
                            end
                        end

                        // case6: (R(5/A),W(A/5)) upward.
                        CASE6: begin
                            if (step == 0) begin
                                test_ren      <= 1'b1;
                                expected_data <= address[0] ? ALL_A : ALL_5;
                                step          <= 1;
                            end else begin
                                test_error_BL <= test_error_BL | compare_error;
                                test_wen      <= 1'b1;
                                Mbist_pattern <= address[0] ? ALL_5 : ALL_A;
                                expected_data <= address[0] ? ALL_A : ALL_5;
                                step          <= 0;
                                if (address == LAST_ADDR) begin address <= '0; case_id <= CASE7; end
                                else address <= address + 1'b1;
                            end
                        end

                        // case7/8: W0 -> (R0,W0) upward.
                        CASE7: begin
                            if (step == 0) begin
                                test_ren      <= 1'b1;
                                expected_data <= address[0] ? ALL_5 : ALL_A;
                                step          <= 1;
                            end else begin
                                test_error_BL <= test_error_BL | compare_error;
                                test_wen      <= 1'b1;
                                Mbist_pattern <= ALL_0;
                                expected_data <= (address == '0) ? ALL_5 : ALL_0;
                                step          <= 0;
                                if (address == LAST_ADDR) begin address <= '0; case_id <= CASE9; end
                                else address <= address + 1'b1;
                            end
                        end

                        // case9: (R0,W1,R1,W1) upward.
                        CASE9: begin
                            case (step)
                                0: begin test_ren <= 1'b1; expected_data <= ALL_0; step <= 1; end
                                1: begin test_error_BL <= test_error_BL | compare_error; test_wen <= 1'b1; Mbist_pattern <= ALL_1; expected_data <= ALL_0; step <= 2; end
                                2: begin test_ren <= 1'b1; expected_data <= ALL_1; step <= 3; end
                                default: begin
                                    test_error_BL <= test_error_BL | compare_error;
                                    test_wen <= 1'b1; Mbist_pattern <= ALL_1; expected_data <= ALL_1; step <= 0;
                                    if (address == LAST_ADDR) begin address <= '0; case_id <= CASE10; end
                                    else address <= address + 1'b1;
                                end
                            endcase
                        end

                        // case10: (R1,W0,R0,W0) upward.
                        CASE10: begin
                            case (step)
                                0: begin test_ren <= 1'b1; expected_data <= ALL_1; step <= 1; end
                                1: begin test_error_BL <= test_error_BL | compare_error; test_wen <= 1'b1; Mbist_pattern <= ALL_0; expected_data <= ALL_1; step <= 2; end
                                2: begin test_ren <= 1'b1; expected_data <= ALL_0; step <= 3; end
                                default: begin
                                    test_error_BL <= test_error_BL | compare_error;
                                    test_wen <= 1'b1; Mbist_pattern <= ALL_0; expected_data <= ALL_0; step <= 0;
                                    if (address == LAST_ADDR) begin address <= LAST_ADDR; case_id <= CASE11; end
                                    else address <= address + 1'b1;
                                end
                            endcase
                        end

                        // case11: (R1,W0,R0,R1) downward.
                        CASE11: begin
                            case (step)
                                0: begin test_ren <= 1'b1; expected_data <= ALL_0; step <= 1; end
                                1: begin test_error_BL <= test_error_BL | compare_error; test_wen <= 1'b1; Mbist_pattern <= ALL_1; expected_data <= ALL_1; step <= 2; end
                                2: begin test_ren <= 1'b1; step <= 3; end
                                default: begin
                                    test_ren <= 1'b1;
                                    test_error_BL <= test_error_BL | compare_error; expected_data <= ALL_0; step <= 0;
                                    if (address == '0) begin address <= LAST_ADDR; case_id <= CASE12; end
                                    else address <= address - 1'b1;
                                end
                            endcase
                        end

                        // case12: (R0,W1,R1,R0) downward.
                        CASE12: begin
                            case (step)
                                0: begin test_ren <= 1'b1; expected_data <= ALL_1; step <= 1; end
                                1: begin test_error_BL <= test_error_BL | compare_error; test_wen <= 1'b1; Mbist_pattern <= ALL_0; expected_data <= ALL_0; step <= 2; end
                                2: begin test_ren <= 1'b1; step <= 3; end
                                default: begin
                                    test_ren <= 1'b1;
                                    test_error_BL <= test_error_BL | compare_error; expected_data <= ALL_1; step <= 0;
                                    if (address == '0) begin address <= LAST_ADDR; case_id <= CASE13; end
                                    else address <= address - 1'b1;
                                end
                            endcase
                        end

                        // case13: (R1,W0) downward.
                        CASE13: begin
                            if (step == 0) begin test_ren <= 1'b1; expected_data <= ALL_0; step <= 1; end
                            else begin
                                test_error_BL <= test_error_BL | compare_error;
                                test_wen <= 1'b1; Mbist_pattern <= ALL_0; expected_data <= ALL_0; step <= 0;
                                if (address == '0) begin address <= '0; case_id <= CASE14; end
                                else address <= address - 1'b1;
                            end
                        end

                        // case14/15: (R0,W1) upward.
                        CASE14: begin
                            if (step == 0) begin test_ren <= 1'b1; expected_data <= ALL_0; step <= 1; end
                            else begin
                                test_error_BL <= test_error_BL | compare_error;
                                test_wen <= 1'b1; Mbist_pattern <= ALL_1; expected_data <= (address == '0) ? ALL_0 : ALL_1; step <= 0;
                                if (address == LAST_ADDR) begin address <= '0; case_id <= CASE16; end
                                else address <= address + 1'b1;
                            end
                        end

                        // case16: (R1,W1) upward.
                        CASE16: begin
                            if (step == 0) begin test_ren <= 1'b1; expected_data <= ALL_1; step <= 1; end
                            else begin
                                test_error_BL <= test_error_BL | compare_error;
                                test_wen <= 1'b1; Mbist_pattern <= ALL_1; expected_data <= ALL_1; step <= 0;
                                if (address == LAST_ADDR) begin address <= '0; case_id <= CASE17; end
                                else address <= address + 1'b1;
                            end
                        end

                        // case17/18: (R1,W0) upward.
                        CASE17: begin
                            if (step == 0) begin test_ren <= 1'b1; expected_data <= ALL_1; step <= 1; end
                            else begin
                                test_error_BL <= test_error_BL | compare_error;
                                test_wen <= 1'b1; Mbist_pattern <= ALL_0; expected_data <= (address == '0) ? ALL_1 : ALL_0; step <= 0;
                                if (address == LAST_ADDR) begin state <= ST_RESULT; end
                                else address <= address + 1'b1;
                            end
                        end

                        default: state <= ST_RESULT;
                    endcase
                end

                ST_RESULT: begin
                    testMemory <= 1'b0;
                    test_wen   <= 1'b0;
                    test_ren   <= 1'b0;
                    test_busy  <= 1'b1;
                    // No logical error means the memory is valid.  One bad
                    // bit in a 128+1 bank is repairable: report its address
                    // and keep out_of_repair low.  Only multiple bad bits in
                    // one bank exceed the available repair capacity.
                    if (test_error_BL[BL_WIDTH+3:4] == {BL_WIDTH{1'b0}}) begin
                        test_memory_valid <= 1'b1;
                        out_of_repair     <= 1'b0;
                    end else if (any_multi_error) begin
                        test_memory_valid <= 1'b0;
                        out_of_repair     <= 1'b1;
                    end else begin
                        test_memory_valid <= 1'b0;
                        out_of_repair     <= 1'b0;
                    end
                    // Preserve the original four 8-bit repair-report ports.
                    // A spare-only error still produces valid/address zero,
                    // exactly as the original onehot_position logic did.
                    if (|error_bank0) test_error_sbk0_BL <= {1'b1, first_error_position(error_bank0)};
                    if (|error_bank1) test_error_sbk1_BL <= {1'b1, first_error_position(error_bank1)};
                    if (|error_bank2) test_error_sbk2_BL <= {1'b1, first_error_position(error_bank2)};
                    if (|error_bank3) test_error_sbk3_BL <= {1'b1, first_error_position(error_bank3)};
                    state <= ST_DONE;
                end

                ST_DONE: begin
                    testMemory <= 1'b0;
                    test_busy  <= 1'b0;
                    // Hold completion status until reset or the next BIST
                    // start.  test_done is intentionally not a one-cycle
                    // pulse.
                    test_done  <= 1'b1;
                    state      <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule

// Convenience top level for the actual macro in
// /home/zexing.chen/workspace/anker_release/hdsram256w512btop.sv.
// Compile that macro source together with this file when using this wrapper.
module hdsram256w512b_mbist (
    input         clk,
    input         rst_n,
    input         test_memory_start,
    input  [7:0]  timing_config,
    input  [127:0] repair3,
    input  [127:0] repair2,
    input  [127:0] repair1,
    input  [127:0] repair0,
    input         waen,
    input         raen,
    output        test_done,
    output        test_busy,
    output        test_memory_valid,
    output        out_of_repair,
    output [515:0] test_error_BL
);
    wire        mbist_cen;
    wire        mbist_wen;
    wire        mbist_ren_unused;
    wire        mbist_testMemory;
    wire [511:0] mbist_pattern;
    wire [7:0]  mbist_test_addr;
    wire [7:0]  mbist_addr;
    wire [7:0]  mbist_waddr;
    wire [7:0]  mbist_raddr;
    wire [7:0]  mbist_r_act_id;
    wire        mbist_test_wen;
    wire        mbist_test_ren;
    wire        mbist_test_rst;
    wire [511:0] mbist_din;
    wire [511:0] mbist_dout;
    wire         redsbk0OUT;
    wire         redsbk1OUT;
    wire         redsbk2OUT;
    wire         redsbk3OUT;

    SRAM_MBIST u_mbist (
        .clk               (clk),
        .rst_n             (rst_n),
        .test_memory_start (test_memory_start),
        .sram_rdata        (mbist_dout),
        .redsbk0OUT        (redsbk0OUT),
        .redsbk1OUT        (redsbk1OUT),
        .redsbk2OUT        (redsbk2OUT),
        .redsbk3OUT        (redsbk3OUT),
        .testMemory        (mbist_testMemory),
        .Mbist_pattern     (mbist_pattern),
        .test_addr         (mbist_test_addr),
        .test_wen          (mbist_test_wen),
        .test_ren          (mbist_test_ren),
        .test_rst          (mbist_test_rst),
        .test_waddr        (mbist_waddr),
        .test_raddr        (mbist_raddr),
        .test_r_act_id     (mbist_r_act_id),
        .CEN               (mbist_cen),
        .WEN               (mbist_wen),
        .REN               (mbist_ren_unused),
        .ADDR              (mbist_addr),
        .DIN               (mbist_din),
        .test_done         (test_done),
        .test_busy         (test_busy),
        .test_memory_valid (test_memory_valid),
        .out_of_repair     (out_of_repair),
        .test_error_BL     (test_error_BL),
        .test_error_sbk0_BL(),
        .test_error_sbk1_BL(),
        .test_error_sbk2_BL(),
        .test_error_sbk3_BL()
    );

    hdsram256w512btop u_sram (
        .CK          (clk),
        .CEN         (mbist_cen),
        .WEN         (mbist_wen),
        .ADDR        (mbist_addr),
        .DIN         (mbist_din),
        .DOUT        (mbist_dout),
        // MBIST always operates on the complete 512-bit word.
        .write_mask  (2'b11),
        .read_mask   (2'b11),
        .timing_config(timing_config),
        .repair3     (repair3),
        .repair2     (repair2),
        .repair1     (repair1),
        .repair0     (repair0),
        .waen        (waen),
        .raen        (raen),
        .redsbk0OUT  (redsbk0OUT),
        .redsbk1OUT  (redsbk1OUT),
        .redsbk2OUT  (redsbk2OUT),
        .redsbk3OUT  (redsbk3OUT)
    );
endmodule

// Combined functional-access/MBIST top level.
//
// When test_memory_start is low and the MBIST controller is idle, the
// external CEN/WEN/ADDR/DIN pins access the SRAM normally.  While the MBIST
// controller is running, its generated CEN/WEN/ADDR/DIN signals take over the
// same SRAM pins.  The SRAM is single-port, so functional access must be
// quiescent for the duration of MBIST.
module hdsram256w512b_mbist_top (
    input         CK,
    input         rst_n,
    input         CEN,
    input         WEN,
    input  [7:0]  ADDR,
    input  [511:0] DIN,
    input  [1:0]   read_mask,
    input  [1:0]   write_mask,
    output [511:0] DOUT,

    input  [7:0]   timing_config,
    // CPU repair reports, matching FP4TE_CimMacro_merge_BIST:
    // {valid, 7-bit bad-column address}, one code per 128-bit bank.
    input  [7:0]   test_red_sbk3,
    input  [7:0]   test_red_sbk2,
    input  [7:0]   test_red_sbk1,
    input  [7:0]   test_red_sbk0,
    input          waen,
    input          raen,

    input          test_memory_start,
    output         test_done,
    output         test_busy,
    output         test_memory_valid,
    output         out_of_repair,
    output [515:0] test_error_BL,
    output [7:0]   test_error_sbk0_BL,
    output [7:0]   test_error_sbk1_BL,
    output [7:0]   test_error_sbk2_BL,
    output [7:0]   test_error_sbk3_BL,
    output         redsbk0OUT,
    output         redsbk1OUT,
    output         redsbk2OUT,
    output         redsbk3OUT
);
    wire          mbist_cen;
    wire          mbist_wen;
    wire          mbist_ren_unused;
    wire          mbist_testMemory;
    wire [511:0]  mbist_pattern;
    wire [7:0]    mbist_test_addr;
    wire [7:0]    mbist_addr;
    wire [7:0]    mbist_waddr;
    wire [7:0]    mbist_raddr;
    wire [7:0]    mbist_r_act_id;
    wire          mbist_test_wen;
    wire          mbist_test_ren;
    wire          mbist_test_rst;
    wire [511:0]  mbist_din;
    wire [7:0]    mbist_error_sbk0_BL;
    wire [7:0]    mbist_error_sbk1_BL;
    wire [7:0]    mbist_error_sbk2_BL;
    wire [7:0]    mbist_error_sbk3_BL;
    wire [511:0]  macro_dout;
    wire          macro_redsbk0;
    wire          macro_redsbk1;
    wire          macro_redsbk2;
    wire          macro_redsbk3;

    // Include the launch/result cycles in the select so a functional request
    // cannot slip through on the same edge as MBIST start or completion.
    wire          mbist_select = mbist_testMemory | test_memory_start | test_busy;
    wire          macro_cen = mbist_select ? mbist_cen : CEN;
    wire          macro_wen = mbist_select ? mbist_wen : WEN;
    wire [7:0]    macro_addr = mbist_select ? mbist_addr : ADDR;
    wire [511:0]  macro_din = mbist_select ? mbist_din : DIN;
    // MBIST always compares a complete 512-bit word.  Functional reads use
    // the externally selected half/full-word mask.
    wire [1:0]    macro_read_mask = mbist_select ? 2'b11 : read_mask;
    // MBIST writes complete words; functional writes use the external mask.
    wire [1:0]    macro_write_mask = mbist_select ? 2'b11 : write_mask;

    function automatic [127:0] redundancyMUX;
        input [7:0] error_BL;
        begin
            // Same conversion as the untouched original BIST source.
            redundancyMUX = error_BL[7] ? ({128{1'b1}} << error_BL[6:0]) : 128'd0;
        end
    endfunction

    // Bit 7 is the enable bit.  Bits [6:0] select the failed column.
    // No separate repair_apply signal is required.
    wire [127:0] repair3 = redundancyMUX(test_red_sbk3);
    wire [127:0] repair2 = redundancyMUX(test_red_sbk2);
    wire [127:0] repair1 = redundancyMUX(test_red_sbk1);
    wire [127:0] repair0 = redundancyMUX(test_red_sbk0);

    SRAM_MBIST u_mbist (
        .clk               (CK),
        .rst_n             (rst_n),
        .test_memory_start (test_memory_start),
        .sram_rdata        (macro_dout),
        .redsbk0OUT        (macro_redsbk0),
        .redsbk1OUT        (macro_redsbk1),
        .redsbk2OUT        (macro_redsbk2),
        .redsbk3OUT        (macro_redsbk3),
        .testMemory        (mbist_testMemory),
        .Mbist_pattern     (mbist_pattern),
        .test_addr         (mbist_test_addr),
        .test_wen          (mbist_test_wen),
        .test_ren          (mbist_test_ren),
        .test_rst          (mbist_test_rst),
        .test_waddr        (mbist_waddr),
        .test_raddr        (mbist_raddr),
        .test_r_act_id     (mbist_r_act_id),
        .CEN               (mbist_cen),
        .WEN               (mbist_wen),
        .REN               (mbist_ren_unused),
        .ADDR              (mbist_addr),
        .DIN               (mbist_din),
        .test_done         (test_done),
        .test_busy         (test_busy),
        .test_memory_valid (test_memory_valid),
        .out_of_repair     (out_of_repair),
        .test_error_BL     (test_error_BL),
        .test_error_sbk0_BL(mbist_error_sbk0_BL),
        .test_error_sbk1_BL(mbist_error_sbk1_BL),
        .test_error_sbk2_BL(mbist_error_sbk2_BL),
        .test_error_sbk3_BL(mbist_error_sbk3_BL)
    );

    hdsram256w512btop u_sram (
        .CK           (CK),
        .CEN          (macro_cen),
        .WEN          (macro_wen),
        .ADDR         (macro_addr),
        .DIN          (macro_din),
        .DOUT         (macro_dout),
        .write_mask   (macro_write_mask),
        .read_mask    (macro_read_mask),
        .timing_config(timing_config),
        .repair3      (repair3),
        .repair2      (repair2),
        .repair1      (repair1),
        .repair0      (repair0),
        .waen         (waen),
        .raen         (raen),
        .redsbk0OUT   (macro_redsbk0),
        .redsbk1OUT   (macro_redsbk1),
        .redsbk2OUT   (macro_redsbk2),
        .redsbk3OUT   (macro_redsbk3)
    );

    assign DOUT      = macro_dout;
    assign test_error_sbk0_BL = mbist_error_sbk0_BL;
    assign test_error_sbk1_BL = mbist_error_sbk1_BL;
    assign test_error_sbk2_BL = mbist_error_sbk2_BL;
    assign test_error_sbk3_BL = mbist_error_sbk3_BL;
    assign redsbk0OUT = macro_redsbk0;
    assign redsbk1OUT = macro_redsbk1;
    assign redsbk2OUT = macro_redsbk2;
    assign redsbk3OUT = macro_redsbk3;
endmodule


// Combined MBIST top using the fault configuration written directly in
// hdsram256w512btop_fault_inject.sv.  There are intentionally no fault
// parameters on this wrapper: the model file is the single source of truth.
module hdsram256w512b_mbist_fault_top (
    input         CK,
    input         rst_n,
    input         CEN,
    input         WEN,
    input  [7:0]  ADDR,
    input  [511:0] DIN,
    input  [1:0]   read_mask,
    input  [1:0]   write_mask,
    output [511:0] DOUT,

    input  [7:0]   timing_config,
    // CPU repair reports, matching FP4TE_CimMacro_merge_BIST:
    // {valid, 7-bit bad-column address}, one code per 128-bit bank.
    input  [7:0]   test_red_sbk3,
    input  [7:0]   test_red_sbk2,
    input  [7:0]   test_red_sbk1,
    input  [7:0]   test_red_sbk0,
    input          waen,
    input          raen,

    input          test_memory_start,
    output         test_done,
    output         test_busy,
    output         test_memory_valid,
    output         out_of_repair,
    output [515:0] test_error_BL,
    output [7:0]   test_error_sbk0_BL,
    output [7:0]   test_error_sbk1_BL,
    output [7:0]   test_error_sbk2_BL,
    output [7:0]   test_error_sbk3_BL,
    output         redsbk0OUT,
    output         redsbk1OUT,
    output         redsbk2OUT,
    output         redsbk3OUT
);
    wire          mbist_cen;
    wire          mbist_wen;
    wire          mbist_ren_unused;
    wire          mbist_testMemory;
    wire [511:0]  mbist_pattern;
    wire [7:0]    mbist_test_addr;
    wire [7:0]    mbist_addr;
    wire [7:0]    mbist_waddr;
    wire [7:0]    mbist_raddr;
    wire [7:0]    mbist_r_act_id;
    wire          mbist_test_wen;
    wire          mbist_test_ren;
    wire          mbist_test_rst;
    wire [511:0]  mbist_din;
    wire [7:0]    mbist_error_sbk0_BL;
    wire [7:0]    mbist_error_sbk1_BL;
    wire [7:0]    mbist_error_sbk2_BL;
    wire [7:0]    mbist_error_sbk3_BL;
    wire [511:0]  macro_dout;
    wire          macro_redsbk0;
    wire          macro_redsbk1;
    wire          macro_redsbk2;
    wire          macro_redsbk3;

    // Include the launch/result cycles in the select so a functional request
    // cannot slip through on the same edge as MBIST start or completion.
    wire          mbist_select = mbist_testMemory | test_memory_start | test_busy;
    wire          macro_cen = mbist_select ? mbist_cen : CEN;
    wire          macro_wen = mbist_select ? mbist_wen : WEN;
    wire [7:0]    macro_addr = mbist_select ? mbist_addr : ADDR;
    wire [511:0]  macro_din = mbist_select ? mbist_din : DIN;
    wire [1:0]    macro_read_mask = mbist_select ? 2'b11 : read_mask;
    wire [1:0]    macro_write_mask = mbist_select ? 2'b11 : write_mask;

    function automatic [127:0] redundancyMUX;
        input [7:0] error_BL;
        begin
            // Same conversion as the untouched original BIST source.
            redundancyMUX = error_BL[7] ? ({128{1'b1}} << error_BL[6:0]) : 128'd0;
        end
    endfunction

    // Bit 7 is the enable bit.  Bits [6:0] select the failed column.
    // No separate repair_apply signal is required.
    wire [127:0] repair3 = redundancyMUX(test_red_sbk3);
    wire [127:0] repair2 = redundancyMUX(test_red_sbk2);
    wire [127:0] repair1 = redundancyMUX(test_red_sbk1);
    wire [127:0] repair0 = redundancyMUX(test_red_sbk0);

    SRAM_MBIST u_mbist (
        .clk               (CK),
        .rst_n             (rst_n),
        .test_memory_start (test_memory_start),
        .sram_rdata        (macro_dout),
        .redsbk0OUT        (macro_redsbk0),
        .redsbk1OUT        (macro_redsbk1),
        .redsbk2OUT        (macro_redsbk2),
        .redsbk3OUT        (macro_redsbk3),
        .testMemory        (mbist_testMemory),
        .Mbist_pattern     (mbist_pattern),
        .test_addr         (mbist_test_addr),
        .test_wen          (mbist_test_wen),
        .test_ren          (mbist_test_ren),
        .test_rst          (mbist_test_rst),
        .test_waddr        (mbist_waddr),
        .test_raddr        (mbist_raddr),
        .test_r_act_id     (mbist_r_act_id),
        .CEN               (mbist_cen),
        .WEN               (mbist_wen),
        .REN               (mbist_ren_unused),
        .ADDR              (mbist_addr),
        .DIN               (mbist_din),
        .test_done         (test_done),
        .test_busy         (test_busy),
        .test_memory_valid (test_memory_valid),
        .out_of_repair     (out_of_repair),
        .test_error_BL     (test_error_BL),
        .test_error_sbk0_BL(mbist_error_sbk0_BL),
        .test_error_sbk1_BL(mbist_error_sbk1_BL),
        .test_error_sbk2_BL(mbist_error_sbk2_BL),
        .test_error_sbk3_BL(mbist_error_sbk3_BL)
    );

    hdsram256w512btop_fault_inject u_sram (
        .CK           (CK),
        .CEN          (macro_cen),
        .WEN          (macro_wen),
        .ADDR         (macro_addr),
        .DIN          (macro_din),
        .DOUT         (macro_dout),
        .write_mask   (macro_write_mask),
        .read_mask    (macro_read_mask),
        .timing_config(timing_config),
        .repair3      (repair3),
        .repair2      (repair2),
        .repair1      (repair1),
        .repair0      (repair0),
        .waen         (waen),
        .raen         (raen),
        .redsbk0OUT   (macro_redsbk0),
        .redsbk1OUT   (macro_redsbk1),
        .redsbk2OUT   (macro_redsbk2),
        .redsbk3OUT   (macro_redsbk3)
    );

    assign DOUT      = macro_dout;
    assign test_error_sbk0_BL = mbist_error_sbk0_BL;
    assign test_error_sbk1_BL = mbist_error_sbk1_BL;
    assign test_error_sbk2_BL = mbist_error_sbk2_BL;
    assign test_error_sbk3_BL = mbist_error_sbk3_BL;
    assign redsbk0OUT = macro_redsbk0;
    assign redsbk1OUT = macro_redsbk1;
    assign redsbk2OUT = macro_redsbk2;
    assign redsbk3OUT = macro_redsbk3;
endmodule
