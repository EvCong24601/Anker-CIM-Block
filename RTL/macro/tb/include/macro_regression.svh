// 正向场景顺序、随机回归与总账检查；含独立 primitive 穷举和 watchdog。
// 本文件在父 TB 的 module 作用域内 include，不作为独立编译单元。
// 共享信号/计数器在父 TB 声明；不要添加 module 或额外 begin/end 层次。

initial begin : stimulus
  int w_value, a_value, primitive_expected, ba;
  logic [1023:0] row;
  logic [511:0] activation;
  logic [31:0] random_control;
  logic [7:0] address;
  logic station;
  logic [2:0] precision;
  logic [1:0] phase;
  if ($value$plusargs("SEED=%d", random_state)) begin
  end
  if ($value$plusargs("NEGATIVE=%s", negative_case)) negative_mode = 1;
  // Generate a real asynchronous assertion edge even if the functional
  // clock gate remains closed throughout reset.
  #1 reset = 1;
  case_description = "exhaustive-2x4-primitive";

  for (int sw = 0; sw < 2; sw++)
  for (int sa = 0; sa < 2; sa++)
  for (int w = 0; w < 4; w++)
  for (int a = 0; a < 16; a++) begin
    display_case($sformatf("2x4-primitive weight_signed=%0d act_signed=%0d w=%0d a=%0d", sw, sa, w, a));
    mul_sw = (sw != 0);
    mul_sa = (sa != 0);
    mul_w = w[1:0];
    mul_a = a[3:0];
    w_value = (sw && w >= 2) ? w - 4 : w;
    a_value = (sa && a >= 8) ? a - 16 : a;
    primitive_expected = w_value * a_value;
    #1;
    if ($signed(mul_product) != primitive_expected) $fatal(1, "TB: 2x4 primitive mismatch");
    primitive_count++;
  end
  @(negedge clock);
  reset = 0;
  if (negative_mode) run_negative(negative_case);

  // All 256 rows, including boundary addresses, with consecutive writes.
  case_description = "all-256-rows/consecutive-preload";
  for (int i = 0; i < 256; i++) begin
    case (i)
      0: row = '0;
      1: row = '1;
      2: row = {128{8'haa}};
      3: row = {128{8'h88}};
      4: row = {128{8'h80}};
      5: row = {128{8'h77}};
      6: row = {128{8'h7f}};
      default: row = random_row();
    endcase
    write_row(i[7:0], row);
  end
  // Immediate first read after last write, then consecutive reuse.
  case_description = "immediate-read-after-write/Hold-reuse";
  send_phase(6, 0, 0, 15, 255, 1, padded_activation('1, 6));
  send_phase(6, 1, 0, 15, 255, 0, padded_activation('1, 6));

  // All precision/sign/phase/OC-mask combinations, back-to-back.
  case_description = "exhaustive-precision-sign-phase-OC-mask";
  for (int p = 0; p < 7; p++)
  for (int sg = 0; sg < 2; sg++)
  for (int ph = 0; ph < activation_bits(p) / 4; ph++)
  for (int mask = 0; mask < 16; mask++) begin
    activation = padded_activation(random_activation(), p);
    send_phase(p[2:0], ph[1:0], (sg != 0), mask[3:0], 8'(p * 16 + mask), 1, activation);
  end
  // Explicit unsigned maximum and signed minimum patterns.
  case_description = "unsigned-maximum/signed-minimum";
  send_phase(5, 0, 0, 15, 1, 1, padded_activation('1, 5));
  send_phase(5, 1, 0, 15, 1, 0, padded_activation('1, 5));
  send_phase(6, 3, 1, 15, 4, 1, padded_activation({128{4'h8}}, 6));
  send_phase(0, 0, 1, 15, 2, 1, {128{4'h8}});
  send_phase(2, 0, 1, 15, 3, 1, padded_activation({128{4'h8}}, 2));

  // Hold preserves masked-off OC data and ignores zero-mask refreshes.
  case_description = "Hold-preservation/zero-compute-mask";
  send_phase(3, 0, 1, 1, 5, 1, padded_activation(random_activation(), 3));
  send_phase(3, 1, 1, 15, 5, 0, padded_activation(random_activation(), 3));
  send_phase(7, 3, 1, 0, 6, 1, random_activation());
  send_phase(6, 3, 1, 13, 5, 0, padded_activation(random_activation(), 6));
  drain();

  // A completing refresh survives a zero-mask or ren=0 input. Ensure a
  // different old Hold cannot conceal a dropped refresh.
  case_description = "refresh-completion/zero-mask/idle-input-poison";
  send_phase(5, 0, 0, 15, 1, 1, padded_activation('1, 5));
  send_phase(7, 3, 1, 0, 255, 1, '0);
  send_phase(5, 1, 0, 15, 1, 0, padded_activation('1, 5));
  send_phase(3, 0, 1, 3, 5, 1, padded_activation(random_activation(), 3));
  idle_cycle();
  // Poison live inputs during the accepted request's computation. The
  // registered request must still complete and refresh Row5 correctly.
  cim_idata = '0;
  cim_raddr = 8'd254;
  cim_station = 0;
  cim_precision = 7;
  cim_signed_en = 0;
  cim_phase = 3;
  cim_oc_mask = 15;
  send_phase(3, 1, 1, 15, 5, 0, padded_activation(random_activation(), 3));
  drain();
  // Known unused upper ACT bits must not enter the arithmetic.
  case_description = "unused-upper-ACT-bits";
  send_phase(5, 0, 0, 15, 6, 1, '1);

  // Independent consecutive requests with bubbles and dynamic controls.
  case_description = "random-back-to-back/bubbles/dynamic-controls";
  for (int i = 0; i < 2000; i++) begin
    // The preceding request was driven at a falling edge, not yet
    // accepted. Wait for that acceptance before choosing a reuse row.
    // The next drive is still the immediately following falling edge.
    @(posedge clock);
    #2;
    random_control = random_word();
    if (random_control[3:0] == 0) idle_cycle();
    else begin
      precision = 3'(random_control % 7);
      ba = activation_bits(int'(precision));
      phase = 2'((random_control >> 8) % (ba / 4));
      station = random_control[12] || !(reference_hold_valid || pending_refresh);
      // At the next acceptance edge the pending refresh, if any,
      // commits and supersedes the old Hold address.
      address = station ? random_control[23:16] : pending_refresh ? pending_hold_address : reference_hold_address;
      activation = padded_activation(random_activation(), int'(precision));
      send_phase(precision, phase, random_control[13], random_control[7:4], address, station, activation);
    end
  end
  drain();

  // Legal earliest write: last issue n; complete n+1; write at n+2
  // while the previous output is sampled. Also write again at n+3.
  case_description = "earliest-legal-write-after-drain";
  send_phase(5, 0, 0, 15, 255, 1, padded_activation('1, 5));
  idle_cycle();
  write_row(255, {128{8'h12}});
  write_row(254, {128{8'h34}});
  send_phase(5, 0, 0, 15, 254, 1, padded_activation('1, 5));
  send_phase(5, 0, 0, 15, 255, 1, padded_activation('1, 5));
  drain();

  // Interrupt valid transactions asynchronously, retaining SRAM rows.
  case_description = "inflight-reset/SRAM-retention";
  for (int i = 0; i < 6; i++) send_phase(4, i[1:0], 1, 15, 200, 1, padded_activation(random_activation(), 4));
  async_reset();
  send_phase(4, 3, 1, 15, 200, 1, padded_activation(random_activation(), 4));
  send_phase(4, 0, 0, 15, 200, 0, padded_activation(random_activation(), 4));
  drain();
  // Reset also works with an idle, stopped functional clock gate.
  display_case("regular-raw-read/idle-clock-gate");
  @(negedge clock);
  sram_ren   = 1;
  sram_raddr = 8'd254;
  #1;
  if (sram_rdata !== reference_memory[254]) $fatal(1, "TB: regular raw read mismatch");
  @(negedge clock);
  sram_ren = 0;
  async_reset();
  send_phase(0, 0, 0, 15, 0, 1, '1);
  drain();
  @(posedge clock);
  #2;
  if (expected_valid != 0 || accepted_count != result_count + cancelled_count)
    $fatal(1, "TB: outstanding or lost transactions at finish");
  $display("PASS clock_gating=%0d primitive=%0d accepted=%0d results=%0d cancelled=%0d bubbles=%0d zero_mask=%0d",
           CLOCK_GATING, primitive_count, accepted_count, result_count, cancelled_count, bubble_count, zero_mask_count);
  $finish;
end
initial begin
  #2000000;
  $fatal(1, "TB: timeout");
end
