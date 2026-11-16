# ZEQ-200-TC in the Caravel user area (user_project_wrapper), PnR and signoff.
# Adapted from caravel_user_project's base_user_project_wrapper.sdc: the
# chip is clocked by user_clock2 (Caravel's latency/transition figures for
# the user clock), and every functional I/O is asynchronous to it.

create_clock [get_ports user_clock2] -name clk -period $::env(CLOCK_PERIOD)
set_propagated_clock [all_clocks]
set_clock_uncertainty $::env(SYNTH_CLOCK_UNCERTAINTY) [get_clocks {clk}]
set_clock_transition $::env(SYNTH_CLOCK_TRANSITION) [get_clocks {clk}]
set_max_transition $::env(MAX_TRANSITION_CONSTRAINT) [current_design]
set_max_fanout $::env(MAX_FANOUT_CONSTRAINT) [current_design]
set_timing_derate -early [expr {1 - $::env(SYNTH_TIMING_DERATE)}]
set_timing_derate -late  [expr {1 + $::env(SYNTH_TIMING_DERATE)}]

# user_clock2 as delivered by Caravel (base_user_project_wrapper.sdc:
# usr_clk_min/max_latency, usr_clk_tran)
set_clock_latency -source -max 4.57 [get_clocks {clk}]
set_clock_latency -source -min 4.11 [get_clocks {clk}]
set_input_transition 0.13 [get_ports user_clock2]

# Functional I/O is asynchronous by design:
#  - io_in: RSTN (async assert, synchronized release), CI/RI/BI (2-flop
#    synchronizers in zeq_uart/zeq_link), ADDR straps (static)
#  - io_out/io_oeb: CO/RO/BO are registered UART lines sampled by the next
#    chip's own clock; TEMP is open drain
#  - la_data_in[7:0]: the thermal code written by the management core,
#    quasi-static (compared into a registered over-temperature flag)
#  - Wishbone and the rest of the logic analyzer are unused (tied off)
set_false_path -from [get_ports {io_in[*]}]
set_false_path -to   [get_ports {io_out[*]}]
set_false_path -to   [get_ports {io_oeb[*]}]
set_false_path -from [get_ports {la_data_in[*]}]
set_false_path -from [get_ports {la_oenb[*]}]
set_false_path -to   [get_ports {la_data_out[*]}]
set_false_path -to   [get_ports {user_irq[*]}]
set_false_path -from [get_ports {wb_clk_i wb_rst_i wbs_stb_i wbs_cyc_i wbs_we_i}]
set_false_path -from [get_ports {wbs_sel_i[*] wbs_dat_i[*] wbs_adr_i[*]}]
set_false_path -to   [get_ports {wbs_ack_o wbs_dat_o[*]}]

# electrical: pad-side transitions and loads (Caravel figures)
set_input_transition 0.5 [get_ports {io_in[*]}]
set_input_transition 0.5 [get_ports {la_data_in[*] la_oenb[*]}]
set_load 0.19 [all_outputs]
