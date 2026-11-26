# SingleMacro synthesis with the SRAM timing model.
# RTL list: filelist_syn.f. Technology: TSMC 22ULL 9T, TT 0.8V 25C.
# target_library is HVT only. link_library also has the SVT db, so the
# explicit CKLNQD8BWP30P140 ICG can resolve, and the SRAM db.
# Target period: 3.2 ns (312.5 MHz).
# MacroW8MainTreeCSA stays dont_touch. MacroWeightSRAM and its MBIST wrapper
# are compiled. The two hdsram256w512btop leaves are library macros.
# The library db files are on /lamport; run under srun -p boltzmann when
# that path is not mounted.
# Run from this directory:
#   dc_shell-xg-t -f dc_SingleMacro_hvt_sram_3p2ns.tcl | tee dc_SingleMacro_hvt_sram_3p2ns.log

set SYN_DIR [file dirname [file normalize [info script]]]
cd $SYN_DIR

set LOG_DATE [clock format [clock seconds] -format "%Y%m%d_%H%M%S"]
set_host_options -max_cores 16
set DESIGN_NAME SingleMacro
set CLK_PERIOD 3.2
set SUFFIX 312p5MHz_22nmHVT_TT_sramwrap

set NVLM_PATH /lamport/shared/hzzhu/techlib/tn22ull/stdcell/TSMCHOME/digital/Front_End/timing_power_noise/NLDM
set HVT_DB $NVLM_PATH/tcbn22ullbwp30p140hvt_110b/tcbn22ullbwp30p140hvttt0p8v25c.db
set SVT_DB $NVLM_PATH/tcbn22ullbwp30p140_110b/tcbn22ullbwp30p140tt0p8v25c.db
set SRAM_DB [file normalize $SYN_DIR/../lib/hdsram256w512btop_tt_scalar.db]

set target_library $HVT_DB
set symbol_library $HVT_DB
set link_library "* $HVT_DB $SVT_DB $SRAM_DB"

file mkdir ./work_sramwrap_3p2ns
define_design_lib WORK -path ./work_sramwrap_3p2ns
set_svf ${DESIGN_NAME}_sramwrap_3p2ns.svf
set_app_var verilogout_show_unconnected_pins true

set RTL_DIR [file normalize $SYN_DIR/../rtl]
source $RTL_DIR/check_csa.tcl

set filelist [open $SYN_DIR/filelist_syn.f r]
while {[gets $filelist rtl_line] >= 0} {
    set rtl_line [string trim $rtl_line]
    if {$rtl_line eq "" || [string match "#*" $rtl_line]} {
        continue
    }
    analyze -format sverilog -define SYNTHESIS $rtl_line
}
close $filelist

elaborate $DESIGN_NAME
current_design ${DESIGN_NAME}
if {[link] == 0} {
    error "link returned failure for $DESIGN_NAME"
}

set unresolved [get_cells -quiet -hierarchical -filter "is_unresolved == true"]
if {[sizeof_collection $unresolved] != 0} {
    foreach_in_collection c $unresolved {
        puts "Unresolved: [get_object_name $c] ref_name=[get_attribute $c ref_name]"
    }
    error "Unresolved references remain after link."
}

set sram_macros [get_cells -quiet -hierarchical -filter "ref_name == hdsram256w512btop"]
if {[sizeof_collection $sram_macros] != 2} {
    error "Expected 2 linked hdsram256w512btop macros; found [sizeof_collection $sram_macros]."
}
set_dont_touch $sram_macros
puts "Linked 2 hdsram256w512btop macros from $SRAM_DB."

set icg [get_cells -quiet -hierarchical -filter "ref_name == CKLNQD8BWP30P140"]
if {[sizeof_collection $icg] == 0} {
    error "SVT ICG CKLNQD8BWP30P140 was not linked. SVT db must stay in link_library."
}
set_dont_touch $icg
puts "Preserving [sizeof_collection $icg] CKLNQD8BWP30P140 ICG cells."

# 3.2 ns is 312.5 MHz. Same absolute clock constraints as the 3 ns HVT scripts.
# No port input/output delay and no reset false path.
create_clock -name clock -period $CLK_PERIOD [get_ports clock]
# set_false_path -fall_from [get_clocks *]
set_clock_uncertainty -setup 0.125 [all_clocks]
set_clock_uncertainty -hold 0.05 [all_clocks]
set_clock_transition 0.1 [all_clocks]
set_clock_latency 0.2 [all_clocks]

set_max_transition 0.4 [current_design]
set_max_area 0

set_fix_hold [all_clocks]
set_fix_multiple_port_nets -buffer_constants -all

source $RTL_DIR/preserve_csa.tcl
check_csa_structure ./work_sramwrap_3p2ns/csa_pre_compile.txt

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
