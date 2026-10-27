open_project [lindex $argv 0]
if {[catch {read_ipc {E:/Gowin/workspace/hdmi_stage41_20261011/rtl/hdmi_pll/hdmi_pll.ipc}} result options]} {
    puts "READ ERROR: $result"
    puts "OPTIONS: $options"
} else {
    puts "READ RESULT: $result"
    puts "IPS: [get_ips]"
    report_property [get_ips hdmi_pll]
}
run close
