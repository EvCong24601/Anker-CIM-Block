// Logging and drivers: drive writes/computes on falling edges, and provide idle,
// drain and asynchronous-reset_n tasks.
// This file is included inside the parent TB module scope and is not a stand-alone
// compilation unit.
// Shared signals/counters are declared in the parent TB; do not add a module or any
// extra begin/end scope.

task automatic display_case(input string description);
  $display("[CASE_START] time=%0.3f ns suite=single_macro case=%0d description=%s clock_gating=%0d seed=%08h",
           $realtime, test_case_id, description, CLOCK_GATING, random_state);
  test_case_id++;
endtask

// The SRAM wrapper has no reset. Its caller holds all requests inactive while
// resetting control state; cells and retained read output survive in both modes.
task automatic reset_sram_retention();
  logic [1023:0] saved_read;
  display_case("active-low-reset/SRAM-retention-with-idle-requests");
  drain();
  read_row(8'd254);
  saved_read = reference_memory[254];
  #1 reset_n = 0;
  sram_wen = 0;
  sram_ren = 0;
  cim_ren = 0;
  repeat (3) begin
    @(posedge clock);
    #1;
    if (cim_odata_valid !== 0 || cim_odata !== 0 || sram_rdata !== 0 || dut.hold_valid !== 0)
      $fatal(1, "TB: active-low reset did not clear control/output state");
    if (dut.sram_read_data !== saved_read)
      $fatal(1, "TB: reset changed retained SRAM read output");
  end
  @(negedge clock);
  cim_ren = 0;
  sram_ren = 0;
  reset_n = 1;
  read_row(8'd255);
  read_row(8'd254);
  $display("PASS reset_sram_retention clock_gating=%0d", CLOCK_GATING);
endtask
// Drive only at falling edges; sample registered outputs after NBA.
task automatic idle_cycle();
  @(negedge clock);
  cim_ren  = 0;
  sram_wen = 0;
endtask
task automatic drain();
  repeat (3) idle_cycle();
endtask
task automatic write_row(input logic [7:0] address, input logic [1023:0] data, input logic [3:0] write_mask = 4'b0000);
  display_case($sformatf("%s/write-row address=%0d mask=%h", case_description, address, write_mask));
  @(negedge clock);
  cim_ren = 0;
  sram_wen = 1;
  sram_waddr = address;
  sram_wdata = data;
  sram_wmask = write_mask;
endtask
task automatic send_phase(input logic [2:0] precision, input logic [1:0] phase, input logic signed_en,
                          input logic [3:0] mask, input logic [7:0] address, input logic station,
                          input logic [511:0] data);
  display_case($sformatf(
               "%s/phase W%0dA%0d signed=%0d phase=%0d oc_mask=%h row=%0d refresh=%0d",
               case_description,
               weight_bits(
                 precision
               ),
               activation_bits(
                 precision
               ),
               signed_en,
               phase,
               mask,
               address,
               station
               ));
  @(negedge clock);
  cim_ren = 1;
  sram_wen = 0;
  cim_precision = precision;
  cim_phase = phase;
  cim_signed_en = signed_en;
  cim_oc_mask = mask;
  cim_raddr = address;
  cim_station = station;
  cim_idata = data;
endtask
task automatic async_reset(input bit short_pulse = 0);
  display_case("asynchronous-reset_n/cancel-inflight/retain-SRAM");
  @(negedge clock);
  cim_ren  = 0;
  sram_wen = 0;
  #2 reset_n = 0;
  #1;
  if (cim_odata_valid !== 0 || cim_odata !== 0 || cim_odata_oc_mask !== 0 || cim_odata_phase !== 0)
    $fatal(1, "TB: asynchronous reset_n did not immediately clear outputs");
  if (short_pulse) #1;
  else @(negedge clock);
  reset_n = 1;
endtask

// Ordinary SRAM reads replace the same output row later reused by CIM.
task automatic read_row(input logic [7:0] address);
  display_case($sformatf("regular-read/output-row-replacement address=%0d", address));
  @(negedge clock);
  cim_ren = 0;
  sram_wen = 0;
  sram_ren = 1;
  sram_raddr = address;
  @(posedge clock);
  #2ns;  // Sample after the v2 SRAM clock delay.
  if (!negative_mode && sram_rdata !== reference_memory[address])
    $fatal(1, "TB: ordinary read output mismatch row=%0d", address);
  @(negedge clock);
  sram_ren = 0;
endtask
