`timescale 1ns/1ps
module tb_song_upload_frame_rx;
    reg clk=0, reset_n=0, rx_valid=0, rx_error=0, frame_ready=0;
    reg [7:0] rx_data=0, frame_index=0;
    wire rx_ready, frame_valid, error_valid;
    wire [7:0] frame_length, frame_byte;
    wire [1:0] error_code;
    localparam TIMEOUT_CYCLES=100;
    song_upload_frame_rx #(.TIMEOUT_CYCLES(TIMEOUT_CYCLES)) dut(.*);
    wire ref_rx_ready,ref_frame_valid,ref_error_valid;
    wire [7:0] ref_frame_length,ref_frame_byte;
    wire [1:0] ref_error_code;
    // Keep the frozen asynchronous implementation unchanged. Its CRC clock
    // pauses only on the new RAM-fetch edges; all receive/release edges match.
    reg ref_clk=0;
    always @(posedge clk)
        if(!(reference_rx.state==1 && dut.state==5)) ref_clk=1;
    always @(negedge clk) ref_clk=0;
    stage51_song_upload_frame_rx #(.TIMEOUT_CYCLES(TIMEOUT_CYCLES)) reference_rx(
        .clk(ref_clk),.reset_n(reset_n),.rx_valid(rx_valid),.rx_error(rx_error),.rx_data(rx_data),
        .rx_ready(ref_rx_ready),.frame_valid(ref_frame_valid),.frame_ready(frame_ready),
        .frame_length(ref_frame_length),.frame_index(frame_index),.frame_byte(ref_frame_byte),
        .error_valid(ref_error_valid),.error_code(ref_error_code));
    reg [7:0] ref_byte_q;
    reg payload_read;
    always @(posedge clk)begin
        ref_byte_q=ref_frame_byte;
        payload_read=dut.state==3;
        #1;
        if({rx_ready,frame_valid,error_valid,frame_length,error_code} !==
           {ref_rx_ready,ref_frame_valid,ref_error_valid,ref_frame_length,ref_error_code})
            $fatal(1,"Receiver differs from frozen stage51 with explicit CRC-fetch latency");
        if(frame_valid && payload_read && frame_byte!==ref_byte_q)
            $fatal(1,"Receiver payload differs from frozen stage51");
    end
    always #5 clk=~clk;
    integer errors=0, frames=0, errors_seen=0, i;
    string long_body, long_line, f_line;
    function automatic string add_crc(input string body);
        reg [15:0] crc;
        integer j,b;
        begin
            crc=16'hffff;
            for(j=0;j<body.len();j=j+1) begin
                crc=crc^{body[j],8'd0};
                for(b=0;b<8;b=b+1) crc=crc[15]?(crc<<1)^16'h1021:crc<<1;
            end
            add_crc=$sformatf("%s,%04X",body,crc);
            add_crc=add_crc.toupper();
        end
    endfunction
    // Physical UART has no backpressure: exercise bytes received while busy.
    task automatic raw_byte(input [7:0] value);
        begin
            @(negedge clk); rx_data=value; rx_valid=1;
            @(negedge clk); rx_valid=0;
        end
    endtask
    task automatic send_byte(input [7:0] value);
        begin
            while(!rx_ready) @(negedge clk);
            @(negedge clk); rx_data=value; rx_valid=1;
            @(negedge clk); rx_valid=0;
        end
    endtask
    task automatic send_text(input string text);
        integer k; begin for(k=0;k<text.len();k=k+1) send_byte(text[k]); end
    endtask
    task automatic expect_error(input [1:0] expected);
        integer timeout; begin timeout=0;
            while(!error_valid) begin @(negedge clk); timeout=timeout+1; if(timeout>1000)$fatal(1,"missing error"); end
            if(error_code!==expected)$fatal(1,"wrong error %d expected %d",error_code,expected);
            errors_seen=errors_seen+1;
        end
    endtask
    task automatic accept_and_check(input string expected);
        integer timeout,k; begin timeout=0;
            while(!frame_valid) begin @(negedge clk); timeout=timeout+1; if(timeout>1000)$fatal(1,"missing valid frame state=%d len=%d body=%d crc=%h expected=%h err=%d",dut.state,dut.line_length,dut.body_length,dut.crc,dut.expected_crc,error_code); end
            if(frame_length!==expected.len())$fatal(1,"length mismatch %d/%d",frame_length,expected.len());
            // Hold frame under backpressure and verify every byte repeatedly.
            for(k=0;k<expected.len();k=k+1) begin
                @(negedge clk); frame_index=k;
                @(posedge clk); #2; if(frame_byte!==expected[k])$fatal(1,"byte %d mismatch",k);
            end
            repeat(4) begin
                @(negedge clk); frame_index=3;
                @(posedge clk); #2; if(!frame_valid || frame_byte!==expected[3])$fatal(1,"frame changed under backpressure");
            end
            @(negedge clk);
            frames=frames+1; frame_ready=1; @(negedge clk); frame_ready=0;
        end
    endtask
    initial begin
        #21; reset_n=1;
        send_text("SONG2,0123456789ABCDEF,0,CAPS,DC34\n");
        accept_and_check("SONG2,0123456789ABCDEF,0,CAPS,DC34");
        send_text({"SONG2,0123456789ABCDEF,0,CAPS,DC34",8'd13,8'd10});
        accept_and_check("SONG2,0123456789ABCDEF,0,CAPS,DC34");
        send_text("SONG2,0123456789ABCDEF,0,CAPS,DC35\n"); expect_error(3);
        send_text("SONG2,0123456789ABCDEF,0,CAPS,DC3Z\n"); expect_error(3);
        send_text("SONG2,0123456789ABCDEF,0,CAPS\n"); expect_error(3);
        send_text({"SONG2,0123456789ABCDEF,0,CAPS,DC34",8'd13,"X",8'd10}); expect_error(2);
        send_text({{"X"}, {256{8'h41}}, {"\n"}}); expect_error(2);
        send_text("\n"); expect_error(2);
        // Split one frame at every byte boundary is covered by send_byte's
        // one-cycle valid pulse; a held output is covered above.
        send_text("SONG2,0123456789ABCDEF,0,CAPS,DC34\n"); accept_and_check("SONG2,0123456789ABCDEF,0,CAPS,DC34");
        // CRC nibble F is legal. Maximum LF frame: 250 body + 5 suffix + LF.
        f_line=add_crc("F");
        send_text({f_line,8'd10}); accept_and_check(f_line);
        long_body="";
        repeat(250) long_body={long_body,"A"};
        long_line=add_crc(long_body);
        send_text({long_line,8'd10}); accept_and_check(long_line);
        // The same 255-byte line plus CRLF exceeds the 256-byte wire bound.
        send_text({long_line,8'd13,8'd10}); expect_error(2);
        send_text("SONG2,partial"); expect_error(1);
        send_text("suffix\n"); expect_error(2);
        send_text("bad");
        @(negedge clk); rx_error=1;
        @(negedge clk); rx_error=0;
        send_text("suffix\n"); expect_error(2);
        // Busy traffic cannot modify the held frame; incomplete suffix drains.
        send_text("SONG2,0123456789ABCDEF,0,CAPS,DC34\n");
        wait(frame_valid);
        raw_byte("X");
        accept_and_check("SONG2,0123456789ABCDEF,0,CAPS,DC34");
        send_text("suffix\n"); expect_error(2);
        // A LF received on the exact release edge completes the busy suffix.
        send_text("SONG2,0123456789ABCDEF,0,CAPS,DC34\n");
        wait(frame_valid); raw_byte("X");
        @(negedge clk); frame_ready=1; rx_valid=1; rx_data=10;
        @(negedge clk); frame_ready=0; rx_valid=0;
        if(!rx_ready || dut.state!=0) $fatal(1,"release LF failed to resync");
        // On a bad-CRC release edge, a new partial line must also be drained.
        send_text("SONG2,0123456789ABCDEF,0,CAPS,DC35\n");
        while(dut.state!=2) @(negedge clk);
        rx_valid=1; rx_data="X";
        @(negedge clk); rx_valid=0; expect_error(3);
        if(dut.state!=4) $fatal(1,"CRC release accepted a truncated suffix");
        send_text("suffix\n"); expect_error(2);
        send_text("SONG2,0123456789ABCDEF,0,CAPS,DC34\n"); accept_and_check("SONG2,0123456789ABCDEF,0,CAPS,DC34");
        if(frames!=7 || errors_seen!=13)$fatal(1,"counts frames=%d errors=%d",frames,errors_seen);
        // Every legal body length, alternating LF/CRLF where the wire bound
        // permits it. The tail must belong to this frame, never its predecessor.
        long_body="";
        for(i=1;i<=250;i=i+1)begin
            long_body={long_body,byte'(33+(i*17)%58)};
            long_line=add_crc(long_body);
            if(i<250 && i%2==0)send_text({long_line,8'd13,8'd10});
            else send_text({long_line,8'd10});
            accept_and_check(long_line);
        end
        $display("PASS: frozen-stage51 comparison with explicit RAM-fetch latency, all 250 body lengths, LF/CRLF, FCRC, timeout, UART error, busy suffix and release-edge recovery");
        $finish;
    end
    initial begin #5000000; $fatal(1,"timeout"); end
endmodule
