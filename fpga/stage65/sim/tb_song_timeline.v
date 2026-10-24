`timescale 1ns/1ps
module tb_song_timeline;
    reg clk=0, reset_n=0, strobe=0, enable=0, stop=0, replay=0, ready=1;
    reg [63:0] rom[0:31];
    reg [63:0] data;
    reg [9:0] length=6;
    wire [8:0] address;
    wire valid,on,flush,done,fault,melody;
    wire [15:0] id;
    integer i,accepted=0,ons=0,offs=0,cycles=0,stall=0;
    reg [63:0] held;
    reg was_stalled=0;
    song_timeline dut(.clk(clk),.reset_n(reset_n),.sample_strobe(strobe),.enable(enable),
        .stop_pressed(stop),.replay_pressed(replay),.remote_start(1'b0),.remote_stop(1'b0),
        .tempo_select(2'd3),.score_index(address),.score_data(data),.score_length(length),
        .score_end_tick(24'd8),.note_index(),.done(done),.deadline_fault(fault),
        .event_flush(flush),.event_valid(valid),.event_on(on),.event_id(id),
        .event_note(),.event_octave(),.event_force(),.event_melody(melody),.event_ready(ready));
    always #5 clk=~clk;
    always @(posedge clk) data<=rom[address[4:0]];
    always @(posedge clk) begin
        cycles=cycles+1;
        if(was_stalled && !flush && dut.current_event!==held)$fatal(1,"stalled payload changed");
        was_stalled=valid && !ready && !flush; held=dut.current_event;
        if(valid && ready) begin
            accepted=accepted+1;
            if(on)ons=ons+1;else offs=offs+1;
            if(dut.slot_age>990)$fatal(1,"late event");
        end
    end
    function [63:0] record;
        input [23:0] t;input is_on;input[15:0] note_id;input last;
        begin record={t,is_on,note_id,4'd0,2'd1,7'd80,last,1'b0,8'd0};end
    endfunction
    task tick;begin @(posedge clk);#1;end endtask
    task slot;input integer clocks;begin strobe=1;tick();strobe=0;repeat(clocks-1)tick();end endtask
    task start;begin replay=1;tick();replay=0;repeat(8)tick();end endtask
    initial begin
        // Two overlapping instances of the same pitch, released independently;
        // third note after a rest. ON IDs must survive unchanged through ROM.
        rom[0]=record(0,1,10,0);rom[1]=record(0,1,11,1);
        rom[2]=record(2,0,10,1);rom[3]=record(4,0,11,1);
        rom[4]=record(6,1,12,1);rom[5]=record(7,0,12,1);
        repeat(3)tick();reset_n=1;enable=1;repeat(20)tick();
        repeat(7199)slot(12);
        // bounded backpressure holds the first event, never score time.
        ready=0;slot(90);ready=1;repeat(934)tick();
        repeat(1700)slot(1024);
        if(!done || fault || accepted!=6 || ons!=3 || offs!=3)$fatal(1,"timeline incomplete");
        start();repeat(7199)slot(12);ready=0;slot(1024);ready=1;repeat(5)tick();
        if(!fault || !done || !flush || valid)$fatal(1,"deadline must cancel");
        start();if(fault)$fatal(1,"replay failed to clear fault");
        // Stop in prefetch and in SEND; no old events may leak on restart.
        stop=1;tick();stop=0;repeat(30)tick();
        if(!done || valid)$fatal(1,"stop prefetch");
        start();repeat(7199)slot(12);strobe=1;tick();strobe=0;ready=0;tick();
        stop=1;tick();stop=0;ready=1;repeat(30)tick();
        if(!done || valid || fault)$fatal(1,"stop SEND");
        // Corrupt ROMs must fail before sending: inconsistent timestamps,
        // missing terminator, invalid note, oversized and unordered groups.
        rom[1]=record(1,1,11,1);start();repeat(20)tick();if(!fault)$fatal(1,"mixed group timestamp");
        rom[1]=record(0,1,11,0);length=2;start();repeat(20)tick();if(!fault)$fatal(1,"missing last");
        rom[0]=record(0,1,10,1);rom[0][22:19]=15;start();repeat(20)tick();if(!fault)$fatal(1,"invalid pitch");
        length=17;for(i=0;i<17;i=i+1)rom[i]=record(0,1,i,i==16);
        start();repeat(60)tick();if(!fault)$fatal(1,"oversized group");
        length=2;rom[0]=record(0,1,10,1);rom[1]=record(0,0,10,1);
        start();repeat(7199)slot(12);slot(1024);if(!fault)$fatal(1,"unordered group");
        enable=0;repeat(4)tick();if(fault || valid)$fatal(1,"exit clear");
        $display("PASS: synchronous ROM prefetch, independent IDs/rests, stable stall, deadline cancel, stop/replay, malformed and oversized groups");
        $finish;
    end
    initial begin #40000000;$fatal(1,"timeline timeout");end
endmodule
