# Run gw_sh from the repository root in an ASCII checkout. No flash operation.
open_project fpga/current/v3_hdmi_top.gprj
set_option -top_module v3_hdmi_top
set_option -place_option 3
set_option -route_option 2
# Stop after synthesis. Audit/compress constraints against this fresh netlist
# as described in docs/BUILD.md before separately invoking run pnr.
run syn
