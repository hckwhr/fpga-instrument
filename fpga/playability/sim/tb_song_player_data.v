`timescale 1ns/1ps
`default_nettype none
// An independent three-row score proves the scheduler does not contain
// Twinkle's first pitch, row count, duration, octave or velocity constants.
module tb_song_player_data;
    reg clk=0, reset_n=0, strobe=0, enable=0, replay=0;
    reg [7:0] length=3;
    wire [7:0] index, playing_index;
    reg [3:0] notes[0:2];
    reg [1:0] octaves[0:2];
    reg [6:0] forces[0:2];
    reg [23:0] durations[0:2];
    wire valid, on, flush, done;
    wire [15:0] id;
    wire [3:0] note;
    wire [1:0] octave;
    wire [6:0] force_level;
    integer ons=0, offs=0, i, count_before, tick_index;
    reg [15:0] active_id;
    reg checking=1;
    always #5 clk=~clk;
    song_player #(.QUARTER_SAMPLES(32)) dut(
        .clk(clk),.reset_n(reset_n),.sample_strobe(strobe),.enable(enable),
        .stop_pressed(1'b0),.replay_pressed(replay),.remote_start(1'b0),.remote_stop(1'b0),
        .score_index(index),.score_length(length),
        .score_note(index<3 ? notes[index] : 4'd0),
        .score_octave(index<3 ? octaves[index] : 2'd0),
        .score_force(index<3 ? forces[index] : 7'd0),
        .score_duration(index<3 ? durations[index] : 24'd0),
        .score_gate(index<3 ? durations[index]-24'd8 : 24'd0),
        .note_index(playing_index),.done(done),.event_ready(1'b1),
        .event_flush(flush),.event_valid(valid),.event_on(on),.event_id(id),
        .event_note(note),.event_octave(octave),.event_force(force_level));
    always @(posedge clk) if(reset_n && valid && !flush) begin
        if(on) begin
            if(checking) begin
                if(ons>=3) $fatal(1,"ignored external length");
                if(note!==notes[ons] || octave!==octaves[ons] || force_level!==forces[ons])
                    $fatal(1,"external row fields mismatch %0d",ons);
                if(tick_index!=((ons==0)?7:(ons==1)?27:55)) $fatal(1,"external duration ignored");
            end
            active_id=id; ons=ons+1;
        end else begin
            if(id!==active_id) $fatal(1,"data score OFF mismatch");
            if(checking && tick_index!=((offs==0)?19:(offs==1)?47:83)) $fatal(1,"release timing");
            offs=offs+1;
        end
    end
    task slot; begin
        @(negedge clk); strobe=1;
        @(negedge clk); strobe=0; repeat(4) @(negedge clk);
    end endtask
    task restart; begin
        replay=1; slot(); replay=0;
    end endtask
    initial begin
        notes[0]=4; notes[1]=11; notes[2]=2;
        octaves[0]=0; octaves[1]=2; octaves[2]=1;
        forces[0]=32; forces[1]=127; forces[2]=72;
        durations[0]=20; durations[1]=28; durations[2]=36;
        repeat(3) @(negedge clk); reset_n=1; enable=1;
        repeat(3) @(negedge clk);
        for(tick_index=0;tick_index<100;tick_index=tick_index+1) begin
            slot();
            if(done !== (tick_index>=91)) $fatal(1,"incorrect external score end %0d",tick_index);
        end
        if(ons!=3 || offs!=3) $fatal(1,"missing data-driven events");
        checking=0;
        // Restart at every row, including the long final note.
        for(i=0;i<3;i=i+1) begin
            restart(); repeat((i==0)?10:(i==1)?30:58) slot();
            if(playing_index!=i) $fatal(1,"replay precondition");
            restart(); repeat(10) slot();
            if(note!=4 || octave!=0 || force_level!=32 || playing_index!=0 || done)
                $fatal(1,"replay did not refetch row zero");
        end
        // Empty and malformed first rows terminate without any ON.
        enable=0; slot(); count_before=ons; length=0; enable=1; repeat(20) slot();
        if(!done || ons!=count_before) $fatal(1,"empty score played");
        enable=0; slot(); length=3; durations[0]=8; enable=1; repeat(20) slot();
        if(!done || ons!=count_before) $fatal(1,"unsafe short duration played");
        enable=0; slot(); durations[0]=20; notes[0]=12; enable=1; repeat(20) slot();
        if(!done || ons!=count_before) $fatal(1,"invalid pitch played");
        // A bad following row stops only after the preceding note's OFF.
        enable=0; slot(); notes[0]=4; durations[1]=0; count_before=offs;
        enable=1; repeat(40) slot();
        if(!done || offs!=count_before+1) $fatal(1,"malformed later row left a note held");
        $display("PASS: external 3-row score, variable pitches/octaves/forces/durations, replay at every row, empty/malformed score");
        $finish;
    end
    initial begin #100000; $fatal(1,"data score timeout"); end
endmodule
`default_nettype wire
