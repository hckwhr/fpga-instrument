`default_nettype none
// Actual V3: twelve independent FSRs, U2 CH4=Y, CH5=X, CH6=pot.
// CH7 (ANJIAN) and the joystick switch are unconnected in the supplied sheet.
module v3_analog_input #(parameter integer CE_ENABLE=0,
    parameter integer KEY_ORDER_REVERSED=0,
    
    parameter integer SPI_DIV=25,
    parameter integer SCAN_IDLE_CYCLES=12500,
    parameter integer CALIBRATION_LOG2=5,
    parameter integer SETTLE_FRAMES=8,
    parameter integer TIMEOUT_SAMPLES=240
)(
    input wire clock_enable,
    
    input wire sys_clk,sys_reset_n,audio_clk,audio_reset_n,sample_strobe,adc_miso,
    input wire [1:0] manual_vibrato,
    output wire adc_sclk,adc_mosi,adc_cs0_n,adc_cs1_n,
    output wire [15:0] keys,
    output wire [83:0] key_forces,
    output wire [6:0] force_value,
    output wire signed [7:0] bend,
    output wire [7:0] vibrato_depth,
    output wire pressure_gate,ready
);
    wire coupled_reset_n=sys_reset_n && audio_reset_n;
    reg [1:0] src_reset=0,dst_reset=0;
    always @(posedge sys_clk or negedge coupled_reset_n)
        if(!coupled_reset_n)src_reset<=0;else src_reset<={src_reset[0],1'b1};
    always @(posedge audio_clk or negedge coupled_reset_n)
        if(!coupled_reset_n)dst_reset<=0;else dst_reset<={dst_reset[0],1'b1};
    wire [159:0] raw;
    wire adc_valid;
    mcp3008_dual_scanner #(.CLK_DIV_CYCLES(SPI_DIV),.FRAME_IDLE_CYCLES(SCAN_IDLE_CYCLES)) u_adc(
        .clk(sys_clk),.reset_n(src_reset[1]),.adc_miso(adc_miso),.adc_sclk(adc_sclk),
        .adc_mosi(adc_mosi),.adc_cs0_n(adc_cs0_n),.adc_cs1_n(adc_cs1_n),
        .channels(raw),.frame_valid(adc_valid));
    localparam integer AW=10+CALIBRATION_LOG2;
    localparam integer SW=(SETTLE_FRAMES<2)?1:$clog2(SETTLE_FRAMES+1);
    reg [SW-1:0] settled[0:13];
    reg [CALIBRATION_LOG2:0] count[0:13];
    reg [AW-1:0] sums[0:13];
    reg [9:0] references[0:13],zeros[0:13];
    reg [13:0] calibrated;
    wire [9:0] center_x=calibrated[13] ? zeros[13] : 10'd512;
    wire [9:0] center_y=calibrated[12] ? zeros[12] : 10'd512;
    wire [9:0] x_value=calibrated[13] ? raw[139:130] : center_x;
    wire [9:0] y_value=calibrated[12] ? raw[129:120] : center_y;
    reg [11:0] keys_sys,on_pending,off_pending;
    reg [83:0] forces_sys;
    reg publish;
    wire [143:0] frame_audio;
    wire frame_valid;
    // 12 gates + 84 forces + X/Y + calibrated X/Y + max pressure (8 bits).
    // Max force is derived at the destination; last byte is reserved zero.
    audio_sample_cdc #(.SRC_CE_ENABLE(0),.DST_CE_ENABLE(CE_ENABLE),.WIDTH(144)) u_cdc(.src_clock_enable(1'b1),.dst_clock_enable(clock_enable),
        .src_clk(sys_clk),.src_reset_n(src_reset[1]),
        .src_sample({keys_sys,forces_sys,x_value,y_value,center_x,center_y,8'd0}),
        .src_sample_strobe(publish),.dst_clk(audio_clk),.dst_reset_n(dst_reset[1]),
        .dst_sample(frame_audio),.dst_sample_valid(frame_valid));
    genvar k;
    // Sensitivity 1x..2x, not the old 1/8x..1x attenuator. A low pot setting
    // must still allow a firm press to reach 127; high sensitivity reaches
    // full scale at about 128 ADC counts above the independently learnt zero.
    wire [7:0] pot_gain=8'd128+{1'b0,raw[149:143]};
    generate for(k=0;k<12;k=k+1)begin: u_pressure
        wire [9:0] delta=raw[k*10+:10]>zeros[k] ? raw[k*10+:10]-zeros[k] : 10'd0;
        // Sensitivity is applied to the sensor reading before the velocity
        // curve, so the curve always spans the same musical range.
        wire [17:0] boosted=delta*pot_gain;
        wire [10:0] sensed=boosted[17:7]>11'd1023 ? 11'd1023 : boosted[17:7];
        // Velocity curve. A key triggers at delta 24, where the previous linear
        // map produced force 12; the voice bank turns that into an amplitude of
        // 24/255, about -20 dB, which is why a light press was inaudible. The
        // low segment lifts the trigger point to an audible 40 and covers light
        // to medium playing, where an FSR moves least per gram; the high
        // segment keeps firm playing separable without spending range on
        // sensor saturation. Soft against hard stays near the previous ratio
        // (about 1.8 in force, 3.4 in energy) so dynamics are not flattened.
        wire [10:0] low_span =sensed>11'd24  ? sensed-11'd24  : 11'd0;
        wire [10:0] high_span=sensed>11'd160 ? sensed-11'd160 : 11'd0;
        wire [21:0] low_scaled =low_span *11'd98;   // 136 counts -> 52 steps
        wire [21:0] high_scaled=high_span*11'd95;   //  94 counts -> 35 steps
        wire [7:0] curved=(sensed<11'd24)   ? 8'd40 :
                          (sensed<11'd160)  ? 8'd40+low_scaled[15:8] :
                          (sensed>=11'd254) ? 8'd127 :
                                              8'd92+high_scaled[15:8];
        wire [6:0] target=curved>8'd127 ? 7'd127 : curved[6:0];
        always @(posedge sys_clk or negedge src_reset[1])begin
            if(!src_reset[1])begin
                keys_sys[k]<=0;on_pending[k]<=0;off_pending[k]<=0;forces_sys[k*7+:7]<=0;
            end else if(adc_valid && calibrated[k])begin
                // Two consecutive frames plus separate on/off thresholds.
                if(!keys_sys[k])begin
                    off_pending[k]<=0;on_pending[k]<=delta>=24;
                    if(delta>=24 && on_pending[k])keys_sys[k]<=1;
                end else begin
                    on_pending[k]<=0;off_pending[k]<=delta<=12;
                    if(delta<=12 && off_pending[k])keys_sys[k]<=0;
                end
                forces_sys[k*7+:7]<=target;
            end
        end
    end endgenerate
    // Calibrate each sensor independently. A held/unconnected/noisy sensor
    // remains inhibited without preventing other released sensors from working.
    // Joystick axes stay neutral until their own stable centre is established.
    genvar c;
    generate for(c=0;c<14;c=c+1)begin: u_calibration
        wire [9:0] value=raw[c*10+:10];
        wire idle_valid=(c<12) ? value<=10'd128 :
            (value>=10'd256 && value<=10'd768);
        wire [9:0] difference=value>references[c] ? value-references[c] : references[c]-value;
        always @(posedge sys_clk or negedge src_reset[1])begin
            if(!src_reset[1])begin
                settled[c]<=0;count[c]<=0;calibrated[c]<=0;
                sums[c]<=0;references[c]<=0;zeros[c]<=0;
            end else if(adc_valid && !calibrated[c])begin
                if(!idle_valid)begin settled[c]<=0;count[c]<=0;end
                else if(settled[c]<SETTLE_FRAMES)settled[c]<=settled[c]+1'b1;
                else if(count[c]==0 || difference>10'd8)begin
                    count[c]<=1;sums[c]<=value;references[c]<=value;
                end else if(count[c]==(1<<CALIBRATION_LOG2)-1)begin
                    zeros[c]<=({1'b0,sums[c]}+value)>>CALIBRATION_LOG2;
                    calibrated[c]<=1;
                end else begin count[c]<=count[c]+1'b1;sums[c]<=sums[c]+value;end
            end
        end
    end endgenerate
    // Publish after gates/velocities have been committed together.
    always @(posedge sys_clk or negedge src_reset[1])
        if(!src_reset[1])publish<=0;
        else publish<=adc_valid && (|calibrated[11:0]);
    reg [11:0] keys_audio;
    reg [83:0] forces_audio;
    always @(posedge audio_clk or negedge dst_reset[1])begin
        if(!dst_reset[1])begin keys_audio<=0;forces_audio<=0;end
        else if ((!CE_ENABLE || clock_enable)) if(frame_valid)begin keys_audio<=frame_audio[143:132];forces_audio<=frame_audio[131:48];end
    end
    // Aggregate level is for status/global controls; individual key forces and
    // note events keep their original latency. The old serial 12-way maximum
    // reached the status CDC through a 48 ns synthesis path. Four short stages
    // add only four audio clocks (81.38 ns), without a long comparator chain.
    reg [6:0] force_pair[0:5],force_group[0:2],force_half[0:1];
    reg [6:0] max_force;
    genvar pair;
    generate for(pair=0;pair<6;pair=pair+1)begin: u_force_pair
        wire [6:0] left_force=keys_audio[pair*2] ? forces_audio[pair*14+:7] : 7'd0;
        wire [6:0] right_force=keys_audio[pair*2+1] ? forces_audio[pair*14+7+:7] : 7'd0;
        always @(posedge audio_clk or negedge dst_reset[1])
            if(!dst_reset[1])force_pair[pair]<=7'd0;
            else if ((!CE_ENABLE || clock_enable)) force_pair[pair]<=left_force>right_force ? left_force : right_force;
    end endgenerate
    integer n;
    always @(posedge audio_clk or negedge dst_reset[1])begin
        if(!dst_reset[1])begin
            for(n=0;n<3;n=n+1)force_group[n]<=7'd0;
            force_half[0]<=7'd0;force_half[1]<=7'd0;max_force<=7'd0;
        end else if ((!CE_ENABLE || clock_enable)) begin
            for(n=0;n<3;n=n+1)
                force_group[n]<=force_pair[n*2]>force_pair[n*2+1] ? force_pair[n*2] : force_pair[n*2+1];
            force_half[0]<=force_group[0]>force_group[1] ? force_group[0] : force_group[1];
            force_half[1]<=force_group[2];
            max_force<=force_half[0]>force_half[1] ? force_half[0] : force_half[1];
        end
    end
    // V5 playing orientation: left key is FSR11, right key FSR0.
    // Permute gates AND their velocities after coherent CDC; calibration stays
    // attached to its physical ADC channel. This is static wiring, no latency.
    assign keys[15:12]=4'd0;
    genvar key_slot;
    generate for(key_slot=0;key_slot<12;key_slot=key_slot+1)begin: key_order
        localparam integer SENSOR=KEY_ORDER_REVERSED ? 11-key_slot : key_slot;
        assign keys[key_slot]=ready && keys_audio[SENSOR];
        assign key_forces[key_slot*7+:7]=forces_audio[SENSOR*7+:7];
    end endgenerate
    assign force_value=ready ? max_force : 7'd0;
    assign pressure_gate=ready && |keys_audio;
    performance_controls #(.CE_ENABLE(CE_ENABLE),.MANUAL_VIBRATO_FLOOR(1),.TIMEOUT_SAMPLES(TIMEOUT_SAMPLES)) u_controls(.clock_enable(clock_enable),
        .clk(audio_clk),.reset_n(dst_reset[1]),.sample_strobe(sample_strobe),.sensor_enable(1'b1),
        .frame_valid(frame_valid),.force_raw(10'd0),.x_raw(frame_audio[47:38]),.y_raw(frame_audio[37:28]),
        .x_center(frame_audio[27:18]),.y_center(frame_audio[17:8]),.force_zero(10'd0),
        .force_gain_q12(12'd0),.manual_force(7'd0),.manual_vibrato(manual_vibrato),
        .force_value(),.bend(bend),.vibrato_depth(vibrato_depth),
        .pressure_gate(),.pressure_trigger(),.sensor_ready(ready));
endmodule
`default_nettype wire
