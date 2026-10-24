`timescale 1ns/1ps
module tb_keyboard_note_events;
    reg clk=0,reset_n=0,enable=0,ready=0;
    always #10 clk=~clk;
    reg [11:0] keys=0,held=0;
    reg [1:0] octave=1;
    reg [6:0] velocity=90;
    wire valid,on;
    wire [15:0] id;
    wire [3:0] note;
    wire [1:0] oct;
    wire [6:0] force_value;
    reg [15:0] ids [0:11];
    integer accepted=0;
    reg stalled=0;
    reg [30:0] previous_payload;
    keyboard_note_events dut(.clock_enable(1'b1),.clk(clk),.reset_n(reset_n),
        .enable(enable),.keys(keys),.octave(octave),.velocity(velocity),
        .key_forces(84'd0),.event_ready(ready),.event_valid(valid),.event_on(on),
        .event_id(id),.event_note(note),.event_octave(oct),.event_force(force_value));
    always @(posedge clk)if(reset_n && enable)begin
        if(stalled && {on,id,note,oct,force_value}!==previous_payload)$fatal(1,"payload changed under backpressure");
        stalled=valid && !ready;
        previous_payload={on,id,note,oct,force_value};
        if(valid && ready)begin
            accepted++;
            if(on)begin
                if(held[note])$fatal(1,"duplicate ON");
                held[note]=1;ids[note]=id;
            end else begin
                if(!held[note] || ids[note]!==id)$fatal(1,"wrong note occurrence OFF");
                held[note]=0;
            end
        end
    end else stalled=0;
    task ticks(input integer n);repeat(n)@(negedge clk);endtask
    initial begin
        ticks(4);reset_n=1;enable=1;ticks(3);
        keys=12'h891;wait(valid);ticks(3);
        keys=0;octave=2;velocity=20;ticks(10);ready=1;ticks(50);
        if(held!==0 || accepted!=2)$fatal(1,"stalled ON missing matching OFF");
        keys=12'hfff;ticks(80);if(held!==12'hfff)$fatal(1,"12 note chord lost");
        keys=12'h555;ticks(50);if(held!==12'h555)$fatal(1,"release chord lost");
        enable=0;held=0;ticks(5);enable=1;ticks(40);
        if(held!==0 || valid)$fatal(1,"held keys replayed after owner switch");
        keys=0;ticks(5);keys=12'h555;ticks(60);if(held!==12'h555)$fatal(1,"rearm failed");
        keys=0;ticks(60);if(held!==0)$fatal(1,"stuck chord");
        $display("PASS: stable stalled payload, matched occurrence OFF, 12-key chord, releases, owner cancellation and rearm");$finish;
    end
    initial begin #1000000;$fatal(1,"event bridge timeout");end
endmodule
