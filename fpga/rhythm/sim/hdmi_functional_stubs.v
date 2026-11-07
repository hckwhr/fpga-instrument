// Portable integration tests override PLL outputs with testbench clocks.
// These stubs make no PHY claim; run_hdmi_phy.ps1 uses a separate vendor library.
module hdmi_reference_pll(input clkin,init_clk,output clkout0,lock);
    assign clkout0=clkin;
    assign lock=1'b1;
endmodule
module hdmi_pll(input clkin,init_clk,output clkout0,clkout1,clkout2,lock);
    assign clkout0=clkin;
    assign clkout1=clkin;
    assign clkout2=clkin;
    assign lock=1'b1;
endmodule
module OSER10(input D0,D1,D2,D3,D4,D5,D6,D7,D8,D9,PCLK,FCLK,RESET,output reg Q);
    parameter GSREN="FALSE",LSREN="TRUE";
    // Only the parallel interface is observed in portable system tests.
    always @(posedge PCLK or posedge RESET)if(RESET)Q<=0;else Q<=D0;
endmodule
module ELVDS_OBUF(input I,output O,OB);
    assign O=I;
    assign OB=~I;
endmodule
// Same divide/reset behavior as the official GW5A model. PHY tests compile
// the official primitive instead and verify the actual clock period/ratio.
module CLKDIV2(input HCLKIN,RESETN,output reg CLKOUT=0);
    always @(posedge HCLKIN or negedge RESETN)
        if(!RESETN)CLKOUT<=0;else CLKOUT<=~CLKOUT;
endmodule
// Portable integration model only. Official PHY tests use the vendor DHCE.
module DHCE(input CLKIN,CEN,output CLKOUT);
    reg [3:0] enabled=0;
    always @(negedge CLKIN)enabled<={enabled[2:0],!CEN};
    assign CLKOUT=CLKIN && enabled[3];
endmodule
