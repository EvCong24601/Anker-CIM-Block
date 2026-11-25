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
  output wire  [1023:0] read_data,
  input logic reset_n, mbist_start,
  input logic [63:0] repair_config,
  output wire mbist_done, mbist_busy, mbist_valid, mbist_unrepairable,
  output wire [63:0] mbist_errors
);
  wire [7:0] address = write_enable ? write_address : read_address;
  // The v2 model samples its pins 1.5 ns after CK rises. Functional
  // requests are accepted at CK's rising edge: pass them through in the
  // low phase and hold them throughout the high phase, including clk_d.
  logic [7:0] functional_address;
  always_latch if (!clock && (write_enable || read_enable)) functional_address <= address;

  wire [1:0] done, busy, valid, unrepairable;
  assign mbist_done = &done;
  assign mbist_busy = |busy;
  assign mbist_valid = &valid;
  assign mbist_unrepairable = |unrepairable;

  for (genvar bank = 0; bank < 2; bank++) begin : g_bank
    // The external mask uses 1 to preserve an OC; the SRAM uses 1 to write it.
    wire [1:0] bank_write_mask = ~write_mask[2*bank+:2];
    wire [1:0] bank_read_mask = read_oc_mask[2*bank+:2];
    wire bank_write = write_enable && (|bank_write_mask);
    wire bank_read = !write_enable && read_enable && (|bank_read_mask);
    logic functional_cen, functional_wen;
    logic [1:0] functional_write_mask, functional_read_mask;
    logic [511:0] functional_data;
    always_latch begin
      if (!clock) begin
        functional_cen <= !(bank_write || bank_read);
        functional_wen <= !bank_write;
        if (bank_write) begin
          functional_write_mask <= bank_write_mask;
          functional_data <= write_data[512*bank+:512];
        end
        if (bank_read) functional_read_mask <= bank_read_mask;
      end
    end

    // Each v2 wrapper owns one SRAM and its controller. Cluster byte
    // 4*bank + sbk is the repair code and report for that subbank.
    hdsram256w512b_mbist_top u_wrapper (
      .CK(clock), .rst_n(reset_n),
      .CEN(functional_cen), .WEN(functional_wen),
      .ADDR(functional_address), .DIN(functional_data),
      .write_mask(functional_write_mask), .read_mask(functional_read_mask),
      .DOUT(read_data[512*bank+:512]),
      .timing_config(8'b0), .waen(1'b0), .raen(1'b0),
      .test_red_sbk0(repair_config[32*bank+0+:8]),
      .test_red_sbk1(repair_config[32*bank+8+:8]),
      .test_red_sbk2(repair_config[32*bank+16+:8]),
      .test_red_sbk3(repair_config[32*bank+24+:8]),
      .test_memory_start(mbist_start),
      .test_done(done[bank]), .test_busy(busy[bank]),
      .test_memory_valid(valid[bank]), .out_of_repair(unrepairable[bank]),
      .test_error_sbk0_BL(mbist_errors[32*bank+0+:8]),
      .test_error_sbk1_BL(mbist_errors[32*bank+8+:8]),
      .test_error_sbk2_BL(mbist_errors[32*bank+16+:8]),
      .test_error_sbk3_BL(mbist_errors[32*bank+24+:8]),
      .test_error_BL(), .redsbk0OUT(), .redsbk1OUT(), .redsbk2OUT(), .redsbk3OUT()
    );
  end
endmodule
`default_nettype wire
