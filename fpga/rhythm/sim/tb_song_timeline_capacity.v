`timescale 1ns/1ps
// Exercise the admission boundary against the real bank, with real 1024-clock
// slots: 8 OFF + 8 ON at one timestamp, while all 8 old tails remain occupied.
module tb_song_timeline_capacity;
    reg clk=0,reset_n=0,strobe=0,enable=0;
    reg [63:0] rom[0:31],data;
    reg bank_strobe=0,bank_flush=1;
    wire [8:0] address;
    wire valid,on,flush,done,fault,ready;
    wire [15:0] id;
    wire [3:0] note;
    wire [1:0] octave;
    wire [6:0] velocity;
    wire [5:0] count;
    wire signed [15:0] pcm;
    integer i,j,ons=0,offs=0,max_count=0,max_age=0,attacks=0;
    reg [31:0] pending=0,mask;
    song_timeline player(.clk(clk),.reset_n(reset_n),.sample_strobe(strobe),.enable(enable),
        .stop_pressed(1'b0),.replay_pressed(1'b0),.remote_start(1'b0),.remote_stop(1'b0),
        .tempo_select(2'd3),.score_index(address),.score_data(data),.score_length(10'd32),
        .score_end_tick(24'd8),.note_index(),.done(done),.deadline_fault(fault),
        .event_flush(flush),.event_valid(valid),.event_on(on),.event_id(id),
        .event_note(note),.event_octave(octave),.event_force(velocity),.event_melody(),.event_ready(ready));
    polyphony_bank_32 bank(.clk(clk),.reset_n(reset_n),.sample_strobe(bank_strobe),.enable(enable),
        .bend(8'sd0),.vibrato_depth(8'd0),.glide_select(2'd0),
        .voice_trigger(3'd0),.voice_gate(3'd0),.play_mode(1'b0),.tone_select(2'd3),
        .note_select(4'd0),.keymap_select(1'b0),.octave_select(2'd1),.force_value(7'd40),
        .event_mode(1'b1),.event_flush(bank_flush),.event_valid(valid),.event_on(on),
        .event_id(id),.event_note(note),.event_octave(octave),.event_force(velocity),
        .event_ready(ready),.sample(pcm),.active_voice_count(count),.held_note_mask(),.all_voices_active());
    always #5 clk=~clk;
    always @(posedge clk)begin data<=rom[address[4:0]];bank_strobe<=strobe;bank_flush<=flush;end
    always @(posedge clk) if(reset_n)begin
        if(fault)$fatal(1,"admitted capacity misses deadline");
        if(bank_strobe && ((^pcm)===1'bx || pcm>=4095 || pcm<=-4096))
            $fatal(1,"capacity PCM unknown or clips after song x8 gain");
        if(valid && ready)begin if(on)ons=ons+1;else offs=offs+1;end
        if(player.state==5 && ready && player.slot_age>max_age)max_age=player.slot_age;
        if(count>max_count)max_count=count;
        if(bank.allocate_voice)begin
            if(bank.voice_active[bank.search_index])$fatal(1,"admitted score steals");
            pending[bank.search_index]=1;
        end
        if(bank_strobe && pending!=0)begin
            mask=pending;pending=0;
            for(j=0;j<32;j=j+1)if(mask[j] && bank.envelope_gain[j]!=0)$fatal(1,"early attack");
            #1;
            for(j=0;j<32;j=j+1)if(mask[j])begin
                if(bank.envelope_gain[j]!=16)$fatal(1,"split attack");attacks=attacks+1;
            end
        end
    end
    function [63:0] record;
        input [23:0] t;input is_on;input[15:0] occurrence;input last;
        begin record={t,is_on,occurrence,4'd0,2'd1,7'd40,last,1'b0,8'd0};end
    endfunction
    task tick;begin @(posedge clk);#1;end endtask
    task slot;input integer clocks;begin strobe=1;tick();strobe=0;repeat(clocks-1)tick();end endtask
    initial begin
        for(i=0;i<8;i=i+1)begin
            rom[i]=record(0,1,i,i==7);
            rom[8+i]=record(2,0,i,0);
            rom[16+i]=record(2,1,8+i,i==7);
            rom[24+i]=record(7,0,8+i,i==7);
        end
        repeat(3)tick();reset_n=1;enable=1;repeat(20)tick();
        repeat(7199)slot(12);repeat(2700)slot(1024);
        if(!done || count!=0 || pcm!=0 || ons!=16 || offs!=16 || attacks!=16 || max_count!=16 || max_age>=1000)
            $fatal(1,"capacity counts/tails failed");
        $display("PASS: 16-event simultaneous group, 16 occupied lanes, same-pitch independent IDs, no stealing/clips, common attacks; max drain age=%0d clocks",max_age);
        $finish;
    end
    initial begin #40000000;$fatal(1,"capacity timeout");end
endmodule
