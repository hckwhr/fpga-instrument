`default_nettype none
// Synthesis-only harness: preserves the sensor and bend paths disabled on today's board.
module performance_expression_probe(
    input wire clk,reset_n,sample_strobe,sensor_enable,frame_valid,
    input wire [9:0] force_raw,x_raw,y_raw,force_zero,x_center,y_center,
    input wire [11:0] force_gain_q12,
    input wire [6:0] manual_force,
    input wire [1:0] manual_vibrato,
    input wire [31:0] target_increment,
    input wire signed [7:0] lfo,
    output wire [6:0] force_value,
    output wire pressure_gate,pressure_trigger,sensor_ready,
    output wire [31:0] expressed_increment
);
    wire signed [7:0] bend;
    wire [7:0] depth;
    performance_controls control(.clk(clk),.reset_n(reset_n),.sample_strobe(sample_strobe),
        .sensor_enable(sensor_enable),.frame_valid(frame_valid),.force_raw(force_raw),.x_raw(x_raw),.y_raw(y_raw),
        .force_zero(force_zero),.x_center(x_center),.y_center(y_center),.force_gain_q12(force_gain_q12),
        .manual_force(manual_force),.manual_vibrato(manual_vibrato),.force_value(force_value),
        .bend(bend),.vibrato_depth(depth),.pressure_gate(pressure_gate),.pressure_trigger(pressure_trigger),.sensor_ready(sensor_ready));
    pitch_expression pitch(.clk(clk),.reset_n(reset_n),.sample_strobe(sample_strobe),.enable(1'b1),
        .active(1'b1),.note_start(1'b0),.target_increment(target_increment),.start_increment(target_increment),
        .start_valid(1'b1),.glide_select(2'd0),.vibrato_depth(depth),.lfo(lfo),.bend(bend),.expressed_increment(expressed_increment));
endmodule
`default_nettype wire
