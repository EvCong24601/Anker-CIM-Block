# SingleMacro W8main handcut synthesis.
# RTL: rtl_W8main_handcut. Technology: TSMC 22ULL, 9T HVT, TT 0.8V 25C.
# Target period: 3 ns (333 MHz).
# MacroW8MainTreeCSA is the extracted FA/HA netlist and is dont_touch.
# The final sum in MacroW8MainTree stays RTL and is compiled.
# MacroWeightSRAM is a black box, so its array is absent from the power netlist.
# Run from this directory:
#   dc_shell-xg-t -f dc_SingleMacro_hvt_W8main_handcut_3ns.tcl | tee dc_SingleMacro_hvt_W8main_handcut_3ns.log

set SYN_DIR [file dirname [file normalize [info script]]]
cd $SYN_DIR

set LOG_DATE [clock format [clock seconds] -format "%Y%m%d_%H%M%S"]
set_host_options -max_cores 16
set DESIGN_NAME SingleMacro
set CLK_PERIOD 3
set SUFFIX 333MHz_22nmHVT_TT_W8main_handcut

set NVLM_PATH /lamport/shared/hzzhu/techlib/tn22ull/stdcell/TSMCHOME/digital/Front_End/timing_power_noise/NLDM
set STD_DB $NVLM_PATH/tcbn22ullbwp30p140hvt_110b/tcbn22ullbwp30p140hvttt0p8v25c.db

set target_library $STD_DB
set symbol_library $STD_DB
set link_library "* $STD_DB"

file mkdir ./work_W8main_handcut_3ns
define_design_lib WORK -path ./work_W8main_handcut_3ns
set_svf ${DESIGN_NAME}_W8main_handcut_3ns.svf
set_app_var verilogout_show_unconnected_pins true

set RTL_DIR [file normalize $SYN_DIR/../rtl_W8main_handcut]
source $RTL_DIR/check_csa.tcl

analyze -format sverilog -define SYNTHESIS $RTL_DIR/single_macro_pkg.sv
analyze -format sverilog -define SYNTHESIS $RTL_DIR/MacroClockGate.sv
analyze -format sverilog -define SYNTHESIS $SYN_DIR/blackbox/MacroWeightSRAM.sv
analyze -format sverilog -define SYNTHESIS $RTL_DIR/MacroCompress42.sv
analyze -format sverilog -define SYNTHESIS $RTL_DIR/MacroFullWeightPairLUT.sv
analyze -format sverilog -define SYNTHESIS $RTL_DIR/MacroW8MainEntry.sv
analyze -format sverilog -define SYNTHESIS $RTL_DIR/MacroW8MainTreeCSA.sv
analyze -format sverilog -define SYNTHESIS $RTL_DIR/MacroW8MainTree.sv
analyze -format sverilog -define SYNTHESIS $RTL_DIR/MacroW8MainCorrection.sv
analyze -format sverilog -define SYNTHESIS $RTL_DIR/MacroW8MainOC.sv
analyze -format sverilog -define SYNTHESIS $RTL_DIR/SingleMacro.sv

elaborate $DESIGN_NAME
current_design ${DESIGN_NAME}
link

set sram_cells [get_cells -hier -filter "ref_name == MacroWeightSRAM"]
if {[sizeof_collection $sram_cells] == 0} {
    echo "Error: MacroWeightSRAM black box instance was not created"
    exit 1
}
set_dont_touch $sram_cells
set_boundary_optimization [get_designs MacroWeightSRAM] false
echo "Info: MacroWeightSRAM kept as black box for compute-only PTPX."

# 3 ns is 333 MHz. Same absolute clock constraints as dc_SingleMacro_hvt_W8main_3ns.tcl.
# No port input/output delay and no reset false path.
create_clock -name clock -period $CLK_PERIOD [get_ports clock]
set_false_path -fall_from [get_clocks *]
set_clock_uncertainty -setup 0.125 [all_clocks]
set_clock_uncertainty -hold 0.05 [all_clocks]
set_clock_transition 0.1 [all_clocks]
set_clock_latency 0.2 [all_clocks]

set_max_transition 0.4 [current_design]
set_max_area 0

set_fix_hold [all_clocks]
set_fix_multiple_port_nets -buffer_constants -all

source $RTL_DIR/preserve_csa.tcl
check_csa_structure ./work_W8main_handcut_3ns/csa_pre_compile.txt

compile_ultra -no_autoungroup

set REPORTS reports_${DESIGN_NAME}/${LOG_DATE}_${SUFFIX}
set SYN_FILES syn_files_${DESIGN_NAME}/${LOG_DATE}_${SUFFIX}
file delete -force $SYN_FILES
file delete -force $REPORTS
file mkdir $SYN_FILES
file mkdir $REPORTS

check_csa_structure $REPORTS/${DESIGN_NAME}.csa.rpt

report_port -verbose > $REPORTS/${DESIGN_NAME}_port_verbose.rpt
report_clock > $REPORTS/${DESIGN_NAME}_clock.rpt
check_design > $REPORTS/${DESIGN_NAME}_check.rpt
report_power -hierarchy > $REPORTS/${DESIGN_NAME}.hierarchy.power
report_power > $REPORTS/${DESIGN_NAME}.power
report_area -hierarchy > $REPORTS/${DESIGN_NAME}.area
report_timing -significant_digits 5 > $REPORTS/${DESIGN_NAME}.max.timing
report_timing -significant_digits 5 -delay_type min > $REPORTS/${DESIGN_NAME}.min.timing
report_constraint -verbose > $REPORTS/${DESIGN_NAME}.constraint
report_constraint -all_violators > $REPORTS/${DESIGN_NAME}.violation
report_clock_gating -verbose > $REPORTS/${DESIGN_NAME}.icg
report_clock_gating -gating_elements > $REPORTS/${DESIGN_NAME}.elements.icg

write -h $DESIGN_NAME -output ./$SYN_FILES/${DESIGN_NAME}.db
write_file -format ddc -hierarchy -output ./$SYN_FILES/${DESIGN_NAME}.ddc
write_sdf -context verilog -version 1.0 ./$SYN_FILES/${DESIGN_NAME}.syn.sdf
write -h -f verilog $DESIGN_NAME -output ./$SYN_FILES/${DESIGN_NAME}.syn.v -pg
write_sdc ./$SYN_FILES/${DESIGN_NAME}.sdc

set_svf -off
exit
