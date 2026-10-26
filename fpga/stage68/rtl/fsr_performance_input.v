`default_nettype none
// FSR0 adapter into the existing live-instrument event/force contract.
// SPI/sys -> held-data handshake -> audio controls. No audio generator here.
module fsr_performance_input #(
    parameter integer SAMPLE_PERIOD_CYCLES=12500,
    parameter integer ATTACK_WAIT_SAMPLES=96
) (
    input wire sys_clk, sys_reset_n, audio_clk, audio_reset_n,
    input wire sample_strobe, live_enable, adc_miso,
    output wire adc_sclk, adc_mosi, adc_cs0_n, adc_cs1_n,
    output wire [3:0] adc_led,
    output wire [6:0] force_value,
    output reg gate, trigger,
    output wire ready
);
    wire [9:0] raw_sys, raw_audio;
    wire valid_sys, valid_audio, busy;
    // Coupled reset prevents a PLL loss on either side leaving mismatched toggles.
    wire cdc_reset_n=sys_reset_n && audio_reset_n;
    reg [1:0] source_reset_sync_n=0, dest_reset_sync_n=0;
    always @(posedge sys_clk or negedge cdc_reset_n)
        if(!cdc_reset_n)source_reset_sync_n<=0;
        else source_reset_sync_n<={source_reset_sync_n[0],1'b1};
    always @(posedge audio_clk or negedge cdc_reset_n)
        if(!cdc_reset_n)dest_reset_sync_n<=0;
        else dest_reset_sync_n<={dest_reset_sync_n[0],1'b1};
    mcp3008_reader #(.SAMPLE_PERIOD_CYCLES(SAMPLE_PERIOD_CYCLES)) u_reader(
        .clk(sys_clk),.reset_n(source_reset_sync_n[1]),.adc_miso(adc_miso),
        .adc_sclk(adc_sclk),.adc_mosi(adc_mosi),.adc_cs_n(adc_cs0_n),
        .adc_value(raw_sys),.sample_valid(valid_sys),.busy(busy));
    assign adc_cs1_n=1'b1;
    reg [3:0] led_bar;
    always @(posedge sys_clk or negedge source_reset_sync_n[1])begin
        if(!source_reset_sync_n[1])led_bar<=4'd0;
        else if(valid_sys)begin
            if(raw_sys<10'd128)led_bar<=4'b0000;
            else if(raw_sys<10'd256)led_bar<=4'b0001;
            else if(raw_sys<10'd384)led_bar<=4'b0011;
            else led_bar<=4'b1111;
        end
    end
    assign adc_led=~led_bar;
    audio_sample_cdc #(.WIDTH(10)) u_cdc(
        .src_clk(sys_clk),.src_reset_n(source_reset_sync_n[1]),.src_sample(raw_sys),
        .src_sample_strobe(valid_sys),.dst_clk(audio_clk),.dst_reset_n(dest_reset_sync_n[1]),
        .dst_sample(raw_audio),.dst_sample_valid(valid_audio));
    wire pressure_gate, unused_trigger;
    wire signed [7:0] unused_bend;
    wire [7:0] unused_vibrato;
    performance_controls u_controls(
        .clk(audio_clk),.reset_n(dest_reset_sync_n[1]),.sample_strobe(sample_strobe),
        .sensor_enable(1'b1),.frame_valid(valid_audio),.force_raw(raw_audio),
        .x_raw(10'd512),.y_raw(10'd512),.force_zero(10'd104),
        .x_center(10'd512),.y_center(10'd512),.force_gain_q12(12'd2048),
        .manual_force(7'd0),.manual_vibrato(2'd0),.force_value(force_value),
        .bend(unused_bend),.vibrato_depth(unused_vibrato),.pressure_gate(pressure_gate),
        .pressure_trigger(unused_trigger),.sensor_ready(ready));
    localparam integer WAIT_WIDTH=(ATTACK_WAIT_SAMPLES<2)?1:$clog2(ATTACK_WAIT_SAMPLES);
    reg [WAIT_WIDTH-1:0] attack_wait;
    reg armed, pending;
    always @(posedge audio_clk or negedge dest_reset_sync_n[1])begin
        if(!dest_reset_sync_n[1])begin
            attack_wait<=0;armed<=0;pending<=0;gate<=0;trigger<=0;
        end else begin
            trigger<=0;
            if(!live_enable || !ready)begin
                armed<=0;pending<=0;gate<=0;attack_wait<=0;
            end else if(sample_strobe)begin
                if(!pressure_gate)begin
                    armed<=1;pending<=0;gate<=0;attack_wait<=0;
                end else if(armed)begin
                    armed<=0;pending<=1;attack_wait<=0;
                end else if(pending)begin
                    // Let the existing force slew settle before a pluck samples gain.
                    // 96 audio samples (~2 ms) matches the main key onset guard.
                    if(attack_wait==ATTACK_WAIT_SAMPLES-1)begin
                        pending<=0;gate<=1;trigger<=1;
                    end else attack_wait<=attack_wait+1'b1;
                end
            end
        end
    end
endmodule
`default_nettype wire
