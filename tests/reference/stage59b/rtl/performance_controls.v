`default_nettype none
// Vendor-independent ADC frame adapter in audio_clk. The eventual MCP3008
// scanner supplies a coherent CH0/1/2 frame through a CDC handshake if needed.
module performance_controls #(parameter integer CE_ENABLE=0,
    parameter integer MANUAL_VIBRATO_FLOOR=0,
    
    parameter integer TIMEOUT_SAMPLES=4800,
    parameter integer JOYSTICK_SPAN=500
)(
    input wire clock_enable,
    
    input wire clk, reset_n, sample_strobe, sensor_enable, frame_valid,
    input wire [9:0] force_raw, x_raw, y_raw, force_zero, x_center, y_center,
    input wire [11:0] force_gain_q12,
    input wire [6:0] manual_force,
    input wire [1:0] manual_vibrato,
    output wire [6:0] force_value,
    output wire signed [7:0] bend,
    output wire [7:0] vibrato_depth,
    output reg pressure_gate, pressure_trigger,
    output wire sensor_ready
);
    reg [12:0] age;
    reg valid;
    reg bend_initialized;
    reg [9:0] filtered_force,filtered_x,filtered_y;
    reg [6:0] smooth_force;
    reg signed [7:0] smooth_bend;
    reg [7:0] smooth_vibrato;
    reg [21:0] force_scaled;
    wire [9:0] force_delta=filtered_force>force_zero?filtered_force-force_zero:10'd0;
    wire [6:0] force_target=(force_scaled[21:12]>10'd127) ? 7'd127 : force_scaled[18:12];
    wire signed [10:0] x_delta=$signed({1'b0,filtered_x})-$signed({1'b0,x_center});
    wire signed [10:0] y_delta=$signed({1'b0,filtered_y})-$signed({1'b0,y_center});
    wire [10:0] y_abs=y_delta[10]?-y_delta:y_delta;
    wire [10:0] x_abs=x_delta[10]?-x_delta:x_delta;
    wire [17:0] x_travel=(x_abs>11'd24)?{(x_abs-11'd24),7'd0}:18'd0;
    wire [17:0] y_travel=(y_abs>11'd48)?{(y_abs-11'd48),7'd0}:18'd0;
    wire [17:0] x_scaled=x_travel/(JOYSTICK_SPAN-24);
    wire [17:0] y_scaled=y_travel/(JOYSTICK_SPAN-48);
    wire signed [8:0] x_magnitude=(x_scaled>=128)?9'sd128:$signed({1'b0,x_scaled[7:0]});
    wire signed [8:0] x_signed=x_delta[10]?-x_magnitude:x_magnitude;
    wire signed [7:0] bend_target=(x_signed>127)?8'sd127:x_signed[7:0];
    wire [7:0] vibrato_target=(y_scaled>=128)?8'd128:y_scaled[7:0];
    wire [7:0] manual_depth=(manual_vibrato==0)?8'd0:(manual_vibrato==1)?8'd32:
        (manual_vibrato==2)?8'd64:8'd128;
    assign sensor_ready=sensor_enable && valid && age<TIMEOUT_SAMPLES;
    assign force_value=sensor_ready?smooth_force:manual_force;
    // Slew the selected destination, not only the sensor branch. Switching
    // source, losing frames, disabling the sensor and manual depth changes
    // must all pass through the same sample-clocked pitch control state.
    wire signed [7:0] selected_bend=sensor_ready?bend_target:8'sd0;
    // V3 presets are a depth floor; a centred joystick must not cancel a
    // deliberate menu selection. Both sources still use the same slew state.
    wire [7:0] sensor_depth=(MANUAL_VIBRATO_FLOOR && manual_depth>vibrato_target)
        ? manual_depth : vibrato_target;
    wire [7:0] selected_vibrato=sensor_ready?sensor_depth:manual_depth;
    // Before any valid sensor frame the reachable bend is exactly zero.
    // Make that invariant explicit so an ADC-disabled board can eliminate
    // downstream bend multipliers. Keep the flag set through timeout/disable
    // so an acquired bend still slews back to center instead of snapping.
    assign bend=bend_initialized?smooth_bend:8'sd0;
    assign vibrato_depth=smooth_vibrato;
    always @(posedge clk) if ((!CE_ENABLE || clock_enable)) force_scaled<=force_delta*force_gain_q12;
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin
            age<=0;valid<=0;bend_initialized<=0;filtered_force<=0;filtered_x<=512;filtered_y<=512;
            smooth_force<=0;smooth_bend<=0;smooth_vibrato<=0;pressure_gate<=0;pressure_trigger<=0;
        end else if ((!CE_ENABLE || clock_enable)) begin
            pressure_trigger<=0;
            if(sensor_ready) bend_initialized<=1;
            if(sample_strobe) begin
                if(smooth_bend<selected_bend) smooth_bend<=smooth_bend+8'sd1;
                else if(smooth_bend>selected_bend) smooth_bend<=smooth_bend-8'sd1;
                if(smooth_vibrato<selected_vibrato) smooth_vibrato<=smooth_vibrato+8'd1;
                else if(smooth_vibrato>selected_vibrato) smooth_vibrato<=smooth_vibrato-8'd1;
            end
            if(!sensor_enable) begin
                valid<=0;age<=0;pressure_gate<=0;smooth_force<=manual_force;
            end
            else begin
                if(frame_valid) begin
                    age<=0;valid<=1;
                    if(!valid || age>=TIMEOUT_SAMPLES) begin
                        filtered_force<=force_raw;filtered_x<=x_raw;filtered_y<=y_raw;
                    end else begin
                        filtered_force<=({2'd0,filtered_force}*12'd3+{2'd0,force_raw})>>2;
                        filtered_x<=({2'd0,filtered_x}*12'd3+{2'd0,x_raw})>>2;
                        filtered_y<=({2'd0,filtered_y}*12'd3+{2'd0,y_raw})>>2;
                    end
                end else if(sample_strobe && age<TIMEOUT_SAMPLES) age<=age+13'd1;
                if(sample_strobe) begin
                    if(!sensor_ready) pressure_gate<=0;
                    else begin
                        if(smooth_force<force_target) smooth_force<=smooth_force+7'd1;
                        else if(smooth_force>force_target) smooth_force<=smooth_force-7'd1;
                        if(!pressure_gate && force_target>=12) begin pressure_gate<=1;pressure_trigger<=1;end
                        else if(pressure_gate && force_target<=6) pressure_gate<=0;
                    end
                end
            end
        end
    end
endmodule
`default_nettype wire
