`timescale 1ns/1ps
// Actual UART -> store -> CDC snapshot -> unchanged timeline -> production
// polyphony bank -> PT8211 serializer. No force and no substitute ACK/store.
module tb_song_upload_pcm #(parameter WIRE_CONTROL=0, parameter SHARED_UART=0,
    parameter SCORE_ENVELOPE=0);
    localparam CPB=8;
    reg sys_clk=0,audio_clk=0,reset_n=0,rx=1;
    always #10 sys_clk=~sys_clk;
    always #10.172414 audio_clk=~audio_clk;
    wire tx;
    reg command_valid=0,response_ready=0;
    reg [1:0] command=0;
    wire command_ready,response_valid;
    wire [2:0] response_code,response_state;
    wire [7:0] response_note_index;
    wire [15:0] response_play_crc,response_stored_crc;
    wire [9:0] response_play_length;
    wire response_stored_valid,playback_busy,published,staging,link_fault;
    wire sample_strobe,event_flush,event_valid,event_on,event_melody,event_ready;
    wire [15:0] event_id;
    wire [3:0] event_note;
    wire [1:0] event_octave;
    wire [6:0] event_force;
    wire signed [15:0] pcm;
    wire [5:0] voices;
    wire [11:0] held_notes;
    wire bck,ws,din,stream_ready;
    integer received=0,checked=0,bit_num,timeout,events=0,samples=0,peak=0,magnitude,serial_peak=0,bit_count=0;
    reg [7:0] out_bytes[0:2047],decoded;
    reg [15:0] serial_word=0;
    reg [63:0] expected[0:3];
    reg [1:0] audio_release=0;
    always @(posedge audio_clk or negedge reset_n)
        if(!reset_n)audio_release<=0;else audio_release<={audio_release[0],1'b1};
    generate if(SHARED_UART)begin: shared_wire
    instrument_shared_uart #(.CLKS_PER_BIT(CPB)) dut (
        .sys_clk(sys_clk),.audio_clk(audio_clk),.reset_n(reset_n),.rx(rx),.tx(tx),
        .setting_mode(1'b0),.stop_key(1'b0),.song_active(1'b0),.song_done(1'b0),
        .song_index(8'd0),.song_length(8'd85),.play_request(),.stop_request(),.rx_dropped(),
        .playback_busy(playback_busy),.published(published),.staging(staging),.link_fault(link_fault),
        .sample_strobe(sample_strobe),.event_flush(event_flush),.event_valid(event_valid),.event_on(event_on),
        .event_melody(event_melody),.event_id(event_id),.event_note(event_note),.event_octave(event_octave),
        .event_force(event_force),.event_ready(event_ready));
    end else begin: separate_wire
    song_upload_playback #(.WIRE_CONTROL(WIRE_CONTROL),.CLKS_PER_BIT(CPB)) dut (
        .sys_clk(sys_clk),.audio_clk(audio_clk),.reset_n(reset_n),.rx(rx),.tx(tx),
        .command_valid(command_valid),.command_ready(command_ready),.command(command),.tempo_select(2'd1),
        .response_valid(response_valid),.response_ready(response_ready),.response_code(response_code),.response_state(response_state),
        .response_note_index(response_note_index),.response_play_crc(response_play_crc),.response_play_length(response_play_length),
        .response_stored_valid(response_stored_valid),.response_stored_crc(response_stored_crc),.playback_busy(playback_busy),
        .published(published),.staging(staging),.link_fault(link_fault),.sample_strobe(sample_strobe),
        .event_flush(event_flush),.event_valid(event_valid),.event_on(event_on),.event_melody(event_melody),
        .event_id(event_id),.event_note(event_note),.event_octave(event_octave),.event_force(event_force),.event_ready(event_ready));
    end endgenerate
    polyphony_bank_32 #(.SCORE_ENVELOPE_ENABLE(SCORE_ENVELOPE)) bank (
        .clk(audio_clk),.reset_n(audio_release[1]),.sample_strobe(sample_strobe),.enable(1'b1),
        .voice_trigger(3'd0),.voice_gate(3'd0),.play_mode(1'b0),.tone_select(SCORE_ENVELOPE ? 2'd3 : 2'd0),.note_select(4'd0),
        .keymap_select(1'b0),.octave_select(2'd1),.force_value(7'd80),.glide_select(2'd0),.bend(8'sd0),.vibrato_depth(8'd0),
        .event_mode(1'b1),.event_flush(event_flush),.event_valid(event_valid),.event_on(event_on),.event_id(event_id),
        .event_note(event_note),.event_octave(event_octave),.wide_event_octave(1'b0),.event_force(event_force),
        .event_ready(event_ready),.sample(pcm),.active_voice_count(voices),.held_note_mask(held_notes),.all_voices_active());
    pt8211_tx serializer (.audio_clk(audio_clk),.reset_n(audio_release[1]),.sample_in(pcm),.sample_strobe(sample_strobe),
        .audio_bck(bck),.audio_ws(ws),.audio_din(din),.stream_ready(stream_ready));
    always @(posedge audio_clk) if(audio_release[1])begin
        if(event_valid && event_ready)begin
            if(events>=4 || {event_on,event_id,event_note,event_octave,event_force,event_melody}!=={expected[events][39:10],expected[events][8]})$fatal(1,"PCM path event mismatch");
            events=events+1;
        end
        if(sample_strobe)begin
            samples=samples+1;
            if((^pcm)===1'bx)$fatal(1,"unknown PCM");
            magnitude=pcm<0?-$signed(pcm):$signed(pcm);
            if(magnitude>=32767)$fatal(1,"PCM clipping");
            if(magnitude>peak)peak=magnitude;
        end
    end
    // Independently decode both physical DAC words; also verify their bitstream
    // equals the PCM value captured at the beginning of each stereo frame.
    reg [15:0] frame_pcm=0;
    always @(posedge bck) if(audio_release[1] && !ws && serializer.bit_index==0) frame_pcm=pcm;
    always @(negedge bck) if(audio_release[1]) begin
        serial_word={serial_word[14:0],din}; bit_count=bit_count+1;
        if(bit_count==16)begin
            bit_count=0;
            if(stream_ready && serial_word!==frame_pcm)$fatal(1,"DAC serialization mismatch %h/%h",serial_word,frame_pcm);
            magnitude=$signed(serial_word)<0?-$signed(serial_word):$signed(serial_word);
            if(magnitude>serial_peak)serial_peak=magnitude;
        end
    end
    initial forever begin
        @(negedge tx); #(CPB*30);
        for(bit_num=0;bit_num<8;bit_num++)begin decoded[bit_num]=tx; #(CPB*20);end
        if(tx!==1'b1)$fatal(1,"UART TX framing");
        out_bytes[received]=decoded; received++;
    end
    task automatic send_byte(input [7:0] value);
        begin
            @(negedge sys_clk);rx=0;repeat(CPB)@(negedge sys_clk);
            for(integer j=0;j<8;j++)begin rx=value[j];repeat(CPB)@(negedge sys_clk);end
            rx=1;repeat(CPB)@(negedge sys_clk);
        end
    endtask
    task automatic exchange(input string request,input string response);
        begin
            for(integer j=0;j<request.len();j++)send_byte(request[j]);
            timeout=0;
            while(received<checked+response.len())begin @(negedge sys_clk);timeout++;if(timeout>100000)$fatal(1,"UART ACK timeout");end
            for(integer j=0;j<response.len();j++)if(out_bytes[checked+j]!==response[j])$fatal(1,"UART ACK mismatch");
            checked=checked+response.len();repeat(200)@(negedge sys_clk);
        end
    endtask
    task automatic control(input [1:0] op,input [2:0] wanted);
        begin
            if(WIRE_CONTROL)begin
                `include "control_vectors/pcm_control.vh"
            end else begin
            @(negedge sys_clk);while(!command_ready)@(negedge sys_clk);command=op;command_valid=1;
            @(negedge sys_clk);command_valid=0;timeout=0;
            while(!response_valid)begin @(negedge sys_clk);timeout++;if(timeout>10000)$fatal(1,"PCM control timeout");end
            if(response_code!=0 || response_state!=wanted)$fatal(1,"PCM control status");
            response_ready=1;@(negedge sys_clk);response_ready=0;
            end
        end
    endtask
    initial begin
        $readmemh("sim/upload_vectors/timeline.hex",expected);
        repeat(10)@(negedge sys_clk);reset_n=1;repeat(10)@(negedge sys_clk);
        if(WIRE_CONTROL)begin
            `include "control_vectors/pcm_upload.vh"
        end else begin
            `include "playback_vectors/uart_upload.vh"
        end
        if(events || peak || playback_busy || link_fault)$fatal(1,"upload autoplay/fault");
        control(0,1);
        if(SHARED_UART)exchange("PING\n","PONG\n");
        wait(events==1);
        repeat(300)@(posedge sample_strobe);
        if(peak<30 || serial_peak<30 || voices==0)$fatal(1,"uploaded note not present in real PCM/DAC stream %d/%d",peak,serial_peak);
        control(1,0);
        if(SHARED_UART)exchange("STATUS\n","STATUS,MANUAL\n");
        repeat(2200)@(posedge sample_strobe);
        if(pcm!=0 || voices!=0 || held_notes!=0 || !event_flush || playback_busy)$fatal(1,"STOP left held voices/PCM");
        if(events!=1)$fatal(1,"STOP leaked subsequent OFF/ON");
        $display("PASS: physical UART upload -> real RAM -> asynchronous snapshot -> unchanged timeline -> 32-voice PCM -> PT8211 words, peak=%d serial_peak=%d; STOP releases to silence",peak,serial_peak);
        $finish;
    end
    initial begin #350000000;$fatal(1,"PCM integration timeout");end
endmodule

module tb_song_control_pcm;
    tb_song_upload_pcm #(.WIRE_CONTROL(1)) test_instance();
endmodule

module tb_shared_uart_pcm;
    tb_song_upload_pcm #(.WIRE_CONTROL(1),.SHARED_UART(1)) test_instance();
endmodule

// Exercise the new piano envelope through the existing real UART, RAM,
// CDC, playback commands and independently decoded physical DAC words.
module tb_instrumental_upload_pcm;
    tb_song_upload_pcm #(.WIRE_CONTROL(1),.SHARED_UART(1),.SCORE_ENVELOPE(1)) test_instance();
endmodule
