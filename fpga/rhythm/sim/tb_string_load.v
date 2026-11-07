`timescale 1ns/1ps
// Strict real-time slots: never compress the 1024-clock audio interval.
module tb_string_load #(parameter integer SAMPLE_CLOCKS=1024);
    reg clk=0,reset_n=0,enable=1,pluck=1,chord=1;
    reg [2:0] triggers=0,gates=0;
    reg [3:0] note=0;
    reg [1:0] octave=1;
    reg [6:0] force_level=127;
    integer divider=0,cycle=0,slots=0,allocations=0,steals=0;
    integer full_slots=0,parallel_writes=0,peak=0,max_fill=0,max_update=0;
    integer max_batch=0,batch_start=-1,n,j,previous_allocations,expected_notes;
    wire strobe=divider==0;
    wire signed [15:0] sample;
    wire [7:0] active,misses;
    wire [3:0] count;
    wire [7:0] writing;
    physical_string_bank dut(.clk(clk),.reset_n(reset_n),.sample_strobe(strobe),
        .enable(enable),.voice_trigger(triggers),.voice_gate(gates),.play_mode(pluck),
        .keymap_select(chord),.note_select(note),.octave_select(octave),
        .force_value(force_level),.bend(8'sd0),.vibrato_depth(8'd0),.sample(sample),.active_voices(active),
        .active_voice_count(count),.deadline_miss_count(misses));
    always #5 clk=~clk;
    always @(negedge clk) begin
        divider=(!reset_n || divider==SAMPLE_CLOCKS-1)?0:divider+1;
        cycle=cycle+1;
    end
    always @(posedge clk) begin
        if(reset_n && enable) begin
            if(dut.state!=0 && batch_start<0) batch_start=cycle;
            if(dut.state==0 && batch_start>=0) begin
                if(cycle-batch_start>max_batch)max_batch=cycle-batch_start;
                batch_start=-1;
            end
            if(dut.state==4)begin
                if(!dut.accepting[dut.destination] || dut.reserved[dut.destination])
                    $fatal(1,"allocation overwrites an unaccepted strike");
                allocations=allocations+1;
                if(active[dut.destination])steals=steals+1;
            end
            if(&writing)parallel_writes=parallel_writes+1;
            if(strobe)begin
                if(|dut.busy)$fatal(1,"work crossed real sample deadline at slot %0d",slots);
                if(count==8)full_slots=full_slots+1;
                slots=slots+1;
                #2;
                if(misses!=0 || (^sample)===1'bx || count>8)$fatal(1,"invalid bank output");
                if(sample==32767 || sample==-32768)$fatal(1,"clipped bank output");
                if((sample<0?-sample:sample)>peak)peak=sample<0?-sample:sample;
            end
        end
    end
    genvar g;
    generate for(g=0;g<8;g=g+1)begin: watch
        integer fill_start=-1,update_start=-1,filled=0;
        reg [8:0] old_pointer;
        assign writing[g]=dut.strings[g].voice.state==8;
        always @(posedge clk) begin
            if(!reset_n || !enable)begin fill_start=-1;update_start=-1;filled=0;end
            else begin
                if(dut.strings[g].voice.state==1)begin
                    if(fill_start<0)begin fill_start=cycle;filled=0;end
                    filled=filled+1;
                end else if(fill_start>=0)begin
                    if(filled!=512)$fatal(1,"incomplete excitation RAM lane %0d: %0d",g,filled);
                    if(cycle-fill_start>max_fill)max_fill=cycle-fill_start;
                    fill_start=-1;
                end
                if(dut.strings[g].voice.state==2)update_start=cycle;
                if(writing[g])begin
                    if(update_start<0 || cycle-update_start!=6)$fatal(1,"feedback schedule lane %0d",g);
                    if(cycle-update_start+1>max_update)max_update=cycle-update_start+1;
                    update_start=-1;
                    old_pointer=dut.strings[g].voice.write_pointer;
                    #2;
                    if(dut.strings[g].voice.write_pointer!==((old_pointer+9'd1)&9'h1ff))
                        $fatal(1,"feedback pointer lane %0d",g);
                end
            end
        end
    end endgenerate
    task stream;input integer amount;integer t;begin
        for(t=0;t<amount;t=t+1)begin @(posedge clk);while(!strobe)@(posedge clk);#3;@(negedge clk);end
    end endtask
    task pulse;input [2:0] keys;input integer offset;begin
        // One-clock pulses exercise pending-key capture away from sample edges.
        repeat(offset)@(negedge clk);triggers=keys;gates=keys;
        @(negedge clk);triggers=0;
    end endtask
    task request;input [2:0] keys;input integer offset;input integer expected;begin
        previous_allocations=allocations;
        pulse(keys,offset);stream(96);
        if(allocations-previous_allocations!=expected)
            $fatal(1,"lost/repeated request: keys=%0d got=%0d expected=%0d",keys,allocations-previous_allocations,expected);
        if(dut.state!=0 || !( &dut.accepting))$fatal(1,"allocator did not settle");
    end endtask
    initial begin
        repeat(8)@(negedge clk);reset_n=1;stream(3);
        if(sample!=0 || count!=0)$fatal(1,"startup not silent");
        request(1,1,4);if(count!=4)$fatal(1,"first chord count");
        request(2,511,4);if(count!=8)$fatal(1,"second chord did not overlap");
        stream(2000);
        // All 36 selectable roots, three chord keys, max force. No idle compression.
        for(n=0;n<36;n=n+1)begin
            note=n%12;octave=n/12;
            for(j=0;j<3;j=j+1)request(1<<j,(n*29+j*251)%900,4);
        end
        chord=0;
        for(n=1;n<8;n=n+1)begin
            expected_notes=((n&1)!=0)+((n&2)!=0)+((n&4)!=0)+(n==7);
            request(n,17*n,expected_notes);
        end
        // Touch release must retire all tails without a source-key repress reviving them.
        pluck=0;gates=0;stream(18000);
        if(count!=0 || sample!=0)$fatal(1,"touch release failed to retire bank");
        // Disable during excitation and then restart: cancelled work must not return.
        chord=1;pluck=1;pulse(1,2);stream(2);
        if(!( |dut.busy))$fatal(1,"cancellation did not cover excitation fill");
        enable=0;stream(2);
        if(count!=0 || sample!=0)$fatal(1,"disable did not cancel bank");
        enable=1;stream(4);if(count!=0 || sample!=0)$fatal(1,"stale restart");
        request(4,3,4);if(count!=4)$fatal(1,"restart allocation failed");
        if(full_slots<5000 || parallel_writes<5000 || steals<400 || max_fill!=512 || peak==0)
            $fatal(1,"insufficient full-bank coverage");
        $display("METRICS slots=%0d full_slots=%0d all8_parallel_writes=%0d allocations=%0d steals=%0d peak_pcm=%0d fill_clocks=%0d feedback_clocks=%0d max_batch_clocks=%0d deadline_misses=%0d",slots,full_slots,parallel_writes,allocations,steals,peak,max_fill,max_update,max_batch,misses);
        $display("PASS: strict 1024-clock eight-string load, 36 roots, triads, pulse capture, full-pool steals, exact allocation counts, release and restart");
        $finish;
    end
    initial begin #500000000;$fatal(1,"timeout");end
endmodule
