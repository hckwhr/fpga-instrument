`timescale 1ns/1ps
module tb_song_upload_link # (parameter WIRE_MODE=0);
    localparam CPB=8, REPLAY_CYCLES=400000, STORE_CYCLES=800000;
    reg clk=0,reset_n=0,rx=1,playback_busy=0;
    always #5 clk=~clk;
    reg [7:0] rx_data=0;
    reg rx_valid=0,rx_error=0;
    wire rx_ready,tx,tx_valid;
    wire [7:0] tx_data;
    reg [8:0] score_index=0;
    wire [63:0] score_data;
    wire score_valid, published, staging,link_fault;
    wire [9:0] score_length;
    wire [23:0] score_end_tick;
    wire [7:0] score_melody_count;
    wire [15:0] score_crc;
    reg [3:0] stall_counter=0;
    wire tx_ready=stall_counter[1:0]==2'd3;
    always @(posedge clk) stall_counter<=stall_counter+1'b1;
    integer writes=0,commits=0,received=0,checked=0,cases=0,bit_num;
    reg [7:0] out_bytes[0:32767];
    reg [7:0] decoded;
    reg [63:0] ode[0:131], timeline[0:3];
    generate if(WIRE_MODE==0) begin : bytes_mode
        song_upload_link #(.FRAME_TIMEOUT_CYCLES(10000),.STORE_TIMEOUT_CYCLES(STORE_CYCLES),.REPLAY_HOLD_CYCLES(REPLAY_CYCLES)) dut (
            .clk(clk),.reset_n(reset_n),.rx_data(rx_data),.rx_valid(rx_valid),.rx_error(rx_error),.rx_ready(rx_ready),
            .tx_data(tx_data),.tx_valid(tx_valid),.tx_ready(tx_ready),.playback_busy(playback_busy),
            .score_index(score_index),.score_data(score_data),.score_valid(score_valid),.score_length(score_length),
            .score_end_tick(score_end_tick),.score_melody_count(score_melody_count),.score_crc(score_crc),
            .published(published),.staging(staging),.link_fault(link_fault),
            .control_valid(),.control_ready(1'b0),.control_command(),.control_tempo(),
            .control_response_valid(1'b0),.control_response_ready(),.control_response_code(3'd0),.control_status(54'd0));
        wire ref_done,ref_valid;
        wire [7:0] ref_index;
        wire [63:0] ref_sid;
        wire [15:0] ref_sequence,ref_crc;
        wire [2:0] ref_operation;
        wire [23:0] ref_arg0,ref_arg1,ref_arg2,ref_arg3;
        wire [511:0] ref_payload;
        // Frozen parser advances on consumption edges only. Its own index
        // selects the immutable request, independently of the new read port.
        reg ref_clk=0;
        always @(posedge clk)
            if(!(dut.parser.running && dut.parser.read_wait && !dut.parser.finish_pending)) ref_clk=1;
        always @(negedge clk) ref_clk=0;
        wire [7:0] ref_byte=ref_index<dut.frame_length ? dut.receiver.line_mem[ref_index] : 8'd0;
        stage51_song_upload_parse reference_parser(
            .clk(ref_clk),.reset_n(reset_n),.start(dut.state==0 && dut.frame_valid),
            .frame_length(dut.frame_length),.frame_index(ref_index),.frame_byte(ref_byte),
            .done(ref_done),.valid(ref_valid),.session_id(ref_sid),.sequence_id(ref_sequence),
            .operation(ref_operation),.arg0(ref_arg0),.arg1(ref_arg1),.arg2(ref_arg2),.arg3(ref_arg3),
            .song_crc(ref_crc),.payload(ref_payload));
        always @(posedge clk)begin
            #1;
            if({dut.parse_index,dut.parse_done,dut.parse_valid,dut.sid,dut.seq,dut.op,
                dut.a0,dut.a1,dut.a2,dut.a3,dut.scrc,dut.payload,dut.parser.number} !==
               {ref_index,ref_done,ref_valid,ref_sid,ref_sequence,ref_operation,
                ref_arg0,ref_arg1,ref_arg2,ref_arg3,ref_crc,ref_payload,reference_parser.number})
                $fatal(1,"Parser differs from frozen stage51 decimal arithmetic");
        end
        always @(posedge clk) if(reset_n) begin
            if(dut.store.write_word) writes=writes+1;
            if(published) commits=commits+1;
            if(tx_valid && tx_ready) begin out_bytes[received]=tx_data; received=received+1; end
        end
        reg held=0;
        reg [7:0] held_byte;
        always @(posedge clk) begin
            if(held && (!tx_valid || tx_data!==held_byte)) $fatal(1,"TX changed under stall");
            held<=reset_n && tx_valid && !tx_ready; held_byte<=tx_data;
        end
    end else begin : uart_mode
        song_upload_uart #(.CLKS_PER_BIT(CPB),.FRAME_TIMEOUT_CYCLES(10000),.STORE_TIMEOUT_CYCLES(STORE_CYCLES),.REPLAY_HOLD_CYCLES(REPLAY_CYCLES)) dut (
            .clk(clk),.reset_n(reset_n),.rx(rx),.tx(tx),.playback_busy(playback_busy),
            .score_index(score_index),.score_data(score_data),.score_valid(score_valid),.score_length(score_length),
            .score_end_tick(score_end_tick),.score_melody_count(score_melody_count),.score_crc(score_crc),
            .published(published),.staging(staging),.link_fault(link_fault),
            .control_valid(),.control_ready(1'b0),.control_command(),.control_tempo(),
            .control_response_valid(1'b0),.control_response_ready(),.control_response_code(3'd0),.control_status(54'd0));
        always @(posedge clk) if(reset_n) begin
            if(dut.link.store.write_word) writes=writes+1;
            if(published) commits=commits+1;
        end
        initial forever begin
            @(negedge tx); #(CPB*15);
            for(bit_num=0;bit_num<8;bit_num=bit_num+1) begin decoded[bit_num]=tx; #(CPB*10); end
            if(tx!==1'b1) $fatal(1,"UART stop bit");
            out_bytes[received]=decoded; received=received+1;
        end
    end endgenerate
    task automatic send_byte(input [7:0] value);
        integer b;
        begin
            if(WIRE_MODE) begin
                @(negedge clk); rx=0; repeat(CPB) @(negedge clk);
                for(b=0;b<8;b=b+1) begin rx=value[b]; repeat(CPB) @(negedge clk); end
                rx=1; repeat(CPB) @(negedge clk);
            end else begin
                @(negedge clk); rx_data=value; rx_valid=1;
                @(negedge clk); rx_valid=0;
            end
        end
    endtask
    task automatic exchange(input string request,input string response,input integer expected_writes,input integer expected_commits);
        integer i, timeout;
        begin
            cases=cases+1;
            for(i=0;i<request.len();i=i+1) send_byte(request[i]);
            timeout=0;
            if(response.len()==0) repeat(1200) @(negedge clk);
            else while(received<checked+response.len()) begin
                @(negedge clk); timeout=timeout+1;
                if(timeout>100000) $fatal(1,"missing reply case %d request=%s got=%d expected=%s",cases,request,received-checked,response);
            end
            for(i=0;i<response.len();i=i+1)
                if(out_bytes[checked+i]!==response[i]) $fatal(1,"reply case %d offset %d got %h expected %h request=%s",cases,i,out_bytes[checked+i],response[i],request);
            checked=checked+response.len();
            repeat(200) @(negedge clk);
            if(received!=checked) $fatal(1,"unsolicited response case %d",cases);
            if(writes!=expected_writes || commits!=expected_commits) $fatal(1,"side effects case %d writes %d/%d commits %d/%d",cases,writes,expected_writes,commits,expected_commits);
            if(link_fault) $fatal(1,"link fault");
        end
    endtask
    task automatic verify_ode;
        integer i;
        begin
            if(!score_valid || score_length!=132 || score_end_tick!=3072 || score_melody_count!=30) $fatal(1,"Ode metadata mismatch");
            for(i=0;i<132;i=i+1) begin @(negedge clk); score_index=i; @(negedge clk); if(score_data!==ode[i]) $fatal(1,"Ode RAM %d",i); end
        end
    endtask
    task automatic verify_timeline;
        integer i;
        begin
            if(!score_valid || score_length!=4 || score_end_tick!=10 || score_melody_count!=2 || score_crc!=16'h8281) $fatal(1,"timeline metadata mismatch");
            for(i=0;i<4;i=i+1) begin @(negedge clk); score_index=i; @(negedge clk); if(score_data!==timeline[i]) $fatal(1,"timeline RAM %d",i); end
        end
    endtask
    initial begin
        $readmemh("sim/link_vectors/ode.hex",ode);
        $readmemh("sim/upload_vectors/timeline.hex",timeline);
        repeat(5) @(negedge clk); reset_n=1;
        `include "link_vectors/cases.vh"
        $display("PASS: SONG2 host frames to real RTL RAM, mode=%d cases=%d writes=%d commits=%d; exact ACK/FCRC, duplicate and CRC-collision conflict, full Ode and replacement",WIRE_MODE,cases,writes,commits);
        $finish;
    end
    initial begin #200000000; $fatal(1,"global timeout"); end
endmodule

module tb_song_upload_uart;
    tb_song_upload_link #(.WIRE_MODE(1)) test_instance();
endmodule
