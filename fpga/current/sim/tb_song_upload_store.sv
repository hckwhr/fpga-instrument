`timescale 1ns/1ps
module tb_song_upload_store;
    reg clk=0;
    always #10 clk=~clk;
    reg reset_n=0, command_valid=0, response_ready=0, playback_busy=0;
    reg [1:0] command=0;
    reg [9:0] request_length=0;
    reg [23:0] request_end_tick=0;
    reg [7:0] request_melody_count=0;
    reg [15:0] request_crc=0;
    reg [8:0] request_index=0, score_index=0;
    reg [63:0] request_word=0;
    wire command_ready, response_valid, score_valid, published, staging, expired;
    wire [3:0] response_code;
    wire [9:0] response_count, score_length;
    wire [23:0] score_end_tick;
    wire [7:0] score_melody_count;
    wire [15:0] score_crc;
    wire [63:0] score_data;
    song_upload_store #(.IDLE_TIMEOUT_CYCLES(40000)) dut (.*);
    reg [63:0] words[0:511], saved[0:511];
    integer i, cases=0, publications=0;
    reg saved_valid=0;
    reg [9:0] saved_length=0;
    reg [23:0] saved_end=0;
    reg [7:0] saved_melody=0;
    reg [15:0] saved_crc=0;
    always @(posedge clk) if (published) publications<=publications+1;

    task automatic issue(input [1:0] op);
        integer timeout;
        begin
            timeout=0;
            while (!command_ready) begin @(negedge clk); timeout++; if(timeout>25000) $fatal(1,"command readiness timeout"); end
            @(negedge clk); command=op; command_valid=1;
            @(negedge clk); command_valid=0;
        end
    endtask
    task automatic response(input [3:0] expected);
        integer timeout;
        reg [9:0] count;
        begin
            timeout=0;
            while (!response_valid) begin @(negedge clk); timeout++; if(timeout>25000) $fatal(1,"response timeout"); end
            if(response_code!==expected) $fatal(1,"op %d response got %d expected %d at %t",command,response_code,expected,$time);
            count=response_count;
            repeat(4) begin @(negedge clk); if(!response_valid || response_code!==expected || response_count!==count || command_ready) $fatal(1,"response changed under backpressure"); end
            response_ready=1; @(negedge clk); response_ready=0;
        end
    endtask
    task automatic verify_saved;
        integer index;
        begin
            if(score_valid!==saved_valid || score_length!==saved_length || score_end_tick!==saved_end ||
                score_melody_count!==saved_melody || score_crc!==saved_crc) $fatal(1,"published metadata changed unexpectedly");
            if(saved_valid) for(index=0;index<saved_length;index++) begin
                @(negedge clk); score_index=index;
                @(negedge clk); if(score_data!==saved[index]) $fatal(1,"published RAM mismatch at %d",index);
            end
        end
    endtask
    task automatic check_vector(input string name,input [9:0] n,input [23:0] end_tick,input [7:0] melody,input [15:0] crc,input bit valid);
        integer index, old_publications;
        begin
            $readmemh({"sim/upload_vectors/",name,".hex"},words,0,n-1);
            request_length=n; request_end_tick=end_tick; request_melody_count=melody; request_crc=crc;
            old_publications=publications;
            issue(0); response(0);
            // BEGIN and every DATA leave the old public metadata/bank intact.
            for(index=0;index<n;index++) begin
                request_index=index; request_word=words[index]; issue(1); response(0);
                if(response_count!==index+1) $fatal(1,"DATA ACK count mismatch");
            end
            verify_saved();
            issue(2); response(valid ? 0 : 4);
            if(valid) begin
                saved_valid=1; saved_length=n; saved_end=end_tick; saved_melody=melody; saved_crc=crc;
                for(index=0;index<n;index++) saved[index]=words[index];
                if(publications!=old_publications+1 || staging) $fatal(1,"commit did not publish exactly once");
            end else begin
                if(publications!=old_publications || !staging) $fatal(1,"invalid score published");
                issue(3); response(0);
            end
            verify_saved(); cases++;
            $display("VECTOR %s valid=%d PASS",name,valid);
        end
    endtask
    initial begin
        repeat(5) @(negedge clk); reset_n=1;
        `include "upload_vectors/cases.vh"
        // Invalid capacity, incomplete commit, wrong and duplicate DATA offset.
        request_length=0; issue(0); response(2);
        request_length=10'd513; issue(0); response(2);
        request_length=3; issue(0); response(2);
        request_length=2; request_end_tick=2; request_melody_count=1;
        issue(0); response(0); issue(0); response(5);
        issue(2); response(4);
        request_index=1; issue(1); response(3);
        request_index=0; issue(1); response(0); issue(1); response(3);
        issue(3); response(0); issue(3); response(0); verify_saved();
        issue(1); response(1); issue(2); response(1);
        // Deadline expires only staging, never the published score.
        issue(0); response(0);
        repeat(40010) @(negedge clk);
        if(staging) $fatal(1,"staging timeout failed");
        issue(1); response(1); verify_saved();
        // Valid upload with playback lock arriving DURING validation.
        $readmemh("sim/upload_vectors/timeline.hex",words,0,3);
        request_length=saved_length; request_end_tick=saved_end;
        request_melody_count=saved_melody; request_crc=saved_crc;
        issue(0); response(0);
        for(i=0;i<saved_length;i++) begin request_index=i; request_word=words[i]; issue(1); response(0); end
        playback_busy=1; issue(2); response(5); verify_saved();
        playback_busy=0; issue(2); repeat(20) @(negedge clk); playback_busy=1;
        response(5); verify_saved();
        playback_busy=0; issue(2); response(0);
        issue(2); response(1); // wire-layer replay must not call the backend twice
        // Reset during a COMMIT cannot publish the interrupted scan.
        issue(0); response(0);
        for(i=0;i<saved_length;i++) begin request_index=i; request_word=words[i]; issue(1); response(0); end
        issue(2); repeat(8) @(negedge clk); reset_n=0;
        repeat(3) @(negedge clk); reset_n=1;
        repeat(500) @(negedge clk);
        if(score_valid || staging || response_valid || !command_ready) $fatal(1,"reset did not clear transaction validity");
        $display("PASS: song upload store %0d ABI/CRC vectors, double-buffer publication, backpressure, capacity, offset, abort, timeout, playback lock and reset",cases);
        $finish;
    end
    initial begin #100000000; $fatal(1,"global timeout"); end
endmodule
