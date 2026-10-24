`timescale 1ns/1ps
`define E4 dut.u_instrument
// Test-only: actual stage59b V3 top, including half-rate CE, both voice banks,
// production upload/CDC/timeline, DAC and WS2812. Only PLLs are modeled and
// UART bit dwell is shortened; 1024 audio clocks/frame is NOT accelerated.
module tb_ext4_v3_offline;
    localparam CPB=8;
    reg sys_clk=0,audio_clk=0,pixel_clk=0,locked=0,rx=1;
    always #10 sys_clk=~sys_clk;
    always #10.172414 audio_clk=~audio_clk;
    always #15.151515 pixel_clk=~pixel_clk;
    wire tx,bck,ws,din,led;
    v3_hardware_top dut(.sys_clk(sys_clk),.key0_n(1'b1),.key1_n(1'b1),
        .key2_n(1'b1),.setting_key(1'b0),.adc_miso(1'b0),.hc05_rx(rx),
        .hc05_tx(tx),.audio_bck(bck),.audio_ws(ws),.audio_din(din),.ws2812_data(led));
    defparam dut.u_instrument.SHARED_CLKS_PER_BIT=CPB;
    integer requests,replies,words_file,count_file,rc,word_count,request_count;
    string path,line;
    reg [63:0] expected[0:7];
    reg [7:0] byte_rx;
    integer received=0,events=0,frames=0,peak=0,clocks=0,last_sample=0;
    integer bits=0,magnitude,max_voices=0;
    reg [15:0] pcm_word=0,expected_pcm=0;
    reg disconnected=0;
    always @(posedge audio_clk) if(`E4.audio_internal_reset_n) begin
        clocks++;
        if(`E4.audio_sample_strobe) begin
            if(last_sample!=0 && clocks-last_sample!=1024)$fatal(1,"sample cadence changed");
            last_sample=clocks;
        end
        // Both producer and consumer advance only on engine_ce. READY can stay
        // high on the intervening audio clock; that is not a second transfer.
        if(`E4.engine_ce && `E4.uploaded_valid && `E4.uploaded_ready) begin
            if(events>=word_count)$fatal(1,"extra score event");
            if({`E4.uploaded_on,`E4.uploaded_id,`E4.uploaded_note,`E4.uploaded_octave,`E4.uploaded_force,`E4.uploaded_melody}
                !=={expected[events][39:10],expected[events][8]})$fatal(1,"score event mismatch %d",events);
            $display("CHECK: accepted exact uploaded event %0d at %0t",events,$time);
            events++;
        end
        if(`E4.polyphony_active_voice_count>max_voices)max_voices=`E4.polyphony_active_voice_count;
        // Capture exactly what the production serializer loads at a frame boundary.
        if(`E4.u_pt8211_tx.bck_half_counter==15 && !bck &&
           `E4.u_pt8211_tx.frame_started && `E4.u_pt8211_tx.bit_index==31)
            expected_pcm=(`E4.audio_stream_ready || `E4.u_pt8211_tx.silent_frame_count==63)?`E4.audio_sample:0;
        if(disconnected && rx!==1'b1)$fatal(1,"offline UART not idle");
    end
    always @(negedge bck) if(`E4.audio_internal_reset_n) begin
        if(ws!==(bits>=16))$fatal(1,"DAC channel order changed");
        pcm_word={pcm_word[14:0],din};
        if(bits==15 || bits==31)begin
            if(pcm_word!==expected_pcm)$fatal(1,"physical DAC word mismatch");
            magnitude=$signed(pcm_word)<0?-$signed(pcm_word):$signed(pcm_word);
            if(magnitude>=32767)$fatal(1,"DAC clipping");
            if(magnitude>peak)peak=magnitude;
        end
        if(bits==31)begin bits=0;frames++;end else bits++;
    end
    // Decode all 36 physical WS2812 pixels independently of the RTL frame mask.
    // Three adjacent lamps must agree; only the documented GRB value is legal.
    realtime rise_at=0,last_fall=-1000000;
    reg [23:0] grb=0;
    reg [11:0] led_mask=0;
    integer led_bit=0,lamp=0,led_frames=0;
    reg saw_chord=0,saw_d=0,saw_clear=0;
    always @(posedge led)begin
        if($realtime-last_fall>300000)begin led_bit=0;lamp=0;led_mask=0;end
        rise_at=$realtime;
    end
    always @(negedge led)if(locked && rise_at>0)begin
        if($realtime-rise_at<350 || $realtime-rise_at>830)$fatal(1,"WS2812 pulse width");
        grb={grb[22:0],($realtime-rise_at>600)};led_bit++;
        if(led_bit==24)begin
            if(grb!==24'h100800 && grb!==0)$fatal(1,"invalid WS2812 color");
            if(lamp%3==0)led_mask[lamp/3]=(grb!=0);
            else if(led_mask[lamp/3] !== (grb!=0))$fatal(1,"three lamps/key disagree");
            led_bit=0;lamp++;
            if(lamp==36)begin
                led_frames++;
                if(led_mask==12'h091)saw_chord=1; // C/E/G
                if(led_mask==12'h004)saw_d=1;
                if(disconnected && events==word_count && led_mask==0)saw_clear=1;
            end
        end
        last_fall=$realtime;
    end
    // Preserve the actual FPGA replies; the JS production parser validates them.
    initial forever begin
        @(negedge tx);#(CPB*30);
        for(integer b=0;b<8;b++)begin byte_rx[b]=tx;#(CPB*20);end
        if(tx!==1'b1)$fatal(1,"UART reply framing");
        $fwrite(replies,"%c",byte_rx);
        if(byte_rx==10)received++;
    end
    task automatic exchange(input string request);
        integer target,timeout;
        begin
            target=received+1;
            for(integer j=0;j<request.len();j++)begin
                @(negedge sys_clk);rx=0;repeat(CPB)@(negedge sys_clk);
                for(integer b=0;b<8;b++)begin rx=request[j][b];repeat(CPB)@(negedge sys_clk);end
                rx=1;repeat(CPB)@(negedge sys_clk);
            end
            timeout=0;
            while(received<target)begin @(negedge sys_clk);timeout++;if(timeout>200000)$fatal(1,"missing actual FPGA reply");end
            repeat(200)@(negedge sys_clk);
            if(received!=target)$fatal(1,"duplicate reply");
        end
    endtask
    initial begin
        force `E4.audio_clk=audio_clk;force `E4.pixel_clk=pixel_clk;
        force `E4.audio_pll_locked=locked;force `E4.lcd_pll_locked=locked;
        if(!$value$plusargs("requests=%s",path))$fatal(1,"requests path missing");
        requests=$fopen(path,"r");
        if(!$value$plusargs("replies=%s",path))$fatal(1,"replies path missing");
        replies=$fopen(path,"w");
        if(!$value$plusargs("words=%s",path))$fatal(1,"words path missing");
        $readmemh(path,expected);
        if(!$value$plusargs("count=%d",request_count))$fatal(1,"request count missing");
        word_count=8;
        if(!requests || !replies)$fatal(1,"fixture file open failed");
        repeat(20)@(negedge sys_clk);locked=1;repeat(30)@(negedge sys_clk);
        // All requests except the final STATUS end with PLAY. No subsequent
        // UART input is sent until natural completion: there is no audio stream.
        for(integer i=0;i<request_count-1;i++)begin
            rc=$fgets(line,requests);if(rc==0)$fatal(1,"request fixture truncated");
            exchange(line);
            if(i==request_count-3 && (events!=0 || peak!=0 || `E4.uploaded_selected))$fatal(1,"COMMIT auto-played");
        end
        disconnected=1;
        wait(events==word_count);
        wait(`E4.uploaded_state==3);
        repeat(2200)@(posedge `E4.audio_sample_strobe);
        if(peak<30 || max_voices<3)$fatal(1,"chord not audible at real DAC");
        if(!saw_chord || !saw_d || !saw_clear)$fatal(1,"missing offline LED guide %b/%b/%b",saw_chord,saw_d,saw_clear);
        if(`E4.audio_sample!=0 || `E4.song_held_notes!=0 || `E4.polyphony_active_voice_count!=0)$fatal(1,"completion left stuck notes");
        disconnected=0;
        rc=$fgets(line,requests);if(rc==0)$fatal(1,"STATUS fixture missing");exchange(line);
        $fclose(requests);$fclose(replies);
        $display("PASS: current V3 physical UART -> real upload/CDC -> %0d exact events -> %0d-voice chord, PT8211 peak=%0d frames=%0d; offline WS2812 frames=%0d C/E/G -> D -> clear; natural completion and silence; 1024 clocks/frame",events,max_voices,peak,frames,led_frames);
        $finish;
    end
    initial begin #400000000;$fatal(1,"V3 offline integration timeout events=%d state=%d",events,`E4.uploaded_state);end
endmodule
`undef E4
// Interface-only PLL stubs. The bench explicitly supplies clocks/locks above;
// no vendor PLL analog behavior or post-route timing is claimed by this test.
module audio_pll(input clkin,init_clk,output clkout0,lock);
    assign clkout0=1'b0;assign lock=1'b0;
endmodule
module lcd_pll(input clkin,init_clk,output clkout0,lock);
    assign clkout0=1'b0;assign lock=1'b0;
endmodule
// LCD clock output primitive only; LCD output timing is outside this test.
module ODDR(input D0,D1,TX,CLK,output Q0,Q1);
    assign Q0=CLK?D0:D1;assign Q1=TX;
endmodule
