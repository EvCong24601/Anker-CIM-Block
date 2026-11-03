// Simulation-only checks and reference helpers. Include inside the consuming module.
// Cluster helpers use types and synthesizable helpers already declared in that module.
  function automatic bit canonical(input logic [6:0] s);
    if (!s[0]) return s == 0;
    if (!s[1] && (s[3] || s[4])) return 0;
    if (!s[2] && (s[5] || s[6])) return 0;
    return 1;
  endfunction

  function automatic longint signed number(input int unsigned raw, input int bits, input bit sign_en);
    longint signed n;
    n = raw & ((64'd1 << bits) - 1);
    if (sign_en && ((n >> (bits - 1)) & 1)) n -= 64'd1 << bits;
    return n;
  endfunction
