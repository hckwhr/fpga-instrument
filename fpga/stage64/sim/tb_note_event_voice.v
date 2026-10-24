`timescale 1ns/1ps
`default_nettype none
module tb_note_event_voice;
    reg clk=0, reset_n=0, sample_strobe=0, flush=0;
    reg event_valid=0, event_on=0;
    reg [15:0] event_id=0;
    reg [3:0] event_note=0;
    reg [1:0] event_octave=1;
    reg [6:0] event_force=96;
    wire event_ready, gate, trigger;
    wire [3:0] note;
    wire [1:0] octave;
    wire [6:0] force_level;
    always #5 clk=~clk;
    note_event_voice dut(.clk(clk),.reset_n(reset_n),.sample_strobe(sample_strobe),.flush(flush),
        .event_valid(event_valid),.event_ready(event_ready),.event_on(event_on),.event_id(event_id),
        .event_note(event_note),.event_octave(event_octave),.event_force(event_force),
        .gate(gate),.trigger(trigger),.note(note),.octave(octave),.force_level(force_level));
    task boundary; begin
        @(negedge clk); sample_strobe=1;
        #1; if(event_ready) $fatal(1,"accepted on sample boundary");
        @(negedge clk); sample_strobe=0;
    end endtask
    task send; input on; input [15:0] id; begin
        boundary(); event_valid=1; event_on=on; event_id=id;
        @(negedge clk); event_valid=0;
        if(event_ready) $fatal(1,"more than one acceptance in sample slot");
    end endtask
    initial begin
        repeat(3) @(negedge clk); reset_n=1;
        send(1,16'hffff);
        if(!gate || !trigger || note!=0 || octave!=1 || force_level!=96) $fatal(1,"ON not applied");
        // Queued next ON must wait until the next DDS sampling opportunity.
        event_valid=1; event_id=0; event_force=72;
        repeat(5) @(negedge clk);
        if(force_level!=96 || !trigger) $fatal(1,"pending ON overwrote unsampled ON");
        boundary(); @(negedge clk); event_valid=0;
        if(!gate || !trigger || force_level!=72) $fatal(1,"repeated pitch not retriggered");
        send(0,16'hffff);
        if(!gate || trigger) $fatal(1,"stale OFF killed newer same-pitch note");
        send(0,16'd0); if(gate) $fatal(1,"matching OFF ignored");
        // Invalid notes/octaves/zero force must not touch active voice state.
        event_note=7; event_force=96; send(1,16'd1);
        event_note=12; send(1,16'd2); if(note!=7 || !gate || trigger) $fatal(1,"invalid pitch accepted");
        event_note=0; event_octave=3; send(1,16'd3); if(note!=7 || trigger) $fatal(1,"invalid octave accepted");
        event_octave=1; event_force=0; send(1,16'd4); if(note!=7 || trigger) $fatal(1,"zero force accepted");
        send(0,16'd1); if(gate) $fatal(1,"invalid ON changed identity");
        event_force=96; event_note=5; send(1,16'd5);
        // Flush wins even if a new valid ON is presented concurrently.
        flush=1; event_valid=1; event_id=6;
        @(negedge clk);
        if(gate || trigger || event_ready || note!=5) $fatal(1,"flush priority/pitch retention failed");
        event_valid=0; flush=0; boundary();
        if(gate || trigger) $fatal(1,"cancelled note resurrected");
        reset_n=0; @(negedge clk);
        if(gate || trigger || note!=0) $fatal(1,"reset unsafe");
        $display("PASS: identity-matched OFF, repeated pitch, sample-slot backpressure, validation, flush and reset");
        $finish;
    end
    initial begin #10000; $fatal(1,"event bridge timeout"); end
endmodule
`default_nettype wire
