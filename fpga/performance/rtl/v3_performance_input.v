`default_nettype none
// Logical V3 input boundary. No package assignments: final V3 PCB is pending.
module v3_performance_input #(
    parameter integer SPI_DIV=25,
    parameter integer SCAN_IDLE_CYCLES=12500,
    parameter integer DEBOUNCE_FRAMES=4,
    parameter integer CALIBRATION_LOG2=5,
    parameter integer SETTLE_FRAMES=8,
    parameter integer TIMEOUT_SAMPLES=240
)(
    input wire sys_clk, sys_reset_n, audio_clk, audio_reset_n,
    input wire sample_strobe, adc_miso, key_serial,
    input wire [6:0] manual_force,
    input wire [1:0] manual_vibrato,
    output wire adc_sclk, adc_mosi, adc_cs_n, key_load_n, key_shift_clk,
    output reg [15:0] keys,
    output wire [6:0] force_value,
    output wire signed [7:0] bend,
    output wire [7:0] vibrato_depth,
    output wire pressure_gate, ready,
    output wire calibrated,
    output wire [9:0] force_zero, x_center, y_center
);
    wire coupled_reset_n=sys_reset_n && audio_reset_n;
    reg [1:0] src_reset=0,dst_reset=0;
    always @(posedge sys_clk or negedge coupled_reset_n)
        if(!coupled_reset_n)src_reset<=0;else src_reset<={src_reset[0],1'b1};
    always @(posedge audio_clk or negedge coupled_reset_n)
        if(!coupled_reset_n)dst_reset<=0;else dst_reset<={dst_reset[0],1'b1};
    wire [15:0] keys_sys;
    wire keys_ready, adc_valid;
    wire [9:0] raw_force,raw_x,raw_y;
    keypad_165 #(.CLK_DIV_CYCLES(SPI_DIV),.SCAN_IDLE_CYCLES(SCAN_IDLE_CYCLES),
        .DEBOUNCE_FRAMES(DEBOUNCE_FRAMES)) u_keys(
        .clk(sys_clk),.reset_n(src_reset[1]),.serial_data(key_serial),
        .load_n(key_load_n),.shift_clk(key_shift_clk),.keys(keys_sys),.frame_valid(),.ready(keys_ready));
    mcp3008_scanner #(.CLK_DIV_CYCLES(SPI_DIV),.FRAME_IDLE_CYCLES(SCAN_IDLE_CYCLES)) u_adc(
        .clk(sys_clk),.reset_n(src_reset[1]),.adc_miso(adc_miso),
        .adc_sclk(adc_sclk),.adc_mosi(adc_mosi),.adc_cs_n(adc_cs_n),
        .force_raw(raw_force),.x_raw(raw_x),.y_raw(raw_y),.frame_valid(adc_valid));
    localparam integer SW=(SETTLE_FRAMES<2)?1:$clog2(SETTLE_FRAMES+1);
    localparam integer CW=CALIBRATION_LOG2+1;
    localparam integer AW=10+CALIBRATION_LOG2;
    reg [SW-1:0] settled;
    reg [CW-1:0] count;
    reg [AW-1:0] sum_force,sum_x,sum_y;
    reg [9:0] reference_force,reference_x,reference_y,zero_sys,center_x_sys,center_y_sys;
    reg calibrated_sys;
    wire idle_valid=keys_ready && keys_sys==0 && raw_force<=128 &&
        raw_x>=256 && raw_x<=768 && raw_y>=256 && raw_y<=768;
    wire stable=(raw_force>reference_force ? raw_force-reference_force : reference_force-raw_force)<=8 &&
        (raw_x>reference_x ? raw_x-reference_x : reference_x-raw_x)<=8 &&
        (raw_y>reference_y ? raw_y-reference_y : reference_y-raw_y)<=8;
    wire [AW:0] total_force={1'b0,sum_force}+raw_force;
    wire [AW:0] total_x={1'b0,sum_x}+raw_x;
    wire [AW:0] total_y={1'b0,sum_y}+raw_y;
    always @(posedge sys_clk or negedge src_reset[1])begin
        if(!src_reset[1])begin
            settled<=0;count<=0;sum_force<=0;sum_x<=0;sum_y<=0;calibrated_sys<=0;
            reference_force<=0;reference_x<=512;reference_y<=512;
            zero_sys<=0;center_x_sys<=512;center_y_sys<=512;
        end else if(adc_valid && !calibrated_sys)begin
            if(!idle_valid)begin settled<=0;count<=0;sum_force<=0;sum_x<=0;sum_y<=0;end
            else if(settled<SETTLE_FRAMES)settled<=settled+1'b1;
            else if(count==0 || !stable)begin
                count<=1;sum_force<=raw_force;sum_x<=raw_x;sum_y<=raw_y;
                reference_force<=raw_force;reference_x<=raw_x;reference_y<=raw_y;
            end else if(count==(1<<CALIBRATION_LOG2)-1)begin
                zero_sys<=total_force>>CALIBRATION_LOG2;
                center_x_sys<=total_x>>CALIBRATION_LOG2;center_y_sys<=total_y>>CALIBRATION_LOG2;
                calibrated_sys<=1;
            end else begin
                count<=count+1'b1;sum_force<=total_force;sum_x<=total_x;sum_y<=total_y;
            end
        end
    end
    wire [75:0] frame_audio;
    wire frame_valid;
    audio_sample_cdc #(.WIDTH(76)) u_cdc(
        .src_clk(sys_clk),.src_reset_n(src_reset[1]),
        .src_sample({keys_sys,raw_force,raw_x,raw_y,zero_sys,center_x_sys,center_y_sys}),
        .src_sample_strobe(adc_valid && calibrated_sys),
        .dst_clk(audio_clk),.dst_reset_n(dst_reset[1]),.dst_sample(frame_audio),.dst_sample_valid(frame_valid));
    assign force_zero=frame_audio[29:20];
    assign x_center=frame_audio[19:10];assign y_center=frame_audio[9:0];
    reg calibrated_audio;
    always @(posedge audio_clk or negedge dst_reset[1])begin
        if(!dst_reset[1])begin keys<=0;calibrated_audio<=0;end
        else begin
            if(!ready)keys<=0;
            if(frame_valid)begin keys<=frame_audio[75:60];calibrated_audio<=1;end
        end
    end
    assign calibrated=calibrated_audio;
    performance_controls #(.TIMEOUT_SAMPLES(TIMEOUT_SAMPLES)) u_controls(
        .clk(audio_clk),.reset_n(dst_reset[1]),.sample_strobe(sample_strobe),.sensor_enable(1'b1),
        .frame_valid(frame_valid),.force_raw(frame_audio[59:50]),.x_raw(frame_audio[49:40]),
        .y_raw(frame_audio[39:30]),.force_zero(force_zero),.x_center(x_center),.y_center(y_center),
        .force_gain_q12(12'd2048),.manual_force(manual_force),.manual_vibrato(manual_vibrato),
        .force_value(force_value),.bend(bend),.vibrato_depth(vibrato_depth),
        .pressure_gate(pressure_gate),.pressure_trigger(),.sensor_ready(ready));
endmodule
`default_nettype wire
