`timescale 1ns/1ps
module tb_keyboard_light_status;
    reg clk=0, reset_n=0;
    reg [67:0] payload=0;
    wire [11:0] notes;
    integer root,keys,poly,keymap,k,base,n;
    reg [11:0] expected;
    always #15 clk=~clk;
    keyboard_light_status dut(.clk(clk),.reset_n(reset_n),
        .status_payload(payload),.held_notes(notes));
    task check;
        input [11:0] wanted;
        begin
            @(posedge clk); #1;
            if(notes!==wanted) $fatal(1,"payload %h: notes %h expected %h",payload,notes,wanted);
            @(negedge clk);
        end
    endtask
    initial begin
        #1; reset_n=0; check(0); reset_n=1;
        for(root=0;root<12;root=root+1)
        for(keys=0;keys<8;keys=keys+1)
        for(poly=0;poly<2;poly=poly+1)
        for(keymap=0;keymap<2;keymap=keymap+1) begin
            payload=0; payload[16:13]=root; payload[2:0]=keys;
            payload[5]=keymap; payload[27:26]=poly ? 2'b11 : 2'b00;
            expected=0;
            for(k=0;k<3;k=k+1) if((keys & (1<<k))!=0) begin
                if(keymap==0) expected[(root+2*k)%12]=1;
                else begin
                    base=poly ? (k==0 ? 0 : k==1 ? 5 : 7) :
                        ((keys&4)!=0 ? 7 : (keys&2)!=0 ? 5 : 0);
                    expected[(root+base)%12]=1;
                    expected[(root+base+4)%12]=1;
                    expected[(root+base+7)%12]=1;
                end
            end
            check(expected);
        end
        payload[23]=1; check(0);
        // Settings overloads held bit 11 with the piano-layout selection.
        // No held mask (including stale song bits) may light a physical key.
        for(n=0;n<4096;n=n+1) begin payload[67:56]=n; check(0); end
        payload=0;payload[49]=1;payload[53:51]=7;
        for(n=0;n<4096;n=n+1) begin payload[67:56]=n; check(n); end
        payload=0;payload[16:13]=15;payload[2:0]=7;check(0);
        reset_n=0;check(0);
        $display("PASS: all 384 manual note/key modes and 4096 song masks, settings/reset");
        $finish;
    end
endmodule
