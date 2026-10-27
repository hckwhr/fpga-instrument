`timescale 1ns/1ps
module tb_performance_controls;
    reg clk=0,reset_n=0,strobe=0,enable=0,frame=0;
    reg [9:0] force_raw=0,x=512,y=512;
    wire [6:0] force_value;
    wire signed [7:0] bend;
    wire [7:0] vibrato;
    wire gate,trigger,ready;
    wire [31:0] increment;
    integer i,errors=0,triggers=0,last_depth=0,last_bend=0,delta,levels=0;
    performance_controls #(.TIMEOUT_SAMPLES(256)) dut(
        .clk(clk),.reset_n(reset_n),.sample_strobe(strobe),.sensor_enable(enable),.frame_valid(frame),
        .force_raw(force_raw),.x_raw(x),.y_raw(y),.force_zero(10'd20),
        .x_center(10'd512),.y_center(10'd512),.force_gain_q12(12'd528),
        .manual_force(7'd96),.manual_vibrato(2'd1),.force_value(force_value),
        .bend(bend),.vibrato_depth(vibrato),.pressure_gate(gate),.pressure_trigger(trigger),.sensor_ready(ready));
    pitch_expression pitch(.clk(clk),.reset_n(reset_n),.sample_strobe(strobe),.enable(1'b1),
        .active(1'b1),.note_start(1'b0),.target_increment(32'd23409859),
        .start_increment(32'd23409859),.start_valid(1'b1),.glide_select(2'd0),
        .vibrato_depth(vibrato),.lfo(8'sd64),.bend(bend),.expressed_increment(increment));
    always #5 clk=~clk;
    task tick;begin @(posedge clk);#1;if(trigger)triggers=triggers+1;end endtask
    task slot;begin strobe=1;tick();strobe=0;repeat(10)tick();end endtask
    task check;input cond;input [8*100-1:0] msg;
        begin if(cond!==1'b1)begin $display("ERROR: %0s",msg);errors=errors+1;end end endtask
    task stream;input integer count;integer n;begin for(n=0;n<count;n=n+1)begin
        frame=(n%12==0);tick();frame=0;slot();
    end end endtask
    initial begin
        repeat(3)tick();reset_n=1;repeat(40)slot();
        check(force_value==96 && bend==0 && vibrato==32 && !gate,"manual fallback incorrect");
        enable=1;stream(200);check(ready && force_value==0 && bend==0 && vibrato==0 && !gate,"zero/center calibration incorrect");
        force_raw=1023;x=1023;y=1023;stream(1000);
        $display("SENSOR full range: force=%0d bend=%0d vibrato=%0d gate=%0d",force_value,bend,vibrato,gate);
        check(force_value==127 && bend==127 && vibrato==128 && gate,"three sensor axes did not reach limits");
        check(triggers==1,"pressure gate retriggered while held");
        check(increment>26000000,"sensor bend not consumed by pitch engine");
        x=0;y=512;stream(1000);check(bend<= -125 && vibrato==0 && increment<21000000,"negative bend / centered vibrato failed");
        force_raw=20;x=512;stream(1000);check(!gate && force_value==0 && bend==0,"release hysteresis/center deadzone failed");
        // The virtual ADC traverses the old depth boundaries, with real one-clock frames.
        last_depth=0;
        for(i=560;i<=1010;i=i+10)begin
            y=i;stream(180);
            check(vibrato>=last_depth,"ADC vibrato depth reversed during increasing travel");
            if(vibrato>last_depth)levels=levels+1;
            last_depth=vibrato;
        end
        check(levels>35,"ADC vibrato still behaves like coarse depth presets");
        x=512;y=512;stream(1000);last_depth=vibrato;last_bend=bend;
        x=1023;y=1023;
        for(i=0;i<600;i=i+1)begin
            frame=(i%12==0);tick();frame=0;slot();
            delta=vibrato-last_depth;check(delta>=0 && delta<=1,"vibrato depth jumped more than one step/sample");
            delta=$signed(bend)-last_bend;check(delta>=0 && delta<=1,"bend jumped more than one step/sample");
            last_depth=vibrato;last_bend=$signed(bend);
        end
        x=512;y=512;stream(1000);
        force_raw=200;stream(200);check(gate && triggers==2,"second pressure onset failed");
        frame=0;repeat(300)slot();check(!ready && !gate && force_value==96 && bend==0,"stale sensor did not fall back safely");
        enable=0;slot();check(!ready && !gate,"sensor disable retained press");
        if(errors)$fatal(1,"performance controls errors=%0d",errors);
        $display("PASS: calibration, three axes, deadzone, smoothing, hysteresis, onset, stale-input fallback and actual pitch bend");
        $finish;
    end
endmodule
