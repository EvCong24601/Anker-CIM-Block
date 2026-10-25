// Independent data generation and golden model: random numbers, precision extremes,
// tree grouping, valid OC paths and lane latency.
// This file is included inside the parent TB module scope and is not a stand-alone
// compilation unit.
// Shared signals/counters are declared in the parent TB; do not add a module or any
// extra begin/end scope.

function automatic int unsigned rand32();
  rng = rng ^ (rng << 13);
  rng = rng ^ (rng >> 17);
  rng = rng ^ (rng << 5);
  return rng;
endfunction

function automatic int unsigned sample_bits(input int bits, input int pattern, input int index,
                                            input bit sign_en, input bit is_weight);
  int unsigned hi, lo;
  hi = sign_en ? (1 << (bits - 1)) - 1 : (1 << bits) - 1;
  lo = sign_en ? 1 << (bits - 1) : 0;
  case (pattern)
    0: return rand32() & ((1 << bits) - 1);
    1: return 0;
    2: return hi;
    3: return lo;
    4: return index % 2 ? hi : lo;
    default: return ((index % 2) != int'(is_weight)) ? hi : lo;
  endcase
endfunction
// Independent recursive decoder for the numerical scoreboard.
task automatic decode_groups(input logic [6:0] s, input int node, input int start, input int size,
                             inout int group_id);
  if (size == 1 || !s[node]) begin
    for (int m = start; m < start + size; m++) golden_group[m] = group_id;
    group_id++;
  end else begin
    decode_groups(s, 2 * node + 1, start, size / 2, group_id);
    decode_groups(s, 2 * node + 2, start + size / 2, size / 2, group_id);
  end
endtask
// Independent path walk for the numerical scoreboard. Only traverse
// merges within this leaf's decoded endpoint, not unrelated split groups.
function automatic bit golden_oc_path(input int m, input int c, input logic [31:0] oc);
  int first, size;
  first = m;
  size  = 1;
  for (int j = 0; j < 8; j++)
  if (golden_group[j] == golden_group[m]) begin
    if (j < first) first = j;
  end
  while (size <= 8) begin
    if (!oc[4*((m/size)*size)+c]) return 0;
    if ((m / size) * size == first && (first + size == 8 || golden_group[first+size] != golden_group[m])) return 1;
    size *= 2;
  end
  return 0;
endfunction
function automatic bit legal_k(input int p, input logic [6:0] split);
  int count;
  for (int g = 0; g < 8; g++) begin
    count = 0;
    for (int m = 0; m < 8; m++) if (EN_MASK[m] && group_of(split, m) == g) count++;
    if (count * (256 / wbits(p)) >= 256) return 0;
  end
  return 1;
endfunction
function automatic logic [23:0] make_slots(input logic [6:0] split);
  logic [23:0] slots;
  int rank;
  slots = '0;
  for (int m = 0; m < 8; m++)
  if (EN_MASK[m]) begin
    rank = 0;
    for (int j = 0; j < m; j++) if (EN_MASK[j] && group_of(split, j) == group_of(split, m)) rank++;
    slots[3*m+:3] = 3'(rank);
  end
  return slots;
endfunction
function automatic int lane_latency(input int lane);
  int size;
  size = 0;
  for (int m = 0; m < 8; m++) if (golden_group[m] == lane / 4) size++;
  return size <= 2 ? 3 : size == 4 ? 4 : 5;
endfunction
