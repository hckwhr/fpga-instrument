`timescale 1ns/1ps
module tb_mcp3008_scanner;
    reg clk=0,reset_n=0;
    always #10 clk=~clk;
    wire sclk,mosi,cs,miso,valid;
    wire [9:0] f,x,y;
    reg [9:0] fp=37,xp=511,yp=982;
    reg [29:0] last_frame=0;
    integer frame_count=0,expected_channel=0;
    time deselected;
    mcp3008_scanner #(.CLK_DIV_CYCLES(5),.FRAME_IDLE_CYCLES(50)) dut(
        .clk(clk),.reset_n(reset_n),.adc_miso(miso),.adc_sclk(sclk),.adc_mosi(mosi),.adc_cs_n(cs),
        .force_raw(f),.x_raw(x),.y_raw(y),.frame_valid(valid));
    v3_adc_model model(cs,sclk,mosi,fp,xp,yp,miso);
    always @(posedge cs)deselected=$time;
    always @(negedge cs)if(reset_n && $time-deselected<1000)$fatal(1,"ADC CS high gap too short");
    always @(posedge sclk)if(model.edges==5)begin
        // Separate delta avoids a race with the model's command capture.
        #1;
    end
    always @(negedge sclk)if(reset_n && model.edges==5)begin
        if(model.command[2:0]!=expected_channel)$fatal(1,"channel order");
        expected_channel=(expected_channel+1)%3;
    end
    always @(negedge clk)if(reset_n)begin
        if(valid)begin
            if({f,x,y}!=={fp,xp,yp})$fatal(1,"mixed or incorrect ADC frame %d %d %d",f,x,y);
            frame_count++;last_frame={f,x,y};
        end else if({f,x,y}!==last_frame)$fatal(1,"partial ADC frame published");
    end
    initial begin
        repeat(5)@(negedge clk);reset_n=1;
        wait(frame_count==3);@(negedge clk);fp=901;xp=13;yp=672;
        wait(frame_count==6);
        @(negedge cs);repeat(20)@(negedge clk);reset_n=0;
        repeat(3)@(negedge clk);last_frame=0;expected_channel=0;reset_n=1;
        wait(frame_count==7);
        $display("PASS: CH0/1/2 commands, 10-bit values, atomic frames, CS gap, mid-conversion reset");$finish;
    end
    initial begin #5000000;$fatal(1,"ADC scanner timeout");end
endmodule
