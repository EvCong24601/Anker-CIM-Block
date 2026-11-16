# Source AFTER elaborate/link and BEFORE compile/compile_ultra.
# The preserved core is only MacroW8MainTreeCSA. The CPA in MacroW8MainTree
# stays RTL and must remain free to optimize.
set csa_cells [get_cells -hierarchical -filter {ref_name =~ MacroW8MainTreeCSA*}]
set csa_count [sizeof_collection $csa_cells]
if {$csa_count == 0} {
    error "No MacroW8MainTreeCSA found. Use rtl_W8main_handcut sources."
}
if {[get_object_name [current_design]] == "SingleMacro" && $csa_count != 4} {
    error "SingleMacro must contain exactly four CSA cores; found $csa_count."
}
set_ungroup $csa_cells false
set_boundary_optimization $csa_cells false
set_dont_touch $csa_cells true
puts "Preserving $csa_count MacroW8MainTreeCSA instances; the CPA remains optimizable."
