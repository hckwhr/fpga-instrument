`timescale 1ns/1ps
module tb_rhythm_key_gate;
    reg clk=0,reset_n=0,ce=0,valid=0,set=0,blocked=0,busy=0;
    reg [71:0] payload=0;
    reg [11:0] keys=0;
    wire guard,active;wire [11:0] play,guide;wire [71:0] status;wire [1:0] result;
    always #5 clk=~clk;
    always @(negedge clk)ce<=!ce;
    rhythm_key_gate #(.CE_ENABLE(1),.LEASE_STEPS(24)) dut(
        .clk(clk),.reset_n(reset_n),.clock_enable(ce),.command_valid(valid),
        .command_set(set),.command_payload(payload),.blocked(blocked),.keyboard_busy(busy),
        .physical_keys(keys),.guard(guard),.active(active),.play_keys(play),.guide_keys(guide),.status(status),.result(result));
    task step;
        begin @(posedge clk);while(!ce)@(posedge clk);#1;end
    endtask
    task command(input bit write,input bit enable,input [31:0] cue,input [11:0] mask);
        begin @(negedge clk);#1;valid=1;set=write;payload={27'd0,enable,cue,mask};step();@(negedge clk);#1;valid=0;end
    endtask
    task key(input [11:0] value);
        begin @(negedge clk);#1;keys=value;step();end
    endtask
    initial begin
        #12;reset_n=1;step();
        key(1);if(play!=1)$fatal(1,"normal keyboard changed");busy=1;
        command(1,1,1,3);if(result!=2||guard)$fatal(1,"held entry accepted");
        key(0);busy=0;command(1,1,1,3);
        if(!guard||!active||guide!=3||play!=0)$fatal(1,"cue arm");
        key(4);if(play!=0||status[23:12]!=0)$fatal(1,"wrong key sounded");
        key(0);key(1);if(play!=1||guide!=2)$fatal(1,"correct key not accepted");
        key(0);command(0,0,0,0);if(status[23:12]!=1)$fatal(1,"fast tap lost");
        command(1,1,1,3);if(status[23:12]!=1)$fatal(1,"duplicate replay");
        command(1,1,1,7);if(result!=3||guide!=2)$fatal(1,"mutated cue accepted");
        key(2);if(play!=2||guide!=0||status[23:12]!=3)$fatal(1,"chord completion");
        command(1,1,2,2);step();if(status[23:12]!=0||guide!=2)$fatal(1,"held repeated note accepted");
        key(0);key(2);if(status[23:12]!=2)$fatal(1,"repeat after release missed");
        command(1,0,0,0);if(guard||play!=0||guide!=0)$fatal(1,"stop leaked held key");
        step();if(play!=0)$fatal(1,"held key resumed after stop");key(0);key(2);if(play!=2)$fatal(1,"normal route not restored");
        key(0);command(1,1,3,1);key(1);blocked=1;step();
        if(active||!guard||play!=0||guide!=0)$fatal(1,"blocked exit unsafe");
        blocked=0;command(1,1,4,1);if(result!=2||active)$fatal(1,"guard restarted without stop");
        command(1,0,0,0);key(0);command(1,1,4,1);
        repeat(26)step();if(active||!guard||guide!=0||play!=0)$fatal(1,"disconnect lease");
        command(1,1,5,1);if(result!=2||active)$fatal(1,"expired restart");
        reset_n=0;#1;if(guard||play!=0)$fatal(1,"reset state");
        $display("PASS: rhythm gate CE, wrong key silence, chord, sticky tap, duplicate/stale held, stop inhibition, blocked/lease guard");$finish;
    end
    initial begin #100000;$fatal(1,"timeout");end
endmodule
