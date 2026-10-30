`timescale 1ns/1ps
`default_nettype none
module tb_song_score_rom;
    reg [7:0] index=0;
    wire [3:0] note;
    wire [11:0] duration_ticks, gate_ticks;
    wire [7:0] length;
    integer i;
    reg [3:0] expected_note [0:41];
    song_score_twinkle dut(
        .index(index), .note(note), .duration_ticks(duration_ticks), .gate_ticks(gate_ticks), .length(length),
        .octave(), .force_level());
    initial begin
        {expected_note[0],expected_note[1],expected_note[2],expected_note[3],expected_note[4],expected_note[5],expected_note[6]}=28'h0077997;
        {expected_note[7],expected_note[8],expected_note[9],expected_note[10],expected_note[11],expected_note[12],expected_note[13]}=28'h5544220;
        {expected_note[14],expected_note[15],expected_note[16],expected_note[17],expected_note[18],expected_note[19],expected_note[20]}=28'h7755442;
        {expected_note[21],expected_note[22],expected_note[23],expected_note[24],expected_note[25],expected_note[26],expected_note[27]}=28'h7755442;
        {expected_note[28],expected_note[29],expected_note[30],expected_note[31],expected_note[32],expected_note[33],expected_note[34]}=28'h0077997;
        {expected_note[35],expected_note[36],expected_note[37],expected_note[38],expected_note[39],expected_note[40],expected_note[41]}=28'h5544220;
        #1; if(length!==8'd85) $fatal(1,"score length is %0d",length);
        for(i=0;i<42;i=i+1) begin
            index=i;
            #1;
            if(note!==expected_note[i]) $fatal(1,"note %0d mismatch",i);
            if(duration_ticks!==((i%7==6)?12'd192:12'd96) || gate_ticks!=duration_ticks-6) $fatal(1,"duration %0d mismatch",i);
            index=i+43; #1;
            if(note!==expected_note[i] || duration_ticks!==((i%7==6)?12'd192:12'd96)) $fatal(1,"second verse mismatch");
        end
        index=42; #1;
        if(note!==15 || duration_ticks!==192 || gate_ticks!==0) $fatal(1,"missing two-beat rest");
        index=85; #1;
        if(note!==15 || duration_ticks!==0 || gate_ticks!==0) $fatal(1,"out-of-range score is not safe");
        $display("PASS: 85 rows, two verses, explicit rest, independent gate and safe end");
        $finish;
    end
endmodule
`default_nettype wire
