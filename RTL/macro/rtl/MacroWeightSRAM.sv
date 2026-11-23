`timescale 1ns / 1ps
`default_nettype none
// One logical weight row spans two single-port SRAMs: OC0/1 below OC2/3.
module MacroWeightSRAM (
  input  logic          clock,
  input  logic          write_enable,
  input  logic [   7:0] write_address,
  input  logic [1023:0] write_data,
  input  logic [   3:0] write_mask,
  input  logic          read_enable,
  input  logic [   7:0] read_address,
  input  logic [   3:0] read_oc_mask,
  output wire  [1023:0] read_data
);
  wire [7:0] address = write_enable ? write_address : read_address;

  for (genvar bank = 0; bank < 2; bank++) begin : g_bank
    // The external mask uses 1 to preserve an OC; the SRAM uses 1 to write it.
    wire [1:0] bank_write_mask = ~write_mask[2*bank+:2];
    wire [1:0] bank_read_mask = read_oc_mask[2*bank+:2];
    wire bank_write = write_enable && (|bank_write_mask);
    wire bank_read = !write_enable && read_enable && (|bank_read_mask);

    hdsram256w512btop u_sram (
      .CK(clock),
      .CEN(!(bank_write || bank_read)),
      .WEN(!bank_write),
      .ADDR(address),
      .DIN(write_data[512*bank+:512]),
      .write_mask(bank_write_mask),
      .read_mask(bank_read_mask),
      .DOUT(read_data[512*bank+:512]),
      .timing_config(8'b0),
      .repair3(128'b0),
      .repair2(128'b0),
      .repair1(128'b0),
      .repair0(128'b0),
      .waen(1'b0),
      .raen(1'b0),
      .redsbk0OUT(),
      .redsbk1OUT(),
      .redsbk2OUT(),
      .redsbk3OUT()
    );
  end
endmodule
`default_nettype wire
