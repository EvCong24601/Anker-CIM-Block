`timescale 1ns / 1ps
`default_nettype none
// Synchronous single-port SRAM model: requests sample on a rising access
// clock edge. Read data holds until the next read; storage is not reset.
// The parent issues a refresh at R_in and computes during R_in -> R_out.
module MacroWeightSRAM (
  input  logic          clock,
  input  logic          write_enable,
  input  logic [   7:0] write_address,
  input  logic [1023:0] write_data,
  input  logic [   3:0] write_mask,
  input  logic          read_enable,
  input  logic [   7:0] read_address,
  output logic [1023:0] read_data
);
  logic [1023:0] mem[0:255];
  always_ff @(posedge clock) begin
    if (write_enable) begin
      for (int c = 0; c < 4; c++) if (!write_mask[c]) mem[write_address][256*c+:256] <= write_data[256*c+:256];
    end else if (read_enable) read_data <= mem[read_address];
  end
endmodule
`default_nettype wire
