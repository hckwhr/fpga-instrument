`timescale 1ns/1ps
// Real keyboard reconciler -> backpressure -> existing eight-target allocator.
module tb_string_keyboard_events;
    reg clk=0,rst=0,enable=1,stall=0,direct=0;
    always #5 clk=~clk;
    reg [9:0] cycle=0;
    always @(posedge clk) cycle<=cycle+1'b1;
    wire strobe=cycle==0;
    reg [11:0] keys=0;
    wire valid,on,ready,kv,ko;
    wire [15:0] id,ki;
    wire [3:0] note,kn;
    wire [1:0] oct;
    wire [6:0] force_value;
    reg dv=0,don=0;
    reg [15:0] did=0;
    reg [3:0] dn=0;
    assign valid=direct?dv:kv&&!stall;
    assign on=direct?don:ko;
    assign id=direct?did:ki;
    assign note=direct?dn:kn;
    keyboard_note_events keyboard(.clk(clk),.reset_n(rst),.clock_enable(1'b1),
        .enable(enable),.keys(keys),.octave(2'd1),.velocity(7'd96),.key_forces(84'd0),
        .event_ready(ready&&!stall&&!direct),.event_valid(kv),.event_on(ko),
        .event_id(ki),.event_note(kn),.event_octave(oct),.event_force(force_value));
    physical_string_bank #(.EVENT_SUPPORT(1)) dut(.clk(clk),.reset_n(rst),.clock_enable(1'b1),
        .sample_strobe(strobe),.enable(enable),.event_mode(1'b1),.event_flush(1'b0),
        .event_valid(valid),.event_on(on),.event_id(id),.event_note_in(note),
        .event_octave_in(2'd1),.event_force_in(7'd96),.event_ready(ready),
        .voice_trigger(3'd0),.voice_gate(3'd0),.play_mode(1'b0),.keymap_select(1'b0),
        .note_select(4'd0),.octave_select(2'd1),.force_value(7'd96),
        .bend(8'sd0),.vibrato_depth(8'd0),.sample(),.active_voices(),
        .active_voice_count(),.deadline_miss_count());
    integer writes=0,ons=0,offs=0,i,j,k,before_writes,owners,expected;
    reg [15:0] last_id;
    reg [7:0] before_release,match_mask;
    // Independent edge assertions: every ON writes exactly one slot; every
    // OFF changes only matching occurrence ownership, including stolen IDs.
    always @(posedge clk) if(rst) begin
        if(valid&&ready)begin
            if(on)begin ons++;last_id=id;end
            else begin
                offs++;before_release=dut.released;match_mask=0;
                for(integer n=0;n<8;n++)
                    if(dut.voice_id_valid[n] && dut.voice_id[n]==id)match_mask[n]=1;
                #1;
                if(dut.released!==(before_release|match_mask))
                    $fatal(1,"OFF changed a nonmatching owner");
            end
        end
        if(dut.state==4)begin
            writes++;
            #1;
            owners=0;
            for(integer n=0;n<8;n++)
                if(dut.voice_id_valid[n] && dut.voice_id[n]==last_id)owners++;
            if(owners!=1)$fatal(1,"ON has %0d owners",owners);
        end
        #2;
        for(integer a=0;a<8;a++)for(integer b=a+1;b<8;b++)
            if(dut.voice_id_valid[a]&&dut.voice_id_valid[b]&&dut.voice_id[a]==dut.voice_id[b])
                $fatal(1,"Duplicate ID ownership");
    end
    task ticks(input integer n);repeat(n)@(negedge clk);endtask
    task send(input bit is_on,input [15:0] eid,input [3:0] pitch);
        begin
            direct=1;dv=1;don=is_on;did=eid;dn=pitch;
            do @(posedge clk);while(!ready);
            @(negedge clk);dv=0;
            wait(dut.state==0);ticks(4);
        end
    endtask
    initial begin
        ticks(4);rst=1;ticks(8);
        for(k=0;k<12;k++)begin
            before_writes=writes;keys=12'b1<<k;ticks(1200);
            if(writes!=before_writes+1)$fatal(1,"Key %0d not allocated once",k);
            keys=0;ticks(1200);
            if(dut.voice_id_valid!=0)$fatal(1,"Key %0d OFF stuck",k);
        end
        // Held payload is released before the receiver accepts its ON.
        stall=1;keys=1;wait(kv);ticks(5);keys=0;ticks(5);
        before_writes=writes;stall=0;ticks(1200);
        if(writes!=before_writes+1 || dut.voice_id_valid!=0)
            $fatal(1,"Stalled ON was not followed by matching OFF");
        // Isolate the overload scenario from the preceding pending strikes:
        // an already released occurrence may still be ramping toward FILL.
        // Start with eight equally eligible slots, then exercise 12 held IDs.
        rst=0;ticks(4);rst=1;ticks(8);
        // A stolen waveguide ramps down before accepting the pending strike;
        // exercise backpressure for enough real 1024-clock sample slots.
        keys=12'hfff;ticks(100000);
        if(dut.voice_id_valid!==8'hff || writes!=ons)
            $fatal(1,"Twelve held keys did not fill/steal eight slots once per ON: valid=%h writes=%0d ON=%0d state=%0d reserved=%h active=%h",dut.voice_id_valid,writes,ons,dut.state,dut.reserved,dut.active_voices);
        keys=0;ticks(2400);
        if(dut.voice_id_valid!=0)$fatal(1,"Stolen occurrence OFF corrupted ownership");
        // Same pitch, different occurrences. The old OFF must leave new ID held.
        send(1,16'h1234,0);ticks(1100);send(1,16'h9234,0);ticks(1100);
        send(0,16'h1234,0);
        owners=0;for(i=0;i<8;i++)if(dut.voice_id_valid[i]&&dut.voice_id[i]==16'h9234)begin
            owners++;if(dut.released[i])$fatal(1,"Old OFF released new same-pitch ON");end
        if(owners!=1)$fatal(1,"New same-pitch occurrence lost");
        send(0,16'h9234,0);
        // Fill every voice, release one, then prove released-before-held steal.
        rst=0;ticks(4);rst=1;ticks(8);
        for(k=0;k<8;k++)begin send(1,16'h4000+k,k);ticks(1100);end
        expected=-1;for(i=0;i<8;i++)if(dut.voice_id_valid[i]&&dut.voice_id[i]==16'h4003)expected=i;
        if(expected<0)$fatal(1,"Setup failed to retain eight events");
        send(0,16'h4003,0);send(1,16'h5000,9);
        if(dut.voice_id[expected]!=16'h5000)$fatal(1,"Released-priority better criterion changed");
        if(writes!=ons)$fatal(1,"Accepted ON/write mismatch");
        $display("PASS: 12-key ON/OFF, eight-slot stealing, released priority, unique IDs, stalled release, same-pitch stale OFF; ON=%0d OFF=%0d writes=%0d",ons,offs,writes);
        $finish;
    end
    initial begin #20000000;$fatal(1,"String keyboard event timeout");end
endmodule
