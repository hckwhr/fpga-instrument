`timescale 1ns/1ps
module tb_song_uploaded_player #(parameter AUDIO_HALF=7);
    reg sys_clk=0,audio_clk=0,reset_n=0,audio_running=1;
    always #10 sys_clk=~sys_clk;
    initial begin #3; forever begin #(AUDIO_HALF); if(audio_running) audio_clk=~audio_clk; end end
    reg [1:0] sys_release=0,audio_release=0;
    always @(posedge sys_clk or negedge reset_n)
        if(!reset_n)sys_release<=0;else sys_release<={sys_release[0],1'b1};
    always @(posedge audio_clk or negedge reset_n)
        if(!reset_n)audio_release<=0;else audio_release<={audio_release[0],1'b1};
    reg command_valid=0,response_ready=0;
    reg [1:0] command=0,tempo_select=1;
    wire command_ready,response_valid;
    wire [2:0] response_code,response_state;
    wire [7:0] response_note_index;
    wire [15:0] response_play_crc,response_stored_crc;
    wire [9:0] response_play_length;
    wire response_stored_valid,playback_busy;
    wire [8:0] score_index;
    wire [63:0] score_data;
    wire score_valid,published,staging,expired;
    wire [9:0] score_length;
    wire [23:0] score_end_tick;
    wire [7:0] score_melody_count;
    wire [15:0] score_crc;
    reg store_valid=0,store_response_ready=0;
    reg [1:0] store_command=0;
    reg [9:0] length=4;
    reg [23:0] end_tick=10;
    reg [7:0] melody_count=2;
    reg [15:0] crc=16'h8281;
    reg [8:0] index=0;
    reg [63:0] word=0;
    wire store_ready,store_response;
    wire [3:0] store_code;
    wire [9:0] store_count;
    reg [4:0] divider=0;
    wire sample_strobe=divider==31;
    reg allow_events=1;
    wire event_ready=allow_events && divider[2:0]==3'd4;
    wire event_flush,event_valid,event_on,event_melody;
    wire [15:0] event_id;
    wire [3:0] event_note;
    wire [1:0] event_octave;
    wire [6:0] event_force;
    reg [63:0] original[0:3],alternate[0:3],maximum[0:511];
    reg use_alternate=0,check_events=1;
    integer received=0,samples=0,first_sample=0,i,timeout,transactions=0;
    reg [63:0] expected;
    reg [56:0] held_response;
    `include "playback_vectors/constants.vh"
    song_upload_store store (
        .clk(sys_clk),.reset_n(sys_release[1]),.command_valid(store_valid),.command_ready(store_ready),.command(store_command),
        .request_length(length),.request_end_tick(end_tick),.request_melody_count(melody_count),.request_crc(crc),
        .request_index(index),.request_word(word),.response_valid(store_response),.response_ready(store_response_ready),
        .response_code(store_code),.response_count(store_count),.playback_busy(playback_busy),.score_index(score_index),
        .score_data(score_data),.score_valid(score_valid),.score_length(score_length),.score_end_tick(score_end_tick),
        .score_melody_count(score_melody_count),.score_crc(score_crc),.published(published),.staging(staging),.expired(expired));
    song_uploaded_player dut (
        .local_stop(1'b0),.play_blocked(1'b0),.score_melody_count(8'd0),
        .active_audio(),.state_audio(),.note_index_audio(),.melody_count_audio(),.tempo_audio(),
        .sys_clk(sys_clk),.sys_reset_n(sys_release[1]),.audio_clk(audio_clk),.audio_reset_n(audio_release[1]),
        .command_valid(command_valid),.command_ready(command_ready),.command(command),.tempo_select(tempo_select),
        .response_valid(response_valid),.response_ready(response_ready),.response_code(response_code),.response_state(response_state),
        .response_note_index(response_note_index),.response_play_crc(response_play_crc),.response_play_length(response_play_length),
        .response_stored_valid(response_stored_valid),.response_stored_crc(response_stored_crc),.playback_busy(playback_busy),
        .score_index(score_index),.score_data(score_data),.score_valid(score_valid),.score_length(score_length),
        .score_end_tick(score_end_tick),.score_crc(score_crc),.sample_strobe(sample_strobe),.event_flush(event_flush),
        .event_valid(event_valid),.event_on(event_on),.event_melody(event_melody),.event_id(event_id),.event_note(event_note),
        .event_octave(event_octave),.event_force(event_force),.event_ready(event_ready));
    always @(posedge audio_clk) begin
        if(!reset_n) begin divider<=0; samples<=0; end
        else begin
            divider<=divider+1'b1;
            if(sample_strobe) samples<=samples+1;
            if(event_valid && event_ready) begin
                if(check_events) begin
                    if(received>=4) $fatal(1,"extra event");
                    expected=use_alternate ? alternate[received] : original[received];
                    if({event_on,event_id,event_note,event_octave,event_force,event_melody}!=={expected[39:10],expected[8]}) $fatal(1,"CDC event mismatch %d",received);
                    if(received==0) first_sample=samples;
                    if(samples-first_sample!=expected[63:40]*300) $fatal(1,"sample spacing changed");
                end
                received=received+1;
            end
            if(dut.run_audio && dut.state==2) $fatal(1,"snapshot concurrently read and written");
        end
    end
    task automatic store_send(input [1:0] op,input [3:0] code);
        begin
            @(negedge sys_clk); while(!store_ready) @(negedge sys_clk);
            store_command=op; store_valid=1;
            @(negedge sys_clk); store_valid=0; timeout=0;
            while(!store_response) begin @(negedge sys_clk); timeout++; if(timeout>100000)$fatal(1,"store timeout"); end
            if(store_code!==code)$fatal(1,"store code %d expected %d",store_code,code);
            store_response_ready=1; @(negedge sys_clk); store_response_ready=0;
        end
    endtask
    task automatic stage(input bit alt);
        begin
            length=4; end_tick=10; melody_count=2; crc=alt?ALT_CRC:16'h8281;
            store_send(0,0);
            for(integer j=0;j<4;j++)begin index=j; word=alt?alternate[j]:original[j]; store_send(1,0); end
        end
    endtask
    task automatic issue(input [1:0] op);
        begin
            @(negedge sys_clk); while(!command_ready) @(negedge sys_clk);
            command=op; command_valid=1;
            @(negedge sys_clk); command_valid=0;
        end
    endtask
    task automatic reply(input [2:0] code,input [2:0] state);
        begin
            timeout=0;
            while(!response_valid)begin @(negedge sys_clk); timeout++; if(timeout>10000)$fatal(1,"control timeout");end
            if(response_code!==code || response_state!==state)$fatal(1,"control %d got code/state %d/%d expected %d/%d",transactions,response_code,response_state,code,state);
            held_response={response_code,response_state,response_note_index,response_play_crc,response_play_length,response_stored_valid,response_stored_crc};
            repeat(13)begin @(negedge sys_clk); if(!response_valid || held_response!=={response_code,response_state,response_note_index,response_play_crc,response_play_length,response_stored_valid,response_stored_crc})$fatal(1,"response changed under backpressure");end
            response_ready=1; @(negedge sys_clk); response_ready=0; transactions++;
        end
    endtask
    task automatic control(input [1:0] op,input [2:0] code,input [2:0] state);
        begin issue(op); reply(code,state); end
    endtask
    task automatic clear_all;
        begin
            @(negedge sys_clk); reset_n=0; command_valid=0; response_ready=0; store_valid=0; store_response_ready=0;
            repeat(6)@(negedge sys_clk); reset_n=1; received=0;
            repeat(8)@(negedge sys_clk);
            if(playback_busy || response_valid || score_valid || event_valid)$fatal(1,"reset leaked ownership or score");
        end
    endtask
    initial begin
        $readmemh("sim/upload_vectors/timeline.hex",original);
        $readmemh("sim/playback_vectors/alternate.hex",alternate);
        $readmemh("sim/upload_vectors/capacity_512.hex",maximum);
        clear_all();
        control(0,1,0); control(3,3,0);
        stage(0); store_send(2,0);
        repeat(1000)@(negedge sys_clk);
        if(received || playback_busy)$fatal(1,"commit autoplay");
        control(2,0,0);
        if(!response_stored_valid || response_stored_crc!=16'h8281 || response_play_length!=0)$fatal(1,"initial status");
        control(0,0,1);
        if(!playback_busy || response_play_crc!=16'h8281 || response_play_length!=4)$fatal(1,"play identity");
        control(0,2,1);
        stage(1); store_send(2,5);
        wait(received==1); control(2,0,2);
        wait(!playback_busy); control(2,0,3);
        if(received!=4 || response_note_index!=1)$fatal(1,"completion/progress");
        store_send(2,0); control(2,0,3);
        if(response_play_crc!=16'h8281 || response_stored_crc!=ALT_CRC)$fatal(1,"stored/playing identity mixed");
        received=0; use_alternate=1;
        control(0,0,1); control(1,0,0); control(1,0,0);
        repeat(1500)@(negedge sys_clk);
        if(received || !event_flush || playback_busy)$fatal(1,"STOP during launch leaked event");
        control(0,0,1); wait(received==1); control(1,0,0);
        repeat(1500)@(negedge sys_clk);
        if(received!=1 || !event_flush)$fatal(1,"STOP after ON leaked event");
        // At the exact publication edge, PLAY takes ownership and COMMIT must
        // fail BUSY; PLAY must retain the previously published alternate song.
        stage(0);
        @(negedge sys_clk); store_command=2; store_valid=1;
        @(negedge sys_clk); store_valid=0;
        wait(store.validate_done); @(negedge sys_clk); command=0; command_valid=1;
        @(negedge sys_clk); command_valid=0;
        if(!store_response || store_code!=5 || published)$fatal(1,"PLAY/COMMIT publication race");
        store_response_ready=1; @(negedge sys_clk); store_response_ready=0;
        reply(0,1);
        if(response_play_crc!=ALT_CRC)$fatal(1,"race copied wrong bank");
        control(1,0,0); store_send(2,0);
        // A stopped audio clock cannot produce a successful command response.
        @(negedge audio_clk); audio_running=0;
        issue(0); repeat(200)@(negedge sys_clk);
        if(response_valid || command_ready || !playback_busy)$fatal(1,"false ACK with stopped audio clock");
        audio_running=1; reply(0,1); control(1,0,0);
        // Reset while copying, and reset after PLAY delivery/while ACK stalls.
        issue(0); clear_all(); control(2,0,0);
        stage(0); store_send(2,0); issue(0); wait(response_valid); clear_all(); control(2,0,0);
        // Exhaust the 512-word copy boundary, including address 511.
        length=512; end_tick=2041; melody_count=255; crc=MAX_CRC;
        store_send(0,0);
        for(i=0;i<512;i++)begin index=i; word=maximum[i]; store_send(1,0);end
        store_send(2,0); control(0,0,1);
        if(response_play_length!=512 || response_play_crc!=MAX_CRC)$fatal(1,"512 metadata");
        for(i=0;i<512;i++)if(dut.snapshot[i]!==maximum[i])$fatal(1,"snapshot boundary word %d",i);
        control(1,0,0);
        // Genuine scheduler deadline failure is returned coherently and locks
        // are released. No forcing internal state to manufacture completion.
        stage(0); store_send(2,0); allow_events=0;
        control(0,0,1); wait(!playback_busy); control(2,0,4);
        allow_events=1; received=0; use_alternate=0;
        control(0,0,1); wait(received==1); control(1,0,0);
        $display("PASS: uploaded player CDC half=%d, %d controls; exact events/timing, commit race, stop, status snapshot, clock pause, reset, 512 words and deadline recovery",AUDIO_HALF,transactions);
        $finish;
    end
    initial begin #100000000; $fatal(1,"player global timeout"); end
endmodule

module tb_song_uploaded_player_slow;
    tb_song_uploaded_player #(.AUDIO_HALF(13)) test_instance();
endmodule
