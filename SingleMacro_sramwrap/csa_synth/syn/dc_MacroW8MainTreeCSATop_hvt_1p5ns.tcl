# Standalone MacroW8MainTreeCSATop synthesis.
# RTL: ../rtl/MacroW8MainTreeCSATop.sv plus the mapped MacroW8MainTreeCSA.sv.
# Technology: TSMC 22ULL, 9T HVT, TT 0.8V 25C.
# Target period: 1.5 ns (666.7 MHz). Inputs and the result are register-to-register.
# The CSA is compiled and may be remapped. correction is tied to 0 in the wrapper.
# The library db is on /lamport; run under srun -p boltzmann when that path is not mounted.
# Run from this directory:
#   dc_shell-xg-t -f dc_MacroW8MainTreeCSATop_hvt_1p5ns.tcl | tee dc_MacroW8MainTreeCSATop_hvt_1p5ns.log

set SYN_DIR [file dirname [file normalize [info script]]]
cd $SYN_DIR

set LOG_DATE [clock format [clock seconds] -format "%Y%m%d_%H%M%S"]
set_host_options -max_cores 16
set DESIGN_NAME MacroW8MainTreeCSATop
set CLK_PERIOD 1.5
set SUFFIX 667MHz_22nmHVT_TT_CSATop

set NVLM_PATH /lamport/shared/hzzhu/techlib/tn22ull/stdcell/TSMCHOME/digital/Front_End/timing_power_noise/NLDM
set STD_DB $NVLM_PATH/tcbn22ullbwp30p140hvt_110b/tcbn22ullbwp30p140hvttt0p8v25c.db

set target_library $STD_DB
set symbol_library $STD_DB
set link_library "* $STD_DB"

file mkdir ./work_CSATop_1p5ns
define_design_lib WORK -path ./work_CSATop_1p5ns
set_svf ${DESIGN_NAME}_1p5ns.svf
set_app_var verilogout_show_unconnected_pins true

set RTL_DIR [file normalize $SYN_DIR/../rtl]

analyze -format sverilog -define SYNTHESIS $RTL_DIR/MacroW8MainTreeCSA.sv
analyze -format sverilog -define SYNTHESIS $RTL_DIR/MacroW8MainTreeCSATop.sv

elaborate $DESIGN_NAME
current_design ${DESIGN_NAME}
link

# 1.5 ns is 666.7 MHz. Same absolute clock constraints as dc_MacroW8MainTreeTop_hvt_1p5ns.tcl.
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

compile_ultra -no_autoungroup

set REPORTS reports_${DESIGN_NAME}/${LOG_DATE}_${SUFFIX}
set SYN_FILES syn_files_${DESIGN_NAME}/${LOG_DATE}_${SUFFIX}
file delete -force $SYN_FILES
file delete -force $REPORTS
file mkdir $SYN_FILES
file mkdir $REPORTS

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
