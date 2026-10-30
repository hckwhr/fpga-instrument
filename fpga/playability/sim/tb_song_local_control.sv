`timescale 1ns/1ps
module tb_song_local_control;
    reg sys_clk=0,audio_clk=0,reset_n=0,running=1;
    always #10 sys_clk=~sys_clk;
    initial begin #3;forever begin #13;if(running)audio_clk=~audio_clk;end end
    reg [1:0] sr=0,ar=0;
    always @(posedge sys_clk or negedge reset_n)if(!reset_n)sr<=0;else sr<={sr[0],1'b1};
    always @(posedge audio_clk or negedge reset_n)if(!reset_n)ar<=0;else ar<={ar[0],1'b1};
    reg command_valid=0,response_ready=0,local_stop=0,play_blocked=0;
    reg [1:0] command=0;
    wire command_ready,response_valid,busy,active,event_flush,event_valid;
    wire [2:0] code,state,live_state;
    wire [7:0] length_audio;
    wire [1:0] tempo_audio;
    wire [8:0] score_index;
    reg [63:0] words[0:3],score_data;
    always @(posedge sys_clk)score_data<=words[score_index];
    song_uploaded_player #(.LOCAL_CONTROL(1)) dut(
        .sys_clk(sys_clk),.sys_reset_n(sr[1]),.audio_clk(audio_clk),.audio_reset_n(ar[1]),
        .command_valid(command_valid),.command_ready(command_ready),.command(command),.tempo_select(2'd3),
        .response_valid(response_valid),.response_ready(response_ready),.response_code(code),.response_state(state),
        .response_note_index(),.response_play_crc(),.response_play_length(),.response_stored_valid(),.response_stored_crc(),
        .playback_busy(busy),.score_index(score_index),.score_data(score_data),.score_valid(1'b1),.score_length(10'd4),
        .score_end_tick(24'd10),.score_crc(16'h8281),.sample_strobe(1'b0),.score_melody_count(8'd2),
        .event_flush(event_flush),.event_valid(event_valid),.event_on(),.event_melody(),.event_id(),.event_note(),.event_octave(),.event_force(),.event_ready(1'b1),
        .local_stop(local_stop),.play_blocked(play_blocked),.active_audio(active),.state_audio(live_state),.note_index_audio(),
        .melody_count_audio(length_audio),.tempo_audio(tempo_audio));
    task issue(input [1:0] op);
        begin @(negedge sys_clk);wait(command_ready);command=op;command_valid=1;@(negedge sys_clk);command_valid=0;end
    endtask
    task reply(input [2:0] want_code,input [2:0] want_state);
        begin wait(response_valid);@(negedge sys_clk);
        if(code!==want_code || state!==want_state)$fatal(1,"reply got %d/%d want %d/%d",code,state,want_code,want_state);
        repeat(5)@(negedge sys_clk);response_ready=1;@(negedge sys_clk);response_ready=0;wait(command_ready);end
    endtask
    initial begin
        $readmemh("sim/upload_vectors/timeline.hex",words);
        repeat(5)@(negedge sys_clk);reset_n=1;repeat(8)@(negedge sys_clk);
        play_blocked=1;issue(0);reply(2,0);if(busy || active)$fatal(1,"blocked PLAY owned audio");play_blocked=0;
        // Stop on each of the three audio command handling edges, including ACK.
        for(integer edge_index=0;edge_index<3;edge_index++)begin
            issue(0);wait(dut.request_sync[1]!=dut.acknowledge_toggle);
            repeat(edge_index)@(posedge audio_clk);
            @(negedge audio_clk);local_stop=1;
            reply(2,0);repeat(10)@(negedge sys_clk);
            if(busy || active || event_valid || !event_flush)$fatal(1,"local stop race leaked ownership/events");
            local_stop=0;repeat(5)@(negedge audio_clk);
        end
        issue(0);reply(0,1);if(!active || length_audio!=2 || tempo_audio!=3)$fatal(1,"live metadata");
        @(negedge audio_clk);local_stop=1;repeat(12)@(negedge sys_clk);local_stop=0;
        issue(2);reply(0,0);if(busy || active)$fatal(1,"local stop failed ownership release");
        @(negedge audio_clk);running=0;issue(0);repeat(100)@(negedge sys_clk);
        if(response_valid || !busy)$fatal(1,"false ACK with stopped audio clock");
        local_stop=1;running=1;reply(2,0);local_stop=0;
        issue(0);reply(0,1);issue(1);reply(0,0);
        if(busy || active)$fatal(1,"restart/remote STOP recovery");
        $display("PASS: local menu rejection, STOP on request/action/ACK edges, coherent metadata, ownership return, clock pause and restart");$finish;
    end
    initial begin #1000000;$fatal(1,"local control timeout");end
endmodule
