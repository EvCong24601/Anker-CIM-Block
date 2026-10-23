`timescale 1ns/1ps
`default_nettype none
// Technology-independent storage implementation: synchronous OC-masked write
// and enabled asynchronous read. Read access AND the entire macro arithmetic
// share the parent's R_in -> R_out cycle. No reset, initial contents or bypass.
// A replacement IP must settle early enough for arithmetic and output setup;
// a synchronous read that returns only after the output edge is incompatible.
module MacroWeightSRAM (
    input  logic          clock,
    input  logic          write_enable,
    input  logic [7:0]    write_address,
    input  logic [1023:0] write_data,
    input  logic [3:0]    write_mask,
    input  logic          read_enable,
    input  logic [7:0]    read_address,
    output wire  [1023:0] read_data
);
    logic [1023:0] mem [0:255];
    always_ff @(posedge clock) begin
        if (write_enable)
            for (int c = 0; c < 4; c++)
                if (!write_mask[c])
                    mem[write_address][256*c+:256] <= write_data[256*c+:256];
    end
    assign read_data = read_enable ? mem[read_address] : 1024'b0;
endmodule
`default_nettype wire
