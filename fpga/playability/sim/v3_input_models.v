`timescale 1ns/1ps
// Electrical models: no internal DUT forces or direct frame injection.
module v3_key_model(input wire load_n,shift_clk,input wire [15:0] pressed,output wire serial_data);
    reg [15:0] chain=16'hffff;
    always @(negedge load_n or posedge shift_clk)
        if(!load_n)chain<=~pressed;else chain<={1'b1,chain[15:1]};
    assign serial_data=load_n ? chain[0] : ~pressed[0];
endmodule
module v3_adc_model(input wire cs_n,sclk,mosi,input wire [9:0] pressure,x,y,output reg miso=0);
    integer edges=0,transactions=0;
    reg [4:0] command=0;
    reg [9:0] code=0;
    always @(negedge cs_n)begin edges=0;command=0;miso=0;end
    always @(posedge sclk)begin
        if(cs_n!==0)$fatal(1,"SPI clock while deselected");
        if(edges<5)command={command[3:0],mosi};
        edges=edges+1;
        if(edges==5)begin
            if(command[4:3]!==2'b11 || command[2:0]>2)$fatal(1,"Invalid ADC command %b",command);
            case(command[2:0])0:code=pressure;1:code=x;2:code=y;endcase
            transactions=transactions+1;
        end
    end
    always @(negedge sclk)if(edges>=6 && edges<=15)miso=code[15-edges];else miso=0;
endmodule
