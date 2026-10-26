if {[llength $argv] != 1} { error "usage: generate_hdmi_plls.tcl project.gprj" }
set project_file [file normalize [lindex $argv 0]]
open_project $project_file
foreach {name freq idiv mdiv frac odiv div1} {
    hdmi_reference_pll 50.000 1 20 2 20 0
    hdmi_pll 50.625 1 22 0 3 15
} {
    create_ipc -name clock_plladv -module_name $name -language Verilog -file_name $name -dir [file join [file dirname $project_file] rtl] -force
    set ip [get_ips $name]
    set_property -dict {CONFIG.General_Mode false CONFIG.Adcanced_Mode true} $ip
    set_property -dict [list CONFIG.CLKIN_FREQ $freq] $ip
    set_property -dict [list CONFIG.CLKIN_DIV_DYN false CONFIG.CLKIN_DIV_STATIC true CONFIG.CLKIN_DIV_VALUE $idiv] $ip
    set_property -dict {CONFIG.CLKFB_DIV_DYN false CONFIG.CLKFB_DIV_STATIC true CONFIG.CLKFB_DIV_STATIC_VALUE 1} $ip
    set_property -dict [list CONFIG.CLKFBOUT_DIV_DYN false CONFIG.CLKFBOUT_DIV_STATIC true CONFIG.CLKFBOUT_DIV_STATIC_INT_VALUE $mdiv CONFIG.CLKFBOUT_DIV_STATIC_FRAC_VALUE $frac] $ip
    set_property -dict [list CONFIG.CLKOUT0_DIV_DYN false CONFIG.CLKOUT0_DIV_STATIC true CONFIG.CLKOUT0_DIV_STATIC_INT_VALUE $odiv CONFIG.CLKOUT0_DIV_STATIC_FRAC_VALUE 0] $ip
    set_property -dict [list CONFIG.CLKOUT1_EN [expr {$div1 != 0 ? "true" : "false"}] CONFIG.LOCK_EN true] $ip
    if {$div1 != 0} {
        set_property -dict [list CONFIG.CLKOUT1_DIV_DYN false CONFIG.CLKOUT1_DIV_STATIC true CONFIG.CLKOUT1_DIV_STATIC_VALUE $div1] $ip
        # Direct PLL global-clock output: CLKDIV2 is a high-speed IO clock
        # resource and cannot drive ordinary fabric FFs (UG306 section 4.2).
        set_property -dict {CONFIG.CLKOUT2_EN true CONFIG.CLKOUT2_DIV_DYN false CONFIG.CLKOUT2_DIV_STATIC true CONFIG.CLKOUT2_DIV_STATIC_VALUE 30} $ip
    }
    report_property $ip
    generate_target $ip
}
run close
