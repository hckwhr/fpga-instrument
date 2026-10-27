if {[llength $argv] != 1} {
    puts stderr "usage: gw_sh pnr_only.tcl <v3_hdmi_top.gprj>"
    exit 2
}
open_project [file normalize [lindex $argv 0]]
set_option -top_module v3_hdmi_top
set_option -place_option 3
set_option -route_option 2
run pnr
run close
