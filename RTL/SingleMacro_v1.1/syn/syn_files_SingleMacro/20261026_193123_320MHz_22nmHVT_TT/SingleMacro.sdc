###################################################################

# Created by write_sdc on Mon Oct 26 19:56:34 2026

###################################################################
set sdc_version 2.1

set_units -time ns -resistance kOhm -capacitance pF -voltage V -current mA
set_max_transition 0.4 [current_design]
set_max_area 0
create_clock [get_ports clock]  -period 3.125  -waveform {0 1.5625}
set_clock_latency 0.2  [get_clocks clock]
set_clock_uncertainty -setup 0.125  [get_clocks clock]
set_clock_uncertainty -hold 0.05  [get_clocks clock]
set_clock_transition -max -rise 0.1 [get_clocks clock]
set_clock_transition -max -fall 0.1 [get_clocks clock]
set_clock_transition -min -rise 0.1 [get_clocks clock]
set_clock_transition -min -fall 0.1 [get_clocks clock]
set_false_path  -fall_from [get_clocks clock]
