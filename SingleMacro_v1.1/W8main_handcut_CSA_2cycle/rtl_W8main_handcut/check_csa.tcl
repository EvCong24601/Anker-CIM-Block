# Source once, then call after preservation and again after compile_ultra.
# This is a structural guard for the extracted CSA, not an equivalence proof
# of the synthesized CPA.
proc check_csa_structure {report_path} {
    set cores [get_cells -hierarchical -filter {ref_name =~ MacroW8MainTreeCSA*}]
    if {[sizeof_collection $cores] != 4} {
        error "Expected 4 MacroW8MainTreeCSA cores; found [sizeof_collection $cores]."
    }
    set expected {
        FA1D1BWP30P140HVT 558
        HA1D1BWP30P140HVT 5
    }
    set leaves [get_cells -hierarchical -filter {is_hierarchical == false}]
    dict for {ref count} $expected {
        if {[sizeof_collection [get_lib_cells -quiet */$ref]] == 0} {
            error "Unresolved PDK cell type $ref"
        }
    }
    set report "CSA preservation: 4 cores, 563 cells per core\n"
    foreach_in_collection core $cores {
        set core_name [get_object_name $core]
        if {![get_attribute $core dont_touch]} {
            error "CSA core is not dont_touch: $core_name"
        }
        set counts [dict create]
        set total 0
        foreach_in_collection leaf $leaves {
            if {[string first "${core_name}/" [get_object_name $leaf]] != 0} { continue }
            set ref [get_attribute $leaf ref_name]
            if {![dict exists $expected $ref]} {
                error "Unexpected cell type $ref in $core_name"
            }
            dict incr counts $ref
            incr total
        }
        if {$total != 563} { error "$core_name contains $total cells, expected 563." }
        dict for {ref count} $expected {
            if {![dict exists $counts $ref] || [dict get $counts $ref] != $count} {
                error "Wrong cell count for $ref in $core_name; expected $count."
            }
        }
        append report "$core_name: PASS ($total cells, dont_touch=true)\n"
        dict for {ref count} $expected { append report "  $ref $count\n" }
    }
    set stream [open $report_path w]
    puts $stream $report
    close $stream
    puts "PASS CSA preservation: 4 x 563 cells; report $report_path"
}
