`timescale 1ns/1ps
// Independent 255-row score with rests and a >16-bit long note.
module tb_song_transport;
    reg clk=0,reset_n=0,strobe=0,enable=0;
    reg [1:0] tempo=1;
    reg [11:0] beats=4095,gates=4089;
    wire [23:0] duration_samples,gate_samples;
    wire [7:0] index,position;
    wire valid,on,done,flush;
    wire [15:0] id;
    wire [3:0] note;
    integer i,t,ons=0,offs=0,row_start=7,row=0,off_due;
    reg [15:0] active_id;
    reg held=0;
    wire rest=(index%4==0 && index!=100);
    wire [23:0] duration=(index==100)?24'd70000:24'd20;
    song_timing timing(.clk(clk),.tempo_select(tempo),.duration_ticks(beats),.gate_ticks(gates),
        .duration_samples(duration_samples),.gate_samples(gate_samples));
    song_player #(.QUARTER_SAMPLES(32)) dut(
        .clk(clk),.reset_n(reset_n),.sample_strobe(strobe),.enable(enable),
        .stop_pressed(1'b0),.replay_pressed(1'b0),.remote_start(1'b0),.remote_stop(1'b0),
        .score_index(index),.score_length(8'd255),.score_note(rest?4'd15:4'd7),
        .score_octave(2'd1),.score_force(7'd96),.score_duration(duration),
        .score_gate(rest?24'd0:(index==100)?24'd69000:24'd12),
        .note_index(position),.done(done),.event_ready(1'b1),.event_flush(flush),
        .event_valid(valid),.event_on(on),.event_id(id),.event_note(note),.event_octave(),.event_force());
    always #5 clk=~clk;
    always @(posedge clk) if(reset_n && valid && !flush) begin
        if(on) begin
            if(held || position%4==0 && position!=100 || note!=7 || t!=row_start)
                $fatal(1,"long score ON mismatch row=%0d t=%0d expected=%0d",position,t,row_start);
            held=1;active_id=id;ons=ons+1;off_due=t+((position==100)?69000:12);
        end else begin
            if(!held || id!==active_id || t!=off_due)$fatal(1,"gate timing/identity mismatch");
            held=0;offs=offs+1;
        end
    end
    task slot;begin
        @(negedge clk);strobe=1;@(negedge clk);strobe=0;repeat(4)@(negedge clk);
    end endtask
    initial begin
        for(i=0;i<4;i=i+1)begin
            tempo=i;repeat(4)@(negedge clk);
            if(duration_samples!=4095*((i==0)?375:(i==1)?300:(i==2)?250:200) ||
               gate_samples!=4089*((i==0)?375:(i==1)?300:(i==2)?250:200))
                $fatal(1,"tempo/max duration conversion mismatch");
        end
        reset_n=1;enable=1;repeat(3)@(negedge clk);
        for(t=0;t<75100;t=t+1)begin
            if(row<255 && t==row_start+((row==100)?70000:20))begin
                row_start=t;row=row+1;
            end
            slot();
            if(done !== (t>=75087))$fatal(1,"end timing/index overflow t=%0d",t);
        end
        if(held || ons!=192 || offs!=192 || position!=254)$fatal(1,"long score count/end");
        $display("PASS: all four tempos, max 4095 ticks, 255 rows, 63 rests, 70000-sample long note, independent gates and final OFF");
        $finish;
    end
    initial begin #6000000;$fatal(1,"transport timeout");end
endmodule
