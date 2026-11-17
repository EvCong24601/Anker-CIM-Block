// Independent Macro golden model: decode the full integer weights and take a dot
// product; it does not replicate the DUT digit-fusion structure.
// This file is included inside the parent TB module scope and is not a stand-alone
// compilation unit.
// Shared signals/counters are declared in the parent TB; do not add a module or any
// extra begin/end scope.

function automatic logic [31:0] random_word();
  random_state = random_state ^ (random_state << 13);
  random_state = random_state ^ (random_state >> 17);
  random_state = random_state ^ (random_state << 5);
  return random_state;
endfunction
function automatic logic [1023:0] random_row();
  logic [1023:0] value;
  for (int i = 0; i < 32; i++) value[32*i+:32] = random_word();
  return value;
endfunction
function automatic logic [511:0] random_activation();
  logic [511:0] value;
  for (int i = 0; i < 16; i++) value[32*i+:32] = random_word();
  return value;
endfunction
function automatic int activation_bits(input int precision);
  case (precision)
    0, 2: return 4;
    1, 3, 5: return 8;
    default: return 16;
  endcase
endfunction
function automatic int weight_bits(input int precision);
  case (precision)
    0, 1: return 2;
    2, 3, 4: return 4;
    default: return 8;
  endcase
endfunction
function automatic logic [511:0] padded_activation(input logic [511:0] value, input int precision);
  case (weight_bits(
    precision
  ))
    2: return value;
    4: return {256'b0, value[255:0]};
    default: return {384'b0, value[127:0]};
  endcase
endfunction

// Independent golden: decode whole W2/W4/W8 integers and compute a dot
// product. It deliberately does not reproduce slice routing or bit fusion.
function automatic logic [71:0] golden_phase(input logic [1023:0] row, input logic [511:0] activation,
                                             input logic [2:0] precision, input logic signed_en,
                                             input logic [1:0] phase, input logic [3:0] mask);
  int bw, ba, w, a, sum;
  logic [71:0] result;
  bw = weight_bits(int'(precision));
  ba = activation_bits(int'(precision));
  result = '0;
  for (int c = 0; c < 4; c++) begin
    sum = 0;
    if (mask[c]) begin
      for (int j = 0; j < 256 / bw; j++) begin
        case (bw)
          2: w = int'({1'b0, row[256*c+2*j+:2]});
          4: w = int'({1'b0, row[256*c+4*j+:4]});
          default: w = int'({1'b0, row[256*c+8*j+:8]});
        endcase
        if (signed_en && w >= (1 << (bw - 1))) w -= (1 << bw);
        a = int'({1'b0, activation[4*j+:4]});
        if (signed_en && int'(phase) == ba / 4 - 1 && a >= 8) a -= 16;
        sum += w * a;
      end
    end
    if (sum < -131072 || sum > 131071) $fatal(1, "TB: golden outside signed18");
    result[18*c+:18] = sum[17:0];
  end
  return result;
endfunction
