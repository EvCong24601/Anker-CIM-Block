// Read and independently unpack all matrices, packed rows and ACT slices.
task automatic load_scenario_vectors();
  int fd, status, kr, k0, n;
  longint signed dot;
  logic [7:0] wanted_weight;
  if (!$value$plusargs("GEMM_DATA_DIR=%s", data_dir)) $fatal(1, "GEMM scenario: require GEMM_DATA_DIR");
  description = {"gemm_", SCENARIO};
  if ($value$plusargs("GEMM_CASE_NAME=%s", description)) begin
  end
  fd = $fopen({data_dir, "/case_config.txt"}, "r");
  if (!fd) $fatal(1, "GEMM scenario: cannot open case config");
  status = $fscanf(
    fd,
    "%d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d",
    m_count,
    k_count,
    n_count,
    wb,
    ab,
    precision,
    first_macro,
    macro_count,
    split,
    en,
    slots,
    base_address,
    lane_base,
    first_raw,
    n_tiles,
    per_channel,
    act_zp
  );
  $fclose(fd);
  if (status != 17 || m_count < 1 || m_count > 16 || k_count < 1 || k_count > 256 || n_count < 1 || n_count > 8 ||
    n_tiles != (n_count + 3) / 4 || wb != wbits(
      precision
    ) || ab != abits(
      precision
    ) || macro_count != wb || lane_base != 4 * (first_macro / macro_count) || first_raw != ab / 4 + (wb == 2 ? 3 : 4))
    $fatal(1, "GEMM scenario: invalid dimensions or physical route");
  case (SCENARIO)
    "w4a16_high_group": if (wb != 4 || ab != 16 || m_count != 8 || k_count != 192 || n_count != 8 || first_macro != 4)
      $fatal(1, "GEMM W4A16 high-group configuration mismatch");
    "w2a8_high_group": if (wb != 2 || ab != 8 || m_count != 8 || k_count != 192 || n_count != 8 || first_macro != 6)
      $fatal(1, "GEMM W2A8 high-group configuration mismatch");
    "w4a16_n6_tail": if (wb != 4 || ab != 16 || m_count != 8 || k_count != 160 || n_count != 6)
      $fatal(1, "GEMM W4A16 N6-tail configuration mismatch");
    "w4a16_round_clip": if (wb != 4 || ab != 16 || m_count != 12 || k_count != 160 || n_count != 4 || !per_channel)
      $fatal(1, "GEMM W4A16 round/clip configuration mismatch");
    default: $fatal(1, "Unknown concrete GEMM scenario");
  endcase
  phases = ab / 4;
  kr = 256 / wb;
  fd = $fopen({data_dir, "/channel_map.txt"}, "r");
  if (!fd) $fatal(1, "GEMM scenario: cannot open channel map");
  for (int tile = 0; tile < n_tiles; tile++)
    for (int c = 0; c < 4; c++) begin
      status = $fscanf(fd, "%d", n_map[tile][c]);
      if (status != 1 || n_map[tile][c] >= n_count) $fatal(1, "GEMM scenario: invalid N map");
    end
  $fclose(fd);
  $readmemh({data_dir, "/x_q.hex"}, x_q, 0, m_count * k_count - 1);
  $readmemh({data_dir, "/w_q.hex"}, w_q, 0, k_count * n_count - 1);
  $readmemh({data_dir, "/raw_golden.hex"}, raw_golden, 0, m_count * n_count - 1);
  $readmemh({data_dir, "/quant_golden.hex"}, quant_golden, 0, m_count * n_count - 1);
  $readmemh({data_dir, "/requant_multiplier.hex"}, multiplier, 0, n_count - 1);
  $readmemh({data_dir, "/requant_shift.hex"}, shift, 0, n_count - 1);
  $readmemh({data_dir, "/requant_zp.hex"}, zp, 0, n_count - 1);
  $readmemh({data_dir, "/weight_rows.hex"}, weight_rows, 0, n_tiles * 8 - 1);
  $readmemh({data_dir, "/act_planes.hex"}, act_planes, 0, m_count * phases - 1);
  for (int m = 0; m < m_count; m++)
    for (int c = 0; c < n_count; c++) begin
      dot = 0;
      for (int k = 0; k < k_count; k++)
      dot += longint'($signed(x_q[m*k_count+k])) * longint'($signed(w_q[k*n_count+c]));
      if (raw_golden[m*n_count+c] !== 32'(dot)) $fatal(1, "GEMM scenario: independent unpacked dot product mismatch");
    end
  for (int tile = 0; tile < n_tiles; tile++)
    for (int macro = first_macro; macro < first_macro + macro_count; macro++) begin
      k0 = (macro - first_macro) * kr;
      for (int c = 0; c < 4; c++)
      for (int j = 0; j < kr; j++) begin
        n = n_map[tile][c];
        wanted_weight = 0;
        if (n >= 0 && k0 + j < k_count) wanted_weight = w_q[(k0+j)*n_count+n];
        if (((weight_rows[8 * tile + macro] >> (256 * c + wb * j)) & 1024'((1 << wb) - 1)) !== 1024'(wanted_weight & 8'((1 << wb) - 1)))
          $fatal(1, "GEMM scenario: weight packing mismatch tile=%0d macro=%0d OC=%0d", tile, macro, c);
      end
    end
  for (int m = 0; m < m_count; m++)
    for (int ph = 0; ph < phases; ph++)
      for (int k = 0; k < 256; k++)
        if (act_planes[m*phases+ph][4*k+:4] !== ((k < k_count) ? x_q[m*k_count+k][4*ph+:4] : 4'b0))
          $fatal(1, "GEMM scenario: ACT slice or K-tail packing mismatch");
endtask

// Regular 128B WLC accesses only; no hierarchical SRAM injection.
task automatic load_scenario_weights();
  for (int tile = 0; tile < n_tiles; tile++)
    for (int macro = first_macro; macro < first_macro + macro_count; macro++) begin
      @(negedge clock);
      sram_cs_en = 1;
      sram_wr_en = 1;
      sram_row_addr = 8'(base_address + tile);
      sram_macro_group = 1'(macro / 4);
      sram_bank_sel = 2'(macro % 4);
      sram_wrdata = weight_rows[8*tile+macro];
    end
  @(negedge clock);
  sram_wr_en = 0;
  for (int tile = 0; tile < n_tiles; tile++)
    for (int macro = first_macro; macro < first_macro + macro_count; macro++) begin
      sram_row_addr = 8'(base_address + tile);
      sram_macro_group = 1'(macro / 4);
      sram_bank_sel = 2'(macro % 4);
      @(posedge clock);
      #1;
      if (!sram_rd_valid || sram_rd_data !== weight_rows[8*tile+macro]) $fatal(1, "GEMM scenario: SRAM readback mismatch");
      @(negedge clock);
    end
  sram_cs_en = 0;
endtask

task automatic send_scenario_tile(input int tile);
  logic [3:0] oc;
  int n;
  oc = 0;
  requant_cfg_i = '0;
  active_mask = 0;
  requant_cfg_i.conv_mode = 1;
  requant_cfg_i.requant_mode = 1'(per_channel);
  requant_cfg_i.requant_multiplier[0+:32] = multiplier[0];
  requant_cfg_i.requant_shift[0+:10] = shift[0];
  for (int c = 0; c < 4; c++) begin
    n = n_map[tile][c];
    if (n >= 0) begin
      oc[c] = 1;
      active_mask[lane_base+c] = 1;
      requant_cfg_i.requant_zp[32*c+:32] = zp[n];
      if (per_channel) begin
        requant_cfg_i.requant_multiplier[32*c+:32] = multiplier[n];
        requant_cfg_i.requant_shift[10*c+:10] = shift[n];
      end
      $display(
        "[REQUANT_CONFIG] time=%0.3f ns description=fixed-OC-parameter-map tile=%0d OC=%0d n=%0d multiplier=%0d shift=%0d zp=%0d",
        $realtime, tile, c, n, $signed(multiplier[n]), $signed(shift[n]), $signed(zp[n]));
    end
  end
  cmd_i = '0;
  cmd_i.cim_os_cnt = 1;
  cmd_i.cim_ws_cnt = 8'(m_count);
  cmd_i.cim_as_cnt = 1;
  cmd_i.cim_precision = 3'(precision);
  cmd_i.cim_signed_en = 1;
  cmd_i.cim_macro_en_mask = 8'(en);
  cmd_i.cim_reduce_split_mask = 7'(split);
  cmd_i.cim_macro_oc_mask = {8{oc}};
  cmd_i.cim_weight_raddr = 8'(base_address + tile);
  cmd_i.cim_act_slot_sel = 24'(slots);
  for (int m = 0; m < m_count; m++) begin
    for (int ph = 0; ph < phases; ph++) begin
      @(negedge clock);
      cmd_valid_i = (ph == 0);
      act_data_i  = act_planes[m*phases+ph];
      $display(
        "[ACT_SEND] time=%0.3f ns description=edge-GEMM-row-and-slice tile=%0d row=%0d slice=%0d command=%0d address=0x%02h",
        $realtime, tile, m, ph, cmd_valid_i, cmd_i.cim_weight_raddr);
      @(posedge clock);
      if (ph == 0 && !cmd_ready_o) $fatal(1, "GEMM scenario: Command not accepted on schedule");
      #1;
    end
    @(negedge clock);
    cmd_valid_i = 0;
    act_data_i  = '1;
    @(posedge clock);
    #1;
  end
endtask
