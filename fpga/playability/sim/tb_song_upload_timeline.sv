`timescale 1ns/1ps
// Functional interface integration, SAME clock only. No CDC/hardware claim.
module tb_song_upload_timeline;
    reg clk=0;
    always #10 clk=~clk;
    reg reset_n=0, command_valid=0, response_ready=0;
    reg [1:0] command=0;
    reg [8:0] request_index=0;
    reg [63:0] request_word=0;
    wire command_ready,response_valid,score_valid,published,staging,expired;
    wire [3:0] response_code;
    wire [9:0] response_count,score_length;
    wire [23:0] score_end_tick;
    wire [7:0] score_melody_count;
    wire [15:0] score_crc;
    wire [63:0] score_data;
    wire [8:0] score_index;
    reg enable=0, remote_start=0, remote_stop=0;
    wire done, deadline_fault,event_flush,event_valid,event_on,event_melody;
    wire [15:0] event_id;
    wire [3:0] event_note;
    wire [1:0] event_octave;
    wire [6:0] event_force;
    wire [7:0] note_index;
    reg [9:0] sample_div=0;
    wire sample_strobe=sample_div==10'd1023;
    // Introduce downstream stalls while preserving the 1000-cycle slot budget.
    wire event_ready=sample_div[3:0]==4'd12;
    integer samples=0, received=0, first_sample=0, index, timeout;
    reg [63:0] expected[0:3];
    always @(posedge clk) begin
        if(!reset_n) begin sample_div<=0; samples<=0; end
        else begin sample_div<=sample_div+1'b1; if(sample_strobe) samples<=samples+1; end
        if(reset_n && event_valid && event_ready) begin
            if(received>=4) $fatal(1,"extra event from RAM score");
            if({event_on,event_id,event_note,event_octave,event_force,event_melody} !==
               {expected[received][39:10],expected[received][8]}) $fatal(1,"scheduler event mismatch %d",received);
            if(received==0) first_sample=samples;
            if(samples-first_sample!=expected[received][63:40]*300) $fatal(1,"RAM timestamp changed %d: sample %d",received,samples);
            received=received+1;
        end
        if(reset_n && deadline_fault) $fatal(1,"RAM source caused scheduler deadline fault");
    end
    song_upload_store store (
        .clk(clk),.reset_n(reset_n),.command_valid(command_valid),.command_ready(command_ready),.command(command),
        .request_length(10'd4),.request_end_tick(24'd10),.request_melody_count(8'd2),.request_crc(16'h8281),
        .request_index(request_index),.request_word(request_word),.response_valid(response_valid),.response_ready(response_ready),
        .response_code(response_code),.response_count(response_count),.playback_busy(enable && !done),
        .score_index(score_index),.score_data(score_data),.score_valid(score_valid),.score_length(score_length),
        .score_end_tick(score_end_tick),.score_melody_count(score_melody_count),.score_crc(score_crc),
        .published(published),.staging(staging),.expired(expired)
    );
    song_timeline player (
        .clk(clk),.reset_n(reset_n),.sample_strobe(sample_strobe),.enable(enable && score_valid),
        .stop_pressed(1'b0),.replay_pressed(1'b0),.remote_start(remote_start),.remote_stop(remote_stop),.tempo_select(2'd1),
        .score_index(score_index),.score_data(score_data),.score_length(score_length),.score_end_tick(score_end_tick),
        .note_index(note_index),.done(done),.deadline_fault(deadline_fault),.event_flush(event_flush),
        .event_valid(event_valid),.event_on(event_on),.event_melody(event_melody),.event_id(event_id),
        .event_note(event_note),.event_octave(event_octave),.event_force(event_force),.event_ready(event_ready)
    );
    task automatic send(input [1:0] op);
        begin
            @(negedge clk); if(!command_ready) $fatal(1,"unexpected command busy");
            command=op; command_valid=1;
            @(negedge clk); command_valid=0; timeout=0;
            while(!response_valid) begin @(negedge clk); timeout++; if(timeout>20000) $fatal(1,"response timeout"); end
            if(response_code!=0) $fatal(1,"upload failed code=%d",response_code);
            response_ready=1; @(negedge clk); response_ready=0;
        end
    endtask
    initial begin
        $readmemh("sim/upload_vectors/timeline.hex",expected,0,3);
        repeat(5) @(negedge clk); reset_n=1;
        send(0);
        for(index=0;index<4;index++) begin request_index=index; request_word=expected[index]; send(1); end
        send(2);
        repeat(2048) @(negedge clk);
        if(received!=0) $fatal(1,"commit automatically started playback");
        enable=1;
        wait(done); @(negedge clk);
        if(received!=4 || note_index!=1) $fatal(1,"incomplete timeline %d",received);
        // Explicit restart followed by STOP must flush before the launch delay.
        remote_start=1; @(negedge clk); remote_start=0;
        repeat(4096) @(negedge clk);
        remote_stop=1; #1; if(!event_flush) $fatal(1,"stop did not flush");
        @(negedge clk); remote_stop=0;
        repeat(2048) @(negedge clk);
        if(!done || received!=4) $fatal(1,"stopped player emitted stale data");
        $display("PASS: uploaded RAM drives existing song_timeline, exact sample spacing, stalls, progress, no autoplay, restart and stop flush");
        $finish;
    end
    initial begin #300000000; $fatal(1,"timeline test timeout"); end
endmodule
