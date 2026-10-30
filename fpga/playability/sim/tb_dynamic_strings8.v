`timescale 1ns/1ps
module tb_dynamic_strings8;
    reg clk=0,reset_n=0,strobe=0,enable=1,pluck=1,chord=1;
    reg [2:0] triggers=0,gates=0;
    reg [3:0] note=0;
    reg [1:0] octave=1;
    reg [6:0] force_level=96;
    wire signed [15:0] sample;
    wire [7:0] active,misses;
    wire [3:0] count;
    integer errors=0,i,j,n,peak=0,mag,fd,slots=0,max_busy=0,cycles;
    integer stolen,old_ramp;
    reg [8:0] pointer_before;
    physical_string_bank dut(.clk(clk),.reset_n(reset_n),.sample_strobe(strobe),
        .enable(enable),.voice_trigger(triggers),.voice_gate(gates),.play_mode(pluck),
        .keymap_select(chord),.note_select(note),.octave_select(octave),
        .force_value(force_level),.bend(8'sd0),.vibrato_depth(8'd0),.sample(sample),.active_voices(active),
        .active_voice_count(count),.deadline_miss_count(misses));
    always #5 clk=~clk;
    task tick; begin @(posedge clk); #1; end endtask
    task check;
        input cond; input [8*100-1:0] message;
        begin if(!cond) begin $display("ERROR: %0s",message); errors=errors+1; end end
    endtask
    task next_sample;
        input real_slot;
        begin
            strobe=1; tick(); strobe=0; triggers=0;
            cycles=0;
            // Exercise true 1024-clock slots for deadline checks; shorten only
            // idle clocks in long PCM captures, after every unit has finished.
            repeat(64) begin tick(); cycles=cycles+1; end
            while((|dut.busy) && cycles<1023) begin tick(); cycles=cycles+1; end
            if(cycles>max_busy) max_busy=cycles;
            check(dut.state==0,"four-note allocation exceeded sample slot");
            check(!( |dut.busy),"physical loop missed its deadline");
            if(real_slot) repeat(1023-cycles) tick();
            check(misses==0,"deadline miss in legal sample slots");
            check((^sample)!==1'bx,"unknown PCM");
            mag=sample<0?-sample:sample;
            if(mag>peak)peak=mag;
            check(mag<32767,"dynamic mix clipped");
            check(count<=8,"invalid active count");
            slots=slots+1;
        end
    endtask
    task strike;
        input [2:0] keys;
        begin triggers=keys; gates=keys; next_sample(1); next_sample(1); end
    endtask
    task restart;
        begin reset_n=0; tick(); reset_n=1; triggers=0; gates=0; repeat(8)tick(); end
    endtask
    initial begin
        restart(); next_sample(1); check(count==0 && sample==0,"startup not silent");
        strike(1); check(count==4,"first chord must allocate four strings");
        repeat(200)next_sample(1);
        pointer_before=dut.strings[0].voice.write_pointer;
        strike(2); check(count==8,"second chord must overlap first chord");
        check(dut.strings[0].voice.pending_note==12,"second chord retuned old root");
        check(dut.strings[0].voice.write_pointer!=pointer_before,"old string stopped advancing");
        repeat(100)next_sample(1);
        // A third chord replaces the released first group; new chord remains.
        triggers=4; gates=6; next_sample(1); next_sample(1);
        check(count==8,"full-bank replacement lost active lanes");
        check(dut.strings[0].voice.pending || dut.strings[1].voice.pending ||
              dut.strings[2].voice.pending || dut.strings[3].voice.pending,
              "released chord was not chosen for replacement");
        check(!dut.strings[4].voice.pending && !dut.strings[5].voice.pending &&
              !dut.strings[6].voice.pending && !dut.strings[7].voice.pending,
              "allocator stole a held chord while released lanes were available");
        repeat(64)next_sample(1);
        check(&dut.accepting,"replacement did not finish fade/fill");
        // Real generated PCM: overlapping C/F/G chords at 150 ms intervals.
        restart(); fd=$fopen("sim/eight_strings_overlap.csv","w");
        check(fd!=0,"cannot open PCM capture");
        for(i=0;i<48000;i=i+1) begin
            if(i==0 || i==7200 || i==14400 || i==21600) begin
                triggers=(i==7200)?2:(i==14400)?4:1; gates=triggers;
            end
            next_sample(0); $fwrite(fd,"%0d,%0d\n",sample,count);
        end
        $fclose(fd);
        // Maximum-force overlapping chords over all roots and three octaves.
        force_level=127;
        for(n=0;n<36;n=n+1) begin
            restart(); note=n%12; octave=n/12;
            for(j=0;j<3;j=j+1) begin
                strike(1<<j); repeat(512)next_sample(0);
            end
        end
        // Released notes remain released when their source key is pressed again.
        restart(); chord=0; pluck=0; force_level=96; note=0; octave=1;
        strike(1); repeat(200)next_sample(0); gates=0; next_sample(0);
        strike(1); check(dut.released[0] && !dut.released[1],"repress revived previous note");
        gates=0; repeat(14000)next_sample(0);
        $display("DAMP count=%0d sample=%0d voice0=%0d quiet0=%0d level0=%0d voice1=%0d quiet1=%0d",count,sample,
            dut.strings[0].voice.sample,dut.strings[0].voice.quiet_count,dut.strings[0].voice.level,
            dut.strings[1].voice.sample,dut.strings[1].voice.quiet_count);
        check(count==0 && sample==0,"damped tails not returned to free pool");
        // Deliberately violate timing during RAM fill: diagnostic must detect
        // it, saturate, and survive mute/menu entry instead of wrapping.
        pluck=1; strike(1); triggers=2; next_sample(1);
        strobe=1; tick(); strobe=0; tick();
        repeat(300) begin strobe=1; tick(); strobe=0; tick(); end
        check(misses==255,"deadline fault counter did not saturate");
        enable=0; tick(); check(sample==0 && count==0,"disable not silent");
        check(misses!=0,"menu entry cleared diagnostic evidence");
        $display("METRICS peak_pcm=%0d max_observed_work_clocks=%0d legal_slots=%0d",peak,max_busy,slots);
        if(errors!=0)$fatal(1,"dynamic string failures: %0d",errors);
        $display("PASS: eight dynamic waveguides, overlapping tails, release latch, full-bank fade, headroom and deadline diagnostics");
        $finish;
    end
endmodule
