`timescale 1ns / 1ps
// Clock-free unit test: changing inputs must settle without any clock edge.
// Python supplies exact full-range integer golden values for supported shifts.
module tb_ClusterRequant;
  import cluster_pkg::*;
  requant_cfg_t cfg_i;
  logic [1023:0] psum_i;
  logic [31:0] valid_i;
  logic [2:0] group_sel_i = '0;
  wire [255:0] data_o;
  wire [31:0] valid_o;
  ClusterRequant dut (.*);
  task automatic check_isolated_channels();
    if(!(valid_i & (32'h11111111 << 0)) &&
       (dut.g_channel[0].selected_psum !== 0 || dut.g_channel[0].selected_multiplier !== 0 ||
        dut.g_channel[0].selected_shift !== 0 || dut.g_channel[0].selected_zp !== 0))
      $fatal(1, "Requant masked channel 0 consumed Psum/parameter output");
    if(!(valid_i & (32'h11111111 << 1)) &&
       (dut.g_channel[1].selected_psum !== 0 || dut.g_channel[1].selected_multiplier !== 0 ||
        dut.g_channel[1].selected_shift !== 0 || dut.g_channel[1].selected_zp !== 0))
      $fatal(1, "Requant masked channel 1 consumed Psum/parameter output");
    if(!(valid_i & (32'h11111111 << 2)) &&
       (dut.g_channel[2].selected_psum !== 0 || dut.g_channel[2].selected_multiplier !== 0 ||
        dut.g_channel[2].selected_shift !== 0 || dut.g_channel[2].selected_zp !== 0))
      $fatal(1, "Requant masked channel 2 consumed Psum/parameter output");
    if(!(valid_i & (32'h11111111 << 3)) &&
       (dut.g_channel[3].selected_psum !== 0 || dut.g_channel[3].selected_multiplier !== 0 ||
        dut.g_channel[3].selected_shift !== 0 || dut.g_channel[3].selected_zp !== 0))
      $fatal(1, "Requant masked channel 3 consumed Psum/parameter output");
  endtask
  initial begin
    string path, description;
    int fd, status, p, m, s, z, wanted, cases, checks, numeric_checks;
    logic [31:0] vector_mask;
    int mode, mask, cp[4], cm[4], cs[4], cz[4], cq[4], channel_cases;
    cases = 0;
    numeric_checks = 0;
    checks = 0;
    cfg_i = '0;
    psum_i = '0;
    valid_i = '0;
    if (!$value$plusargs("REQUANT_VECTORS=%s", path))
      $fatal(1, "TB: require +REQUANT_VECTORS=PATH (generate with requant_vectors.py)");
    fd = $fopen(path, "r");
    if (!fd) $fatal(1, "TB: cannot open Requant vectors");
    while (!$feof(
      fd
    )) begin
      status = $fscanf(fd, "%d %d %d %d %d %s\n", p, m, s, z, wanted, description);
      if (status != 6) $fatal(1, "TB: malformed Requant vector row");
      $display(
        string'({"[CASE_START] time=%0.3f ns suite=requant_unit case=%0d ",
                 "description=%s psum=%0d multiplier=%0d shift=%0d zp=%0d"}),
        $realtime, cases, description, p, m, s, z);
      cfg_i = '{
        requant_mode: 1'b0,
        requant_multiplier: 32'(m),
        requant_shift: 10'(s),
        requant_zp: {4{32'(z)}},
        default: '0
      };
      for (int lane = 0; lane < 32; lane++) psum_i[32*lane+:32] = 32'(p);
      unique case (cases % 4)
        0: valid_i = 32'h0000000f;
        1: valid_i = 32'h00000000;
        2: valid_i = 32'h05000000;
        3: valid_i = 32'h0000a000;
      endcase
      // Exercise every numeric vector with four active channels first,
      // then check masking/isolation without losing arithmetic coverage.
      vector_mask = valid_i;
      group_sel_i = 0;
      valid_i = 32'hf;
      #0.001;
      for (int c = 0; c < 4; c++) begin
        if (data_o[8*c+:8] !== 8'(wanted)) $fatal(1, "Active numeric vector mismatch");
        numeric_checks++;
      end
      group_sel_i = cases % 4 == 2 ? 3'd6 : cases % 4 == 3 ? 3'd3 : 3'd0;
      valid_i = vector_mask;
      #0.001;
      check_isolated_channels();
      if (valid_o !== valid_i) $fatal(1, "Requant unit valid is not combinational");
      for (int lane = 0; lane < 32; lane++) begin
        if (data_o[8*lane+:8] !== (valid_i[lane] ? 8'(wanted) : 8'b0))
          $fatal(
            1,
            "Requant unit mismatch case=%0d lane=%0d got=%0d expected=%0d",
            cases,
            lane,
            $signed(
              data_o[8*lane+:8]
            ),
            wanted
          );
        checks++;
      end
      cases++;
    end
    $fclose(fd);
    if (cases < 9000) $fatal(1, "Missing Requant unit vector coverage");
    if (!$value$plusargs("REQUANT_CHANNEL_VECTORS=%s", path)) $fatal(1, "TB: require +REQUANT_CHANNEL_VECTORS=PATH");
    fd = $fopen(path, "r");
    channel_cases = 0;
    if (!fd) $fatal(1, "TB: cannot open four-channel vectors");
    while (!$feof(
      fd
    )) begin
      status = $fscanf(fd, "%d %d", mode, mask);
      if (status != 2) $fatal(1, "TB: malformed four-channel vector header");
      for (int c = 0; c < 4; c++) begin
        status = $fscanf(fd, "%d", cp[c]);
        if (status != 1) $fatal(1, "TB: missing psum");
      end
      for (int c = 0; c < 4; c++) begin
        status = $fscanf(fd, "%d", cm[c]);
        if (status != 1) $fatal(1, "TB: missing multiplier");
      end
      for (int c = 0; c < 4; c++) begin
        status = $fscanf(fd, "%d", cs[c]);
        if (status != 1) $fatal(1, "TB: missing shift");
      end
      for (int c = 0; c < 4; c++) begin
        status = $fscanf(fd, "%d", cz[c]);
        if (status != 1) $fatal(1, "TB: missing zp");
      end
      for (int c = 0; c < 4; c++) begin
        status = $fscanf(fd, "%d", cq[c]);
        if (status != 1) $fatal(1, "TB: missing golden");
      end
      // Consume the trailing newline without relying on an extra EOF read.
      status = $fscanf(fd, "\n");
      $display(
        string'({"[CASE_START] time=%0.3f ns suite=requant_channel_unit ",
                 "description=fixed-OC-order-with-mask-holes case=%0d mode=%0d mask=%x"}),
        $realtime, channel_cases, mode, mask);
      cfg_i = '0;
      cfg_i.conv_mode = 1;
      cfg_i.requant_mode = 1'(mode);
      for (int c = 0; c < 4; c++) begin
        cfg_i.requant_multiplier[32*c+:32] = 32'(cm[c]);
        cfg_i.requant_shift[10*c+:10] = 10'(cs[c]);
      end
      for (int l = 0; l < 32; l++) begin
        psum_i[32*l+:32] = 32'(cp[l%4]);
        cfg_i.requant_zp[32*(l%4)+:32] = 32'(cz[l%4]);
        valid_i[l] = (l / 4 == channel_cases % 8) && 1'(mask >> (l % 4));
      end
      vector_mask = valid_i;
      group_sel_i = 3'(channel_cases % 8);
      valid_i = 32'hf << (4 * (channel_cases % 8));
      #0.001;
      for (int l = 0; l < 32; l++)
      if (valid_i[l]) begin
        if (data_o[8*l+:8] !== 8'(cq[l%4])) $fatal(1, "Active per-channel numeric vector mismatch");
        numeric_checks++;
      end
      valid_i = vector_mask;
      #0.001;
      check_isolated_channels();
      if (valid_o !== valid_i) $fatal(1, "Four-channel valid mapping changed");
      for (int l = 0; l < 32; l++)
      if (data_o[8*l+:8] !== (valid_i[l] ? 8'(cq[l%4]) : 8'b0))
        $fatal(1, "Four-channel OC parameter order mismatch lane=%0d", l);
      channel_cases++;
    end
    $fclose(fd);
    if (channel_cases != 512) $fatal(1, "Missing four-channel unit coverage");
    $display("PASS requant_channel_unit cases=%0d lane_checks=%0d masks=16", channel_cases, 32 * channel_cases);
    $display("PASS requant_unit cases=%0d lane_checks=%0d latency=0 no_clock=1 operand_isolation=1 numeric_checks=%0d",
             cases, checks, numeric_checks);
    $finish;
  end

  // VCS supplies a case-specific path; direct runs retain a descriptive default.
`ifdef CLUSTER_FSDB
  initial begin : case_fsdb_dump
    string fsdb_file;
    if (!$value$plusargs("FSDB_FILE=%s", fsdb_file)) fsdb_file = "tb_ClusterRequant_default.fsdb";
    $display("[WAVE] file=%s", fsdb_file);
    $fsdbDumpfile(fsdb_file);
    $fsdbDumpvars(0, tb_ClusterRequant, "+all");
  end
`endif
endmodule
