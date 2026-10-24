`timescale 1ns/1ps
// Physical UART -> production router/store/CDC/snapshot/timeline -> events.
// Only musical time is accelerated; RAM, protocol, CDC and event handshake
// are real. Existing production PCM benches retain the real 48 kHz contract.
module tb_song_capacity4096;
    localparam CPB=4;
    reg sys_clk=0,audio_clk=0,reset_n=0,rx=1;
    always #10 sys_clk=~sys_clk;
    always #11 audio_clk=~audio_clk;
    wire tx,valid,on,melody,flush,busy;
    wire [15:0] id;
    wire [3:0] note;
    wire [1:0] octave;
    wire [6:0] velocity;
    wire [11:0] position,total;
    wire [2:0] play_state;
    reg [5:0] sample_div=0;
    always @(posedge audio_clk) sample_div<=sample_div+1'b1;
    wire strobe=sample_div==0;
    instrument_production_link #(.SCORE_BITS(12),.PROGRESS_BITS(12),.CLKS_PER_BIT(CPB)) dut (
        .clock_enable(1'b1),.sys_clk(sys_clk),.audio_clk(audio_clk),.reset_n(reset_n),.rx(rx),.tx(tx),
        .setting_mode(1'b0),.stop_key(1'b0),.song_active(1'b0),.song_done(1'b0),.song_index(8'd0),.song_length(8'd0),
        .sample_strobe(strobe),.scope_sample_strobe(strobe),.scope_dry_sample(16'd0),.scope_wet_sample(16'd0),
        .playback_busy(busy),.event_flush(flush),.event_valid(valid),.event_on(on),.event_melody(melody),
        .event_id(id),.event_note(note),.event_octave(octave),.event_force(velocity),.event_ready(1'b1),
        .local_stop(1'b0),.play_blocked(1'b0),.upload_selected(1'b1),
        .state_audio(play_state),.note_index_audio(position),.melody_count_audio(total));
    reg [63:0] words[0:4095];
    reg [15:0] crc;
    integer received=0,events=0,bit_number;
    reg [7:0] bytes[0:255],decoded;
    string line,payload,expected;
    function automatic [15:0] crc_byte(input [15:0] c,input [7:0] b);
        reg [15:0] v;
        begin v=c^{b,8'd0};for(integer k=0;k<8;k++)v=v[15]?(v<<1)^16'h1021:v<<1;crc_byte=v;end
    endfunction
    function automatic string upper(input string s);
        upper=s.toupper();
    endfunction
    function automatic string frame(input string body);
        reg [15:0] c;
        begin c=16'hffff;for(integer k=0;k<body.len();k++)c=crc_byte(c,body[k]);frame={body,upper($sformatf(",%04h\n",c))};end
    endfunction
    task automatic exchange(input string body,input string answer);
        integer timeout;
        string request,response;
        begin
            request=body=="STATUS" ? "STATUS\n" : frame(body);
            response=body=="STATUS" ? {answer,"\n"} : frame(answer);received=0;
            for(integer j=0;j<request.len();j++)begin
                @(negedge sys_clk);rx=0;repeat(CPB)@(negedge sys_clk);
                for(integer b=0;b<8;b++)begin rx=request[j][b];repeat(CPB)@(negedge sys_clk);end
                rx=1;repeat(CPB)@(negedge sys_clk);
            end
            timeout=0;while(received<response.len())begin @(negedge sys_clk);timeout++;if(timeout>500000)$fatal(1,"reply timeout %s",answer);end
            for(integer j=0;j<response.len();j++)if(bytes[j]!==response[j])$fatal(1,"reply %s byte %d got %h expected %h",answer,j,bytes[j],response[j]);
            repeat(100)@(negedge sys_clk);
            if(received!=response.len())$fatal(1,"extra reply bytes");
        end
    endtask
    initial forever begin
        @(negedge tx);#(CPB*30);
        for(bit_number=0;bit_number<8;bit_number++)begin decoded[bit_number]=tx;#(CPB*20);end
        if(tx!==1'b1)$fatal(1,"UART stop bit");
        if(received>=256)$fatal(1,"reply overflow");bytes[received]=decoded;received++;
    end
    always @(posedge audio_clk)if(reset_n && valid)begin
        if(events>=4096 || {on,id,note,octave,velocity,melody}!=={words[events][39:10],words[events][8]})
            $fatal(1,"long playback event mismatch at %d id=%d",events,id);
        if(on && events>0 && position!==(events/2-1))$fatal(1,"progress before ON wrong %d",position);
        events++;
    end
    initial begin
        crc=16'hffff;
        for(integer n=0;n<2048;n++)begin
            words[2*n]=(64'(n*8)<<40)|(64'd1<<39)|(64'(n)<<23)|(64'(n%12)<<19)|(64'd1<<17)|(64'd40<<10)|(64'd1<<9)|(64'd1<<8)|64'(n%256);
            words[2*n+1]=(words[2*n] & ~(64'd1<<39))+(64'd1<<40);
        end
        for(integer n=0;n<4096;n++)for(integer b=7;b>=0;b--)crc=crc_byte(crc,words[n][b*8+:8]);
        repeat(12)@(negedge sys_clk);reset_n=1;repeat(16)@(negedge sys_clk);
        exchange("SONG2,0123456789ABCDEF,0,CAPS","ACK2,0123456789ABCDEF,0,CAPS,13,4096,8,1");
        exchange("SONG2,0123456789ABCDEF,1,BEGIN,13,4098,16377,2048,0000","ERR2,0123456789ABCDEF,1,BEGIN,CAPACITY");
        exchange(upper($sformatf("SONG2,0123456789ABCDEF,1,BEGIN,13,4096,16377,2048,%04h",crc)),"ACK2,0123456789ABCDEF,1,BEGIN,0");
        for(integer block=0;block<512;block++)begin
            payload="";for(integer n=0;n<8;n++)payload={payload,upper($sformatf("%016h",words[block*8+n]))};
            line=$sformatf("SONG2,0123456789ABCDEF,%0d,DATA,%0d,8,%s",block+2,block*8,payload);
            expected=$sformatf("ACK2,0123456789ABCDEF,%0d,DATA,%0d",block+2,block*8+8);
            exchange(line,expected);
            if(block==64)exchange(line,expected); // duplicate beyond old address limit
            if(block==511 && (dut.score_valid || events))$fatal(1,"uncommitted score became visible");
        end
        exchange(upper($sformatf("SONG2,0123456789ABCDEF,514,COMMIT,4096,%04h",crc)),upper($sformatf("ACK2,0123456789ABCDEF,514,COMMIT,4096,%04h",crc)));
        if(dut.score_length!=4096 || dut.score_melody_count!=2048)$fatal(1,"metadata truncated");
        // Shorten only the musical clock/lead-in, after the copied descriptor.
        force dut.player.timeline.samples_per_tick=9'd1;
        force dut.player.timeline.launch_samples=13'd1;
        exchange(upper($sformatf("SONG2,0123456789ABCDEF,515,PLAY,4096,%04h,1",crc)),upper($sformatf("ACK2,0123456789ABCDEF,515,PLAY,1,0,4096,%04h,1,%04h",crc,crc)));
        wait(events==4096);wait(!busy);repeat(30)@(negedge sys_clk);
        if(position!=2047 || total!=2048 || play_state!=3)$fatal(1,"final progress/termination wrong");
        exchange("SONG2,0123456789ABCDEF,516,STATUS",upper($sformatf("ACK2,0123456789ABCDEF,516,STATUS,3,2047,4096,%04h,1,%04h",crc,crc)));
        exchange("STATUS","STATUS,STOPPED,2048/2048");
        $display("PASS: physical UART 4096 words/2048 notes, duplicate DATA, capacity guard, real CRC/CDC snapshot, exact full playback and final release/progress");$finish;
    end
    initial begin #500000000;$fatal(1,"4096 test timeout events=%d",events);end
endmodule
