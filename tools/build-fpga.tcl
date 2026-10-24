# Run gw_sh from the repository root in an ASCII checkout. No flash operation.
open_project fpga/stage64/v3_hardware_top.gprj
set_option -place_option 3
set_option -route_option 2
run all
