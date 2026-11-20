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
    wire [1:0] bank_read_mask = read_oc_mask[2*bank+:2];
    wire bank_write = write_enable && (write_mask[2*bank+:2] == 2'b00);
    wire bank_read = !write_enable && read_enable && (|bank_read_mask);

    hdsram256w512btop u_sram (
      .CK(clock),
      .CEN(!(bank_write || bank_read)),
      .WEN(!bank_write),
      .ADDR(address),
      .DIN(write_data[512*bank+:512]),
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

`ifndef SYNTHESIS
  always @(posedge clock) begin
    if (write_enable) begin
      case (write_mask)
        4'h0, 4'h3, 4'hc, 4'hf: ;
        default: $fatal(1, "SRAM_WRITE_PROTOCOL: write mask must select whole 512-bit banks");
      endcase
    end
  end
`endif
endmodule
`default_nettype wire
