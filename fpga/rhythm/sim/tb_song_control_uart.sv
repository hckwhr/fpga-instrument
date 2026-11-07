`timescale 1ns/1ps
module tb_song_control_uart;
    localparam CPB=8;
    reg sys_clk=0,audio_clk=0,reset_n=0,audio_running=1,rx=1;
    always #10 sys_clk=~sys_clk;
    initial begin #3;forever begin #7;if(audio_running)audio_clk=~audio_clk;end end
    wire tx,playback_busy,published,staging,link_fault;
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
    song_control_uart #(.CLKS_PER_BIT(CPB)) dut(.*);
    always @(posedge sys_clk)if(reset_n && dut.endpoint.player.command_valid && dut.endpoint.player.command_ready)begin
        controls=controls+1;
        if(dut.endpoint.player.command==0)plays=plays+1;
        if(dut.endpoint.player.command==1)stops=stops+1;
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
        `include "control_vectors/cases.vh"
        $display("PASS: SONG2 wire controls %d cases, %d actual commands; exact host ACK/CRC, no duplicate PLAY/STOP, cached STATUS, identity guard, clock pause and all tempos",cases,controls);
        $finish;
    end
    initial begin #30000000;$fatal(1,"wire control timeout");end
endmodule
