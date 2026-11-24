// Single-port 6T SRAM behavioral model.
//
// Organization:
//   256 word lines, selected by ADDR[7:0]
//   512 logical bits per word
//   four 128-bit redundancy banks
//   one spare physical column per bank
//
// Operation control:
//   CEN = 0 : chip selected; perform one synchronous operation
//   CEN = 1 : chip deselected; hold DOUT
//   WEN = 0 : write DIN into ADDR
//   WEN = 1 : read ADDR into DOUT

`timescale 1ns/1ps
module hdsram256w512btop (
    input CK,
    input CEN,
    input WEN,
    input [7:0] ADDR,
    input [511:0] DIN,
    // Write-port selection.  01 writes logical bits [255:0], 10 writes
    // logical bits [511:256], and 11 writes the complete 512-bit word.
    // The unselected half keeps its previous SRAM value.  00 is a no-op.
    input [1:0] write_mask,
    // Read-port selection.  01 exposes logical bits [255:0], 10 exposes
    // logical bits [511:256], and 11 exposes the complete 512-bit word.
    // The unselected half keeps its previous registered DOUT value; 00 is
    // intentionally undefined and drives DOUT to X on a read.
    input [1:0] read_mask,
    output reg [511:0] DOUT,

    // Test/repair configuration pins.  testcode is retained as a macro pin;
    // the four MUX vectors select the logical-to-physical column remap.
    input [7:0] timing_config,
    input [127:0] repair3,
    input [127:0] repair2,
    input [127:0] repair1,
    input [127:0] repair0,
    input waen,
    input raen,

    // Spare-column observation for the single read port. MBIST pin.
    output reg redsbk0OUT,
    output reg redsbk1OUT,
    output reg redsbk2OUT,
    output reg redsbk3OUT
);

    localparam integer BANKS = 4;
    localparam integer LOGICAL_BITS_PER_BANK = 128;
    localparam integer PHYSICAL_BITS_PER_BANK = 129;
    localparam integer WORD_LINES = 256;
    localparam integer PHYSICAL_ROWS = BANKS * WORD_LINES;

    integer b;
    integer j;
    integer p;
    integer physical_index;
    wire clk_d;

    reg [PHYSICAL_BITS_PER_BANK-1:0] physical_mem [0:PHYSICAL_ROWS-1];

    function mux_select;
        input integer bank;
        input integer bit_number;
        reg selected;
        begin
            case (bank)
                0: selected = repair0[bit_number];
                1: selected = repair1[bit_number];
                2: selected = repair2[bit_number];
                3: selected = repair3[bit_number];
                default: selected = 1'bx;
            endcase

            // An omitted optional repair pin is Z.  Treat it as the normal
            // no-repair (all-zero) selector rather than propagating Z into
            // the data path.
            if (selected === 1'bz)
                mux_select = 1'b0;
            else
                mux_select = selected;
        end
    endfunction

    // Return the logical value that should be written for one bit.  When the
    // bit is outside write_mask, read the old logical value through the same
    // repair mapping used by the read path.  This lets a partial write update
    // only one 256-bit half while preserving the other half physically.
    function automatic write_value;
        input integer bank;
        input integer row;
        input integer logical_bit;
        input [511:0] write_data;
        input [1:0] write_sel;
        integer idx;
        integer global_bit;
        reg old_value;
        begin
            idx = bank * WORD_LINES + row;
            global_bit = bank * LOGICAL_BITS_PER_BANK + logical_bit;
            old_value = mux_select(bank, logical_bit) ?
                        physical_mem[idx][logical_bit + 1] :
                        physical_mem[idx][logical_bit];
            case (write_sel)
                2'b11: write_value = write_data[global_bit];
                2'b01: write_value = (global_bit < 256) ?
                                      write_data[global_bit] : old_value;
                2'b10: write_value = (global_bit >= 256) ?
                                      write_data[global_bit] : old_value;
                default: write_value = old_value;
            endcase
        end
    endfunction

    // Retain the 100-ps macro-level clock delay used by the previous model.
    assign #1.5 clk_d = CK;

    always @(posedge clk_d) begin
        case (CEN)
            1'b0: begin
                case (WEN)
                    // One synchronous write operation.
                    1'b0: begin
                        for (b = 0; b < BANKS; b = b + 1) begin
                            physical_index = b * WORD_LINES + ADDR;

                            physical_mem[physical_index][0] <=
                                write_value(b, ADDR, 0, DIN, write_mask);

                            for (p = 1; p < LOGICAL_BITS_PER_BANK; p = p + 1) begin
                                physical_mem[physical_index][p] <= mux_select(b, p) ?
                                    write_value(b, ADDR, p - 1, DIN, write_mask) :
                                    write_value(b, ADDR, p, DIN, write_mask);
                            end

                            // Extracted write-MUX behavior for the spare
                            // physical column.
                            physical_mem[physical_index][128] <=
                                mux_select(b, 127) ?
                                    write_value(b, ADDR, 127, DIN, write_mask) :
                                    write_value(b, ADDR, 126, DIN, write_mask);
                        end
                    end

                    // One synchronous read operation.  The SRAM still has
                    // all 512 sense amplifiers; read_mask only selects which
                    // half is presented at the external read port.
                    // DOUT holds during a write or while CEN is inactive.
                    1'b1: begin
                        case (read_mask)
                            2'b11: begin
                                for (b = 0; b < BANKS; b = b + 1) begin
                                    physical_index = b * WORD_LINES + ADDR;

                                    for (j = 0; j < LOGICAL_BITS_PER_BANK; j = j + 1) begin
                                        DOUT[b*LOGICAL_BITS_PER_BANK + j] <=
                                            mux_select(b, j) ?
                                            physical_mem[physical_index][j + 1] :
                                            physical_mem[physical_index][j];
                                    end
                                end
                            end

                            2'b01: begin
                                for (b = 0; b < 2; b = b + 1) begin
                                    physical_index = b * WORD_LINES + ADDR;
                                    for (j = 0; j < LOGICAL_BITS_PER_BANK; j = j + 1) begin
                                        DOUT[b*LOGICAL_BITS_PER_BANK + j] <=
                                            mux_select(b, j) ?
                                            physical_mem[physical_index][j + 1] :
                                            physical_mem[physical_index][j];
                                    end
                                end
                            end

                            2'b10: begin
                                for (b = 2; b < BANKS; b = b + 1) begin
                                    physical_index = b * WORD_LINES + ADDR;
                                    for (j = 0; j < LOGICAL_BITS_PER_BANK; j = j + 1) begin
                                        DOUT[b*LOGICAL_BITS_PER_BANK + j] <=
                                            mux_select(b, j) ?
                                            physical_mem[physical_index][j + 1] :
                                            physical_mem[physical_index][j];
                                    end
                                end
                            end

                            default: DOUT <= {512{1'bx}};
                        endcase

                        // Spare-column observations remain available for all
                        // read masks, including the two half-read modes.
                        for (b = 0; b < BANKS; b = b + 1) begin
                            physical_index = b * WORD_LINES + ADDR;
                            case (b)
                                0: redsbk0OUT <= physical_mem[physical_index][128];
                                1: redsbk1OUT <= physical_mem[physical_index][128];
                                2: redsbk2OUT <= physical_mem[physical_index][128];
                                3: redsbk3OUT <= physical_mem[physical_index][128];
                            endcase
                        end
                    end

                    // Unknown WEN means that the operation is ambiguous.  Do
                    // not alter the array, but make the sampled output X.
                    default: begin
                        DOUT <= {512{1'bx}};
                        redsbk0OUT <= 1'bx;
                        redsbk1OUT <= 1'bx;
                        redsbk2OUT <= 1'bx;
                        redsbk3OUT <= 1'bx;
                    end
                endcase
            end

            // CEN high deselects the macro; all registered outputs hold.
            1'b1: begin
            end

            // Unknown chip select makes the operation/output unknown without
            // corrupting a physical row speculatively.
            default: begin
                DOUT <= {512{1'bx}};
                redsbk0OUT <= 1'bx;
                redsbk1OUT <= 1'bx;
                redsbk2OUT <= 1'bx;
                redsbk3OUT <= 1'bx;
            end
        endcase
    end

endmodule
