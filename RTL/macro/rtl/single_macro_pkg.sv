`timescale 1ns / 1ps
`default_nettype none
package single_macro_pkg;
  localparam logic [1:0] W_MODE_2 = 2'd0;
  localparam logic [1:0] W_MODE_4 = 2'd1;
  localparam logic [1:0] W_MODE_8 = 2'd2;
  localparam int PIPE_LATENCY = 1;

endpackage
`default_nettype wire
