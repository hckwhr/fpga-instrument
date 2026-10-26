`timescale 1ns/1ps
`default_nettype none
module tb_song_player;
    reg clk=0, reset_n=0, sample_strobe=0, enable=0, stop_pressed=0, replay_pressed=0;
    wire gate, trigger, done;
    wire [3:0] note;
    wire [1:0] octave;
    wire [6:0] force_level;
    wire [7:0] note_index;
    wire event_valid, event_on, event_flush, receiver_ready;
    reg allow_ready=1;
    wire event_ready=receiver_ready && allow_ready;
    wire [15:0] event_id;
    wire [3:0] event_note;
    wire [1:0] event_octave;
    wire [6:0] event_force;
    integer i, starts, elapsed, due, last_start;
    integer on_count=0, off_count=0;
    reg check_score=1, awaiting_off=0;
    reg [15:0] last_id=0, stalled_id;
    reg [3:0] stalled_note;
    reg [3:0] expected [0:41];
    always #5 clk=~clk;
    wire [7:0] score_index, score_length;
    wire [3:0] score_note;
    wire [1:0] score_octave;
    wire [6:0] score_force;
    wire [11:0] duration_ticks;
    wire [23:0] score_duration = duration_ticks/12'd3;
    song_score_twinkle score(
        .index(score_index),.length(score_length),.note(score_note),
        .octave(score_octave),.force_level(score_force),.duration_ticks(duration_ticks),.gate_ticks());
    song_player #(.QUARTER_SAMPLES(32)) dut(
        .score_index(score_index),.score_length(8'd42),.score_note(score_note),
        .score_octave(score_octave),.score_force(score_force),.score_duration(score_duration),.score_gate(score_duration-24'd8),
        .clk(clk),.reset_n(reset_n),.sample_strobe(sample_strobe),.enable(enable),
        .stop_pressed(stop_pressed),.replay_pressed(replay_pressed),.done(done),
        .remote_start(1'b0),.remote_stop(1'b0),
        .note_index(note_index),.event_ready(event_ready),.event_flush(event_flush),
        .event_valid(event_valid),.event_on(event_on),
        .event_id(event_id),.event_note(event_note),
        .event_octave(event_octave),.event_force(event_force));
    note_event_voice receiver(
        .clk(clk),.reset_n(reset_n),.sample_strobe(sample_strobe),.flush(event_flush),
        .event_valid(event_valid && allow_ready),.event_ready(receiver_ready),
        .event_on(event_on),.event_id(event_id),.event_note(event_note),
        .event_octave(event_octave),.event_force(event_force),
        .gate(gate),.trigger(trigger),.note(note),.octave(octave),.force_level(force_level));
    always @(posedge clk) if(reset_n && check_score && event_valid && event_ready && !event_flush) begin
        if(event_on) begin
            if(awaiting_off || on_count>=42 || event_note!==expected[on_count] ||
               event_id!==on_count || event_octave!=1 || event_force!=96)
                $fatal(1,"ON sequence/identity mismatch %0d",on_count);
            last_id=event_id; on_count=on_count+1; awaiting_off=1;
        end else begin
            if(!awaiting_off || event_id!==last_id) $fatal(1,"OFF order/identity mismatch");
            off_count=off_count+1; awaiting_off=0;
        end
    end
    task slot; begin
        @(negedge clk); sample_strobe=1;
        @(negedge clk); sample_strobe=0;
        repeat(4) @(negedge clk);
    end endtask
    initial begin
        // Independent conventional score, pitch classes in C major.
        {expected[0],expected[1],expected[2],expected[3],expected[4],expected[5],expected[6]}=28'h0077997;
        {expected[7],expected[8],expected[9],expected[10],expected[11],expected[12],expected[13]}=28'h5544220;
        {expected[14],expected[15],expected[16],expected[17],expected[18],expected[19],expected[20]}=28'h7755442;
        {expected[21],expected[22],expected[23],expected[24],expected[25],expected[26],expected[27]}=28'h7755442;
        {expected[28],expected[29],expected[30],expected[31],expected[32],expected[33],expected[34]}=28'h0077997;
        {expected[35],expected[36],expected[37],expected[38],expected[39],expected[40],expected[41]}=28'h5544220;
        repeat(3) @(negedge clk); reset_n=1; enable=1;
        repeat(3) @(negedge clk); starts=0; due=7; last_start=0;
        for(elapsed=0;elapsed<1560;elapsed=elapsed+1) begin
            slot();
            if(trigger) begin
                if(starts>=42) $fatal(1,"song restarted after final cadence");
                if(elapsed!=due || note!==expected[starts] || note_index!==starts || !gate || octave!=1 || force_level!=96)
                    $fatal(1,"score mismatch at event %0d sample %0d due %0d pitch %0d",starts,elapsed,due,note);
                due=due+((starts%7==6)?64:32);
                last_start=elapsed; starts=starts+1;
            end
            if(starts>0 && !done && elapsed>=due-8 && gate)
                $fatal(1,"missing articulation/release gap");
        end
        if(starts!=42 || !done || gate || trigger || due!=1543) $fatal(1,"full 48-beat song did not finish");
        if(on_count!=42 || off_count!=42 || awaiting_off) $fatal(1,"song did not send 42 ON/OFF pairs");
        check_score=0;
        // Replay must start from C, once; a held replay key must not retrigger.
        replay_pressed=1; repeat(20) slot();
        if(note_index!=0 || note!=0 || !gate || done) $fatal(1,"held replay restarted or failed");
        replay_pressed=0; slot(); stop_pressed=1; slot();
        if(gate || trigger || !done) $fatal(1,"stop left a held note");
        repeat(80) slot(); if(gate || !done) $fatal(1,"stopped song advanced");
        stop_pressed=0; enable=0; slot();
        if(gate || trigger || done || note_index!=0) $fatal(1,"disable failed");
        enable=1; repeat(12) slot();
        if(note!=0 || !gate || done) $fatal(1,"reentry failed");
        repeat(64) slot();
        if(note_index!=2 || note!=7 || !gate) $fatal(1,"not at G before replay");
        replay_pressed=1; slot(); replay_pressed=0; repeat(12) slot();
        if(note_index!=0 || note!=0 || !gate) $fatal(1,"replay from G did not restart at C");
        // Backpressure across many musical ticks must retain a single event.
        allow_ready=0; replay_pressed=1; slot(); replay_pressed=0; repeat(12) slot();
        if(!event_valid || !event_on || gate) $fatal(1,"missing stalled first ON");
        stalled_id=event_id; stalled_note=event_note;
        repeat(64) begin
            slot();
            if(!event_valid || !event_on || event_id!==stalled_id || event_note!==stalled_note ||
               event_octave!=1 || event_force!=96 || note_index!=0)
                $fatal(1,"mailbox overwritten while stalled");
        end
        allow_ready=1; slot();
        if(!gate || event_valid) $fatal(1,"stalled ON was lost");
        // Stall the matching OFF, then consume it exactly once.
        allow_ready=0; repeat(24) slot();
        if(!event_valid || event_on || event_id!==stalled_id || !gate) $fatal(1,"missing stalled OFF");
        repeat(64) slot();
        if(!event_valid || event_on || event_id!==stalled_id || note_index!=0) $fatal(1,"OFF overwritten");
        allow_ready=1; slot(); if(gate || event_valid) $fatal(1,"OFF not applied");
        // Stop/replay/disable cancel a queued ON instead of replaying stale data.
        allow_ready=0; replay_pressed=1; slot(); replay_pressed=0; repeat(12) slot();
        stalled_id=event_id; stop_pressed=1; slot();
        if(event_valid || gate || !done) $fatal(1,"stop did not flush mailbox");
        stop_pressed=0; replay_pressed=1; slot(); replay_pressed=0; repeat(12) slot();
        if(!event_valid || event_id===stalled_id) $fatal(1,"restart reused cancelled identity");
        stalled_id=event_id; replay_pressed=1; slot();
        if(event_valid || gate) $fatal(1,"replay did not flush mailbox");
        replay_pressed=0; repeat(12) slot();
        if(!event_valid || event_id===stalled_id) $fatal(1,"replay reused identity");
        enable=0; slot(); allow_ready=1; repeat(12) slot();
        if(event_valid || gate || trigger || done) $fatal(1,"disable leaked queued note");
        $display("PASS: 42 ON/OFF pairs, exact 48 beats, repeated-note IDs, stall retention, stop/replay/disable cancellation");
        $finish;
    end
    initial begin #1000000; $fatal(1,"song timeout"); end
endmodule
`default_nettype wire
