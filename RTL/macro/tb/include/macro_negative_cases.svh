// 协议负向 case：故意提供非法请求，必须由 SM_PROTOCOL 拒绝。
// 本文件在父 TB 的 module 作用域内 include，不作为独立编译单元。
// 共享信号/计数器在父 TB 声明；不要添加 module 或额外 begin/end 层次。

task automatic run_negative(input string test_name);
  case_description = $sformatf("negative/%s", test_name);
  display_case(case_description);
  write_row(8'd0, {128{8'hff}});
  idle_cycle();
  if (test_name == "precision") send_phase(7, 0, 0, 15, 0, 1, '0);
  else if (test_name == "phase") send_phase(0, 1, 0, 15, 0, 1, '0);
  else if (test_name == "hold_invalid") send_phase(0, 0, 0, 15, 0, 0, '0);
  else if (test_name == "uninitialized") send_phase(0, 0, 0, 15, 255, 1, '0);
  else if (test_name == "masked_uninitialized") begin
    write_row(255, '0, 4'b1110);
    idle_cycle();  // only OC0 initialized; computing OC1 is illegal
    send_phase(2, 0, 0, 2, 255, 1, '0);
  end else if (test_name == "masked_uninitialized_reuse") begin
    write_row(255, '0, 4'b1110);
    idle_cycle();
    send_phase(2, 0, 0, 1, 255, 1, '0);  // initialized OC0 may refresh
    send_phase(2, 0, 0, 2, 255, 0, '0);  // OC1 is still uninitialized
  end else if (test_name == "hold_address") begin
    write_row(1, {128{8'h12}});
    idle_cycle();
    send_phase(0, 0, 0, 15, 0, 1, '0);
    drain();
    read_row(1);
    send_phase(0, 0, 0, 15, 0, 0, '0);
  end else if (test_name == "hold_address_pending") begin
    write_row(8'd1, {128{8'h12}});
    send_phase(0, 0, 0, 15, 0, 1, '0);
    send_phase(0, 0, 0, 15, 1, 1, '0);
    // SRAM output already holds Row1; reusing Row0 must be rejected.
    send_phase(0, 0, 0, 15, 0, 0, '0);
  end else if (test_name == "unknown_write") begin
    write_row(0, '0);
    sram_wdata[1000] = 1'bx;
  end else if (test_name == "unknown_activation") begin
    send_phase(0, 0, 0, 15, 0, 1, '0);
    cim_idata[300] = 1'bx;
  end else if (test_name == "unknown_control") begin
    send_phase(0, 0, 0, 15, 0, 1, '0);
    cim_signed_en = 1'bz;
  end else if (test_name == "read_write") begin
    send_phase(0, 0, 0, 15, 0, 1, '0);
    sram_wen = 1;
  end else if (test_name == "write_busy") begin
    send_phase(0, 0, 0, 15, 0, 1, '0);
    write_row(0, '0);
  end else if (test_name == "hold_after_write") begin
    send_phase(0, 0, 0, 15, 0, 1, '0);
    drain();
    write_row(0, '0);
    send_phase(0, 0, 0, 15, 0, 0, '0);
  end else if (test_name == "hold_after_reset") begin
    send_phase(0, 0, 0, 15, 0, 1, '0);
    drain();
    async_reset();
    send_phase(0, 0, 0, 15, 0, 0, '0);
  end else $fatal(1, "TB: unknown negative case");
  drain();
  $fatal(1, "TB: negative test was not rejected");
endtask
