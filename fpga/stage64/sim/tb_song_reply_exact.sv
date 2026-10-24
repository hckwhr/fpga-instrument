`timescale 1ns/1ps
module reply_exact_case #(parameter CONTROL=0)(output reg finished=0);
    reg clk=0,reset_n=0,start=0;
    always #5 clk=~clk;
    reg [63:0] session_id=64'h123456789ABCDEF0;
    reg [15:0] sequence_id=0,song_crc=0;
    reg [2:0] operation=0;
    reg [3:0] error_code=0;
    reg [9:0] count=0;
    reg [53:0] control_status=0;
    wire [7:0] tx_data,old_data;
    wire tx_valid,done,old_valid,old_done;
    reg [15:0] rng=16'hACE1;
    always @(posedge clk) rng<={rng[14:0],rng[15]^rng[13]^rng[12]^rng[10]};
    wire tx_ready=rng[0] | rng[4];
    song_upload_reply #(.CONTROL_ENABLE(CONTROL)) dut(.*);
    stage54c_song_upload_reply #(.CONTROL_ENABLE(CONTROL)) reference(
        .clk(clk),.reset_n(reset_n),.start(start),.session_id(session_id),.sequence_id(sequence_id),
        .operation(operation),.error_code(error_code),.count(count),.song_crc(song_crc),
        .control_status(control_status),.tx_data(old_data),.tx_valid(old_valid),.tx_ready(tx_ready),.done(old_done));
    byte actual[0:255],expected[0:255];
    integer ac=0,ec=0,cases=0;
    reg done_seen=0,old_done_seen=0,held=0;
    reg [7:0] held_token,held_address;
    reg [63:0] held_sid;
    reg [15:0] held_crc;
    reg [19:0] held_bcd;
    always @(posedge clk) begin
        if(reset_n) begin
            if(held && (!tx_valid || dut.token!==held_token || dut.crc!==held_crc || dut.bcd!==held_bcd ||
                dut.text_address!==held_address || dut.sid!==held_sid))
                $fatal(1,"Reply token/CRC/digits changed during stall");
            if(tx_valid && tx_ready) begin actual[ac]=tx_data;ac++;end
            if(old_valid && tx_ready) begin expected[ec]=old_data;ec++;end
            if(done)done_seen=1;
            if(old_done)old_done_seen=1;
        end
        held=reset_n && tx_valid && !tx_ready;
        held_token=dut.token;held_crc=dut.crc;held_bcd=dut.bcd;
        held_address=dut.text_address;held_sid=dut.sid;
    end
    task exchange;
        integer age,j;
        begin
            @(negedge clk);ac=0;ec=0;done_seen=0;old_done_seen=0;start=1;
            @(negedge clk);start=0;
            // Inputs are allowed to change immediately after acceptance.
            sequence_id=~sequence_id;count=~count;control_status=~control_status;
            age=0;
            while(!done_seen || !old_done_seen) begin
                @(negedge clk);age++;
                if(age>1200)$fatal(1,"Reply timeout control=%d case=%d",CONTROL,cases);
            end
            if(ac!=ec || ac==0)$fatal(1,"Reply length mismatch %d/%d",ac,ec);
            for(j=0;j<ec;j++)if(actual[j]!==expected[j])
                $fatal(1,"Reply byte mismatch control=%d case=%d byte=%d actual=%h expected=%h",CONTROL,cases,j,actual[j],expected[j]);
            cases++;
        end
    endtask
    integer v;
    initial begin
        repeat(4)@(negedge clk);reset_n=1;
        // Exhaust every 16-bit decimal sequence, including all digit boundaries.
        for(v=0;v<65536;v++)begin
            sequence_id=v;operation=v[2:0];error_code=v[7:4];count=v[9:0];
            song_crc=v;control_status={v[2:0],v[7:0],v[9:0],v[15:0],v[0],v[15:0]};
            exchange();
        end
        for(v=0;v<1024;v++)begin
            sequence_id=v;operation=2;error_code=0;count=v;exchange();
            sequence_id=v;operation=7;error_code=0;
            control_status={v[2:0],v[7:0],v[9:0],16'hFE01,1'b1,16'h00AF};exchange();
        end
        $display("Reply comparison control=%0d passed %0d transactions",CONTROL,cases);
        finished=1;
    end
endmodule
module tb_song_reply_exact;
    wire a,b;
    reply_exact_case #(.CONTROL(0)) legacy(a);
    reply_exact_case #(.CONTROL(1)) control(b);
    initial begin wait(a && b);$display("PASS: exhaustive 16-bit reply decimals, counts/status, frozen byte sequences and stalled token/CRC stability");$finish;end
    initial begin #2000000000;$fatal(1,"Reply equivalence timeout");end
endmodule
