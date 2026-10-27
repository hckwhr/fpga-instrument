`timescale 1ns/1ps
// Independent SPI slave: decode commands from pins, drive data on falling SCLK.
module v3_dual_adc_model(
    input wire cs0,cs1,sclk,mosi,
    input wire [159:0] values,
    output reg miso=0
);
    wire selected=!cs0 || !cs1;
    reg [4:0] command=0;
    reg [9:0] conversion=0;
    integer edges=0,transactions=0,expected=0;
    time deselected=0;
    always @(negedge cs0 or negedge cs1)begin
        if(!cs0 && !cs1)$fatal(1,"Both ADCs selected");
        if($time-deselected<1000)$fatal(1,"ADC deselect shorter than 1 us");
        edges=0;command=0;miso=0;
    end
    always @(posedge sclk)if(selected)begin
        edges++;
        if(edges<=5)command={command[3:0],mosi};
        if(edges==5)begin
            if(command[4:3]!==2'b11)$fatal(1,"Invalid ADC command");
            if({!cs1,command[2:0]}!==expected[3:0])$fatal(1,"ADC chip/channel order %d",expected);
            conversion=values[expected*10+:10];
            expected=(expected+1)%16;
        end
    end
    always @(negedge sclk)if(selected)begin
        if(edges>=6 && edges<=15)miso=conversion[15-edges];else miso=0;
    end
    always @(posedge cs0 or posedge cs1)if(cs0 && cs1 && edges!=0)begin
        if(edges!=16)$fatal(1,"ADC transaction length %d",edges);
        transactions++;deselected=$time;edges=0;miso=0;
    end
endmodule
