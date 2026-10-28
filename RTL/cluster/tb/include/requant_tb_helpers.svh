// Simulation-only external per-channel correction after CIM INT8 saturation.
function automatic logic signed [7:0] tb_correct_tensor(
    input logic signed [7:0] cim_int8, input logic signed [31:0] channel_zp);
  longint signed corrected;
  corrected = longint'(cim_int8) + longint'(channel_zp);
  if (corrected > 127) return 8'sd127;
  if (corrected < -128) return -8'sd128;
  return 8'(corrected);
endfunction
