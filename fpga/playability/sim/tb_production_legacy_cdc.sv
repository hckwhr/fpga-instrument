`timescale 1ns/1ps
module tb_production_legacy_cdc;
    localparam CPB=8;
    reg sys_clk=0,audio_clk=0,reset_n=0,audio_running=1,rx=1;
    always #10 sys_clk=~sys_clk;
    initial begin #3;forever begin #13;if(audio_running)audio_clk=~audio_clk;end end
    wire tx,play_request,stop_request;
    integer plays=0,stops=0,received=0,checked=0,bit_num;
    reg [7:0] bytes[0:511],decoded;
    instrument_production_link #(.CLKS_PER_BIT(CPB),.LINE_TIMEOUT_CYCLES(2000)) dut(
        .sys_clk(sys_clk),.audio_clk(audio_clk),.reset_n(reset_n),.rx(rx),.tx(tx),
        .setting_mode(1'b0),.stop_key(1'b0),.song_active(1'b0),.song_done(1'b0),.song_index(8'd0),.song_length(8'd85),
        .play_request(play_request),.stop_request(stop_request),.sample_strobe(1'b0),.playback_busy(),.published(),.staging(),.link_fault(),.rx_dropped(),
        .event_flush(),.event_valid(),.event_on(),.event_melody(),.event_id(),.event_note(),.event_octave(),.event_force(),.event_ready(1'b1),
        .local_stop(1'b0),.play_blocked(1'b0),.upload_selected(1'b0),.active_audio(),.state_audio(),.note_index_audio(),.melody_count_audio(),.tempo_audio());
    always @(posedge audio_clk)if(reset_n)begin if(play_request)plays++;if(stop_request)stops++;end
    initial forever begin
        @(negedge tx);#(CPB*30);
        for(bit_num=0;bit_num<8;bit_num++)begin decoded[bit_num]=tx;#(CPB*20);end
        if(tx!==1'b1)$fatal(1,"UART stop bit");bytes[received]=decoded;received++;
    end
    task automatic send(input string text);
        begin for(integer j=0;j<text.len();j++)begin
            @(negedge sys_clk);rx=0;repeat(CPB)@(negedge sys_clk);
            for(integer b=0;b<8;b++)begin rx=text[j][b];repeat(CPB)@(negedge sys_clk);end
            rx=1;repeat(CPB)@(negedge sys_clk);
        end end
    endtask
    task automatic reply(input string text);
        begin wait(received>=checked+text.len());
        for(integer j=0;j<text.len();j++)if(bytes[checked+j]!==text[j])$fatal(1,"reply ordering offset %d actual %h expected=%s",j,bytes[checked+j],text);
        checked+=text.len();repeat(200)@(negedge sys_clk);
        if(received!=checked)$fatal(1,"unexpected reply");end
    endtask
    initial begin
        repeat(8)@(negedge sys_clk);reset_n=1;repeat(8)@(negedge sys_clk);
        @(negedge audio_clk);audio_running=0;
        send({"PL",8'd13,"AY\n"});send("PLAY\n");repeat(200)@(negedge sys_clk);
        if(received || plays)$fatal(1,"fault/PLAY acknowledged without execution");
        audio_running=1;reply("ERR,LINE\nERR,BUSY\n");
        if(plays)$fatal(1,"fault suffix/flood started music");
        send("PING\n");reply("PONG\n");
        @(negedge audio_clk);audio_running=0;send("PLAY\n");repeat(200)@(negedge sys_clk);
        if(received!=checked || plays)$fatal(1,"PLAY early ACK");
        audio_running=1;reply("OK,PLAY\n");if(plays!=1)$fatal(1,"PLAY not executed exactly once");
        send("HELLO\nPLAY\nSTOP\n");reply("OK,HC05,1,9600,8N1,DEMO=TWINKLE+ODE\nERR,BUSY\n");
        if(plays!=1 || stops!=1)$fatal(1,"STOP unavailable under TX backpressure");
        // Joint reset removes a byte stalled before audio-domain delivery.
        @(negedge audio_clk);audio_running=0;send("PLAY\n");reset_n=0;repeat(8)@(negedge sys_clk);
        audio_running=1;reset_n=1;repeat(20)@(negedge sys_clk);
        send("PING\n");reply("PONG\n");if(plays!=1)$fatal(1,"reset ghost PLAY");
        $display("PASS: production legacy CDC ordered faults/bytes, stopped audio clock, exact execution ACK, flood STOP, reset and recovery");$finish;
    end
    initial begin #10000000;$fatal(1,"production legacy timeout");end
endmodule
