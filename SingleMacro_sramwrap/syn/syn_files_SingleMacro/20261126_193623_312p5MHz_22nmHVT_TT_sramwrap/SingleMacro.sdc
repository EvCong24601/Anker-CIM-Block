###################################################################

# Created by write_sdc on Thu Nov 26 20:28:43 2026

###################################################################
set sdc_version 2.1

set_units -time ns -resistance kOhm -capacitance pF -voltage V -current mA
set_max_transition 0.4 [current_design]
set_max_area 0
create_clock [get_ports clock]  -period 3.2  -waveform {0 1.6}
set_clock_latency 0.2  [get_clocks clock]
set_clock_uncertainty -setup 0.125  [get_clocks clock]
set_clock_uncertainty -hold 0.05  [get_clocks clock]
set_clock_transition -max -rise 0.1 [get_clocks clock]
set_clock_transition -max -fall 0.1 [get_clocks clock]
set_clock_transition -min -rise 0.1 [get_clocks clock]
set_clock_transition -min -fall 0.1 [get_clocks clock]
