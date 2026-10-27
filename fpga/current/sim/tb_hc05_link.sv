`timescale 1ns/1ps
module tb_hc05_link;
    localparam CPB=16, BIT_NS=160;
    reg clk=0, reset_n=0, rx=1, menu=0, stop_key=0, active=0, done=0;
    reg [7:0] position=0;
    reg [7:0] song_length=85;
    wire tx, play, stop;
    integer starts=0, stops=0, received=0, checked=0, j;
    reg [7:0] log_bytes[0:4095];
    reg [7:0] byte_out;
    hc05_link #(.CLKS_PER_BIT(CPB),.TIMEOUT_CYCLES(2000)) dut (
        .clk(clk),.reset_n(reset_n),.rx(rx),.tx(tx),.setting_mode(menu),.stop_key(stop_key),
        .song_active(active),.song_done(done),.song_index(position),
        .song_length(song_length),
        .play_request(play),.stop_request(stop));
    always #5 clk=~clk;
    always @(posedge clk) begin
        if (play) starts=starts+1;
        if (stop) stops=stops+1;
    end
    // Independent wire decoder checks LSB order and the actual stop bit.
    initial forever begin
        @(negedge tx);
        #(BIT_NS+BIT_NS/2);
        for (j=0;j<8;j=j+1) begin byte_out[j]=tx; #(BIT_NS); end
        if (tx!==1'b1) $fatal(1,"TX stop bit invalid");
        log_bytes[received]=byte_out; received=received+1;
    end
    task send_byte(input [7:0] value, input integer period_ns=BIT_NS, input bit bad_stop=0);
        integer k;
        begin
            @(negedge clk); rx=0; #(period_ns);
            for(k=0;k<8;k=k+1) begin rx=value[k]; #(period_ns); end
            rx=!bad_stop; #(period_ns); rx=1;
        end
    endtask
    task send(input string command, input integer period_ns=BIT_NS);
        integer k; begin for(k=0;k<command.len();k=k+1)send_byte(command[k],period_ns); end
    endtask
    task expect_reply(input string expected);
        integer k,n; begin
            n=0;
            while(received<checked+expected.len() && n<16000) begin @(posedge clk); n=n+1; end
            if(received<checked+expected.len())$fatal(1,"missing response: %s received=%0d",expected,received-checked);
            for(k=0;k<expected.len();k=k+1)
                if(log_bytes[checked+k]!==expected[k])$fatal(1,"response mismatch %s at %0d got %h expected %h",expected,k,log_bytes[checked+k],expected[k]);
            checked=checked+expected.len();
            #(BIT_NS*2);
        end
    endtask
    initial begin
        #31; reset_n=1; #100;
        if(tx!==1)$fatal(1,"TX idle must be high");
        // A short low glitch must not produce a character or response.
        rx=0; #30; rx=1; #(BIT_NS*12);
        if(received!=0)$fatal(1,"false start accepted");
        send("PING\n"); expect_reply("PONG\n");
        send({"HELLO",8'd13,8'd10}); expect_reply("OK,HC05,1,9600,8N1,DEMO=TWINKLE+ODE\n");
        send("STATUS\n"); expect_reply("STATUS,MANUAL\n");
        send("PLAY\n"); expect_reply("OK,PLAY\n");
        if(starts!=1)$fatal(1,"PLAY event lost"); active=1;
        send("PLAY\n"); expect_reply("OK,PLAY\n");
        if(starts!=1)$fatal(1,"duplicate PLAY restarted song");
        position=84; send("STATUS\n"); expect_reply("STATUS,PLAYING,085/085\n");
        send("STOP\n"); expect_reply("OK,STOP\n"); done=1;
        send("STOP\n"); expect_reply("OK,STOP\n");
        send("STATUS\n"); expect_reply("STATUS,STOPPED,085/085\n");
        song_length=30; position=29;
        send("STATUS\n"); expect_reply("STATUS,STOPPED,030/030\n");
        song_length=255; position=254;
        send("STATUS\n"); expect_reply("STATUS,STOPPED,255/255\n");
        song_length=85; position=84;
        send("PLAY\n"); expect_reply("OK,PLAY\n");
        if(starts!=2 || stops!=2)$fatal(1,"restart/stop event count");
        menu=1; send("PLAY\n"); expect_reply("ERR,LOCAL\n");
        send("STATUS\n"); expect_reply("STATUS,SETTING\n"); menu=0;
        stop_key=1; send("PLAY\n"); expect_reply("ERR,LOCAL\n"); stop_key=0;
        send("WHAT\n"); expect_reply("ERR,COMMAND\n");
        send("123456789PLAY\n"); expect_reply("ERR,LINE\n");
        send({"PL",8'd13,"AY",8'd10}); expect_reply("ERR,LINE\n");
        send("PL"); expect_reply("ERR,TIMEOUT\n");
        send("AY\n"); expect_reply("ERR,LINE\n");
        send_byte(8'h50,BIT_NS,1); expect_reply("ERR,FRAME\n");
        send("LAY\n"); expect_reply("ERR,LINE\n");
        send("PING\n",157); expect_reply("PONG\n");
        send("PING\n",163); expect_reply("PONG\n");
        // A stopped receiver with no STATE input never invents pairing state.
        send("HELLO\nPLAY\nSTOP\n");
        expect_reply("OK,HC05,1,9600,8N1,DEMO=TWINKLE+ODE\n"); expect_reply("ERR,BUSY\n");
        if(starts!=2 || stops!=3)$fatal(1,"flood must reject PLAY and still honor STOP");
        send("PING\n"); expect_reply("PONG\n");
        if(checked!=received)$fatal(1,"unexpected trailing response");
        $display("PASS: HC05 wire UART, +/-2%% baud, framing, CRLF, timeout, bounded lines, command ACK, idempotent PLAY, local priority, flood STOP and recovery");
        $finish;
    end
    initial begin #10000000; $fatal(1,"HC05 timeout"); end
endmodule
