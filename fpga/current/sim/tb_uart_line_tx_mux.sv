`timescale 1ns/1ps
module tb_uart_line_tx_mux;
    reg clk=0,reset_n=0,legacy_valid=0,song_valid=0,tx_ready=0;
    reg [7:0] legacy_data=0,song_data=0;
    wire legacy_ready,song_ready,tx_valid,song_owned;
    wire [7:0] tx_data;
    string received="";
    reg held=0;
    reg [7:0] held_data;
    uart_line_tx_mux dut(.*);
    always #5 clk=~clk;
    always @(posedge clk)begin
        if(!reset_n)held=0;
        else begin
            if(held && (!tx_valid || tx_data!==held_data))$fatal(1,"TX changed under backpressure");
            held=tx_valid&&!tx_ready;held_data=tx_data;
            if(legacy_ready && song_ready)$fatal(1,"both producers consumed");
            if(tx_valid && tx_ready)received={received,tx_data};
        end
    end
    task cycle;@(posedge clk);@(negedge clk);endtask
    initial begin
        repeat(3)cycle();reset_n=1;
        legacy_data="A";legacy_valid=1;cycle(); // locked before handshake
        song_data="B";song_valid=1;repeat(4)cycle();
        if(song_ready || tx_data!="A")$fatal(1,"new source stole stalled first byte");
        tx_ready=1;cycle();legacy_valid=0;
        repeat(4)cycle();if(song_ready || received!="A")$fatal(1,"valid gap unlocked line");
        legacy_data=10;legacy_valid=1;cycle();legacy_valid=0;
        cycle();song_data=10;cycle();song_valid=0;
        if(received!="A\nB\n")$fatal(1,"interleaved replies %s",received);
        // Both remain valid across boundaries; LF rotates the grant.
        legacy_data=10;song_data=10;legacy_valid=1;song_valid=1;
        #1; // allow combinational selection to settle after testbench drive
        if(!legacy_ready || song_ready)$fatal(1,"expected legacy turn");
        cycle();if(!song_ready || legacy_ready)$fatal(1,"expected song turn");
        cycle();if(!legacy_ready || song_ready)$fatal(1,"round robin starved legacy");
        legacy_valid=0;song_data="C";cycle();song_valid=0;
        repeat(3)cycle();if(!song_owned)$fatal(1,"owner lost in formatter gap");
        // Reset releases a stopped formatter; a new whole reply can proceed.
        reset_n=0;cycle();legacy_data="D";legacy_valid=1;reset_n=1;cycle();
        legacy_data=10;cycle();legacy_valid=0;
        if(received!="A\nB\n\n\nCD\n")$fatal(1,"reset/fairness output %s",received);
        $display("PASS: whole-reply TX ownership, first-byte/backpressure stability, formatter gaps, fairness and reset recovery");$finish;
    end
    initial begin #10000;$fatal(1,"mux timeout");end
endmodule
