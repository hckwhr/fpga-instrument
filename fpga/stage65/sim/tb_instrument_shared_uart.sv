`timescale 1ns/1ps
module tb_instrument_shared_uart;
    localparam CPB=8;
    reg sys_clk=0,audio_clk=0,reset_n=0,audio_running=1,rx=1;
    always #10 sys_clk=~sys_clk;
    initial begin #3;forever begin #7;if(audio_running)audio_clk=~audio_clk;end end
    wire tx,playback_busy,published,staging,link_fault,rx_dropped;
    reg setting_mode=0,stop_key=0,song_active=0,song_done=0;
    reg [7:0] song_index=0,song_length=85;
    wire play_request,stop_request;
    integer legacy_plays=0,legacy_stops=0;
    always @(posedge sys_clk)if(reset_n)begin
        if(play_request)legacy_plays++;
        if(stop_request)legacy_stops++;
    end
    reg [5:0] divider=0;
    wire sample_strobe=divider==63;
    always @(posedge audio_clk)if(!reset_n)divider<=0;else divider<=divider+1'b1;
    wire event_flush,event_valid,event_on,event_melody;
    wire [15:0] event_id;
    wire [3:0] event_note;
    wire [1:0] event_octave;
    wire [6:0] event_force;
    wire event_ready=divider[2:0]==3'd4;
    integer controls=0,plays=0,stops=0,received=0,checked=0,events=0,cases=0,bit_num;
    reg [7:0] out_bytes[0:8191],decoded;
    instrument_shared_uart #(.CLKS_PER_BIT(CPB),.LINE_TIMEOUT_CYCLES(2000)) dut(.*);
    always @(posedge sys_clk)if(reset_n && dut.player.command_valid && dut.player.command_ready)begin
        controls=controls+1;
        if(dut.player.command==0)plays=plays+1;
        if(dut.player.command==1)stops=stops+1;
    end
    always @(posedge audio_clk)if(reset_n && event_valid && event_ready)begin
        if(events!=0 || !event_on || event_note!=0 || event_id!=0 || event_force!=80)$fatal(1,"wrong wire-controlled event");
        events=events+1;
    end
    initial forever begin
        @(negedge tx);#(CPB*30);
        for(bit_num=0;bit_num<8;bit_num++)begin decoded[bit_num]=tx;#(CPB*20);end
        if(tx!==1'b1)$fatal(1,"UART stop bit");
        out_bytes[received]=decoded;received++;
    end
    task automatic send_text(input string request);
        begin
            for(integer i=0;i<request.len();i++)begin
                @(negedge sys_clk);rx=0;repeat(CPB)@(negedge sys_clk);
                for(integer b=0;b<8;b++)begin rx=request[i][b];repeat(CPB)@(negedge sys_clk);end
                rx=1;repeat(CPB)@(negedge sys_clk);
            end
        end
    endtask
    task automatic exchange(input string request,input string response,input integer wanted_controls,input integer wanted_plays,input integer wanted_stops);
        integer timeout;
        begin
            cases++;send_text(request);timeout=0;
            if(response.len()==0)repeat(1500)@(negedge sys_clk);
            else while(received<checked+response.len())begin @(negedge sys_clk);timeout++;if(timeout>100000)$fatal(1,"missing control reply case %d expected=%s",cases,response);end
            for(integer i=0;i<response.len();i++)if(out_bytes[checked+i]!==response[i])$fatal(1,"reply case %d offset %d got=%h want=%h",cases,i,out_bytes[checked+i],response[i]);
            checked=checked+response.len();repeat(200)@(negedge sys_clk);
            if(received!=checked || controls!=wanted_controls || plays!=wanted_plays || stops!=wanted_stops)$fatal(1,"duplicate/side effect case %d controls %d/%d play %d/%d stop %d/%d",cases,controls,wanted_controls,plays,wanted_plays,stops,wanted_stops);
            if(link_fault)$fatal(1,"unexpected link fault");
        end
    endtask
    initial begin
        repeat(8)@(negedge sys_clk);reset_n=1;repeat(8)@(negedge sys_clk);
        exchange("PING\n","PONG\n",0,0,0);
        exchange({"HELLO",8'd13,8'd10},"OK,HC05,1,9600,8N1,DEMO=TWINKLE+ODE\n",0,0,0);
        exchange("STATUS\n","STATUS,MANUAL\n",0,0,0);
        exchange("PLAY\n","OK,PLAY\n",0,0,0);song_active=1;
        exchange("PLAY\n","OK,PLAY\n",0,0,0);
        if(legacy_plays!=1)$fatal(1,"legacy PLAY restart");
        song_index=84;exchange("STATUS\n","STATUS,PLAYING,085/085\n",0,0,0);
        exchange("STOP\n","OK,STOP\n",0,0,0);song_done=1;
        exchange("STATUS\n","STATUS,STOPPED,085/085\n",0,0,0);
        setting_mode=1;exchange("PLAY\n","ERR,LOCAL\n",0,0,0);
        exchange("STATUS\n","STATUS,SETTING\n",0,0,0);setting_mode=0;
        stop_key=1;exchange("PLAY\n","ERR,LOCAL\n",0,0,0);stop_key=0;
        exchange("WHAT\n","ERR,COMMAND\n",0,0,0);
        exchange({"PL",8'd13,"AY\n"},"ERR,LINE\n",0,0,0);
        send_text("PL");exchange("","ERR,TIMEOUT\n",0,0,0);
        exchange("AY\n","",0,0,0); // outer router drains the suffix without another reply
        exchange("PING\n","PONG\n",0,0,0);
        send_text("HELLO\nPLAY\nSTOP\n");
        exchange("","OK,HC05,1,9600,8N1,DEMO=TWINKLE+ODE\nERR,BUSY\n",0,0,0);
        if(legacy_plays!=1 || legacy_stops!=2)$fatal(1,"legacy flood behavior changed");
        `include "control_vectors/cases.vh"
        `include "shared_vectors/mixed.vh"
        if(legacy_plays!=1 || legacy_stops!=4)$fatal(1,"shared STOP count");
        if(!rx_dropped)$fatal(1,"busy/drop not observable");
        $display("PASS: shared physical UART legacy/SONG2 controls %d cases, %d actual commands; exact host ACK/CRC, no duplicate PLAY/STOP, cached STATUS, identity guard, clock pause and all tempos",cases,controls);
        $finish;
    end
    initial begin #30000000;$fatal(1,"wire control timeout");end
endmodule
