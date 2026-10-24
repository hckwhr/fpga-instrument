`default_nettype none

// One independent Karplus-Strong waveguide. Each voice owns its RAM and
// feedback arithmetic; no voice shares or time-multiplexes another's loop.
// Excitation fill and fractional-delay feedback fit within 1024 clocks/sample.
module stage25_physical_string_voice #(
    parameter [15:0] NOISE_SEED = 16'h1ace
) (
    input wire clk, reset_n, sample_strobe, enable, trigger,
    input wire held, pluck_mode,
    input wire [5:0] note,
    input wire [6:0] force_value,
    input wire signed [16:0] delay_delta,
    output reg signed [15:0] sample,
    output reg active,
    output reg [15:0] level,
    output wire busy,
    output wire accepting
);
    localparam [4:0] IDLE=0, FILL=1, READ=2, LOWPASS=3,
        AP_MUL=4, AP_SUM=5, LOSS_MUL=6, LOSS_SUM=7, WRITE=8,
        FETCH_LEFT=9,FETCH_RIGHT=10,FETCH_FAR=11,CAPTURE=12,
        IM0=13,IS0=14,IM1=15,IS1=16,IM2=17,IS2=18,IM3=19,IS3=20,IEND=21;
    reg [4:0] state;
    (* syn_ramstyle = "block_ram" *) reg signed [15:0] delay_ram [0:511];
    reg [8:0] write_pointer, fill_pointer, delay_length;
    reg [20:0] period_q12,delay_q12;
    reg signed [38:0] delay_product;
    reg [20:0] target_delay;
    wire signed [41:0] delay_sum = $signed({21'd0,delay_length,12'd0}) +
        ($signed({{3{delay_product[38]}},delay_product}) >>> 18);
    wire [20:0] slew_step = period_q12 >> 10;
    wire [20:0] delay_error = target_delay>delay_q12 ? target_delay-delay_q12 : delay_q12-target_delay;
    wire [8:0] read_center = write_pointer-delay_q12[20:12];
    wire [8:0] read_pointer = state==FETCH_LEFT ? read_center+9'd1 :
        state==FETCH_RIGHT ? read_center-9'd1 : state==FETCH_FAR ? read_center-9'd2 : read_center;
    wire fractional = delay_q12[11:4]!=8'd0;
    // Prefetch one tap during the preceding capture/accumulate state.
    // This keeps the original feedback cycle count with a narrow ROM bus.
    wire [1:0] coefficient_tap = state==IS0 ? 2'd1 :
        state==IS1 ? 2'd2 : state==IS2 ? 2'd3 : 2'd0;
    reg signed [15:0] interp_coefficient;
    reg signed [15:0] tap_left,tap_center,tap_right,tap_far,interpolated;
    reg signed [31:0] interp_product;
    reg signed [33:0] interp_acc;
    wire signed [15:0] interp_operand = state==IM0 ? tap_left : state==IM1 ? tap_center :
        state==IM2 ? tap_right : tap_far;
    reg signed [15:0] ram_value, previous_delay, lowpass_value;
    reg signed [15:0] previous_lowpass, allpass_value, loop_value;
    reg signed [33:0] product;
    reg [15:0] allpass_coefficient, loss_coefficient;
    reg [31:0] fill_phase, fill_increment;
    reg [15:0] noise;
    reg [6:0] strike_force, ramp;
    reg [18:0] age;
    reg pending;
    reg [11:0] quiet_count;
    reg [5:0] pending_note;
    reg [6:0] pending_force;
    reg signed [23:0] dc_state;

    `include "sim/stage25_string_tuning.vh"
    `include "string_interp.vh"
    `include "string_interp_serial.vh"
    wire [72:0] tuning = string_tuning(pending_note);
    wire signed [15:0] delayed_value = fractional ? interpolated : ram_value;
    // Targets settle between samples. The pending replacement does not change
    // the outgoing string's period; a new period commits only at zero gain.
    always @(posedge clk) begin
        delay_product <= $signed({1'b0,period_q12}) * delay_delta;
        target_delay <= delay_sum<42'sd8192 ? 21'd8192 :
            delay_sum>42'sd2084864 ? 21'd2084864 : delay_sum[20:0];
        interp_coefficient <= string_interp_serial({coefficient_tap,delay_q12[11:4]});
    end
    wire [15:0] triangle = fill_phase[31] ? ~fill_phase[30:15] : fill_phase[30:15];
    wire signed [15:0] displacement = $signed(triangle ^ 16'h8000) >>> 2;
    wire signed [15:0] excitation = displacement + ($signed(noise) >>> 6);
    wire signed [23:0] excitation_scaled = excitation * $signed({1'b0, strike_force});
    wire signed [18:0] lowpass_sum = ($signed({{3{delayed_value[15]}},delayed_value}) <<< 3)
        - $signed({{3{delayed_value[15]}},delayed_value})
        + $signed({{3{previous_delay[15]}},previous_delay});
    wire signed [16:0] ap_difference = $signed({lowpass_value[15],lowpass_value})
        - $signed({allpass_value[15],allpass_value});
    // These two stages never overlap. Select operands before one local DSP;
    // every voice still owns its independent feedback multiplier and RAM.
    wire signed [16:0] feedback_operand = state==AP_MUL ? ap_difference :
        $signed({allpass_value[15],allpass_value});
    wire signed [16:0] feedback_coefficient = state==AP_MUL ?
        $signed({1'b0,allpass_coefficient}) : $signed({1'b0,loss_coefficient});
    wire signed [33:0] ap_sum = $signed(previous_lowpass) + (product >>> 15);
    wire signed [24:0] dc_error = ($signed({{9{loop_value[15]}},loop_value}) <<< 8)
        - $signed({dc_state[23],dc_state});
    wire signed [16:0] ac_value = $signed({loop_value[15],loop_value}) - (dc_state >>> 8);
    wire signed [24:0] output_product = ac_value * $signed({1'b0,ramp});
    wire damped = !pluck_mode && !held;
    wire signed [18:0] damping_product =
        ($signed({{3{allpass_value[15]}},allpass_value}) <<< 3) -
        $signed({{3{allpass_value[15]}},allpass_value});
    assign busy = (state != IDLE);
    assign accepting = !pending && (state != FILL);
    wire signed [15:0] next_sample = clamp(output_product >>> 6);
    wire [15:0] magnitude = next_sample[15] ? (~next_sample + 16'd1) : next_sample;

    function signed [15:0] clamp;
        input signed [33:0] value;
        begin
            if(value > 34'sd32767) clamp=16'sh7fff;
            else if(value < -34'sd32768) clamp=16'sh8000;
            else clamp=value[15:0];
        end
    endfunction

    // Synchronous single read/write-port template. RAM never asynchronously
    // resets; FILL writes every location before the first feedback read.
    always @(posedge clk) begin
        if (state == FILL) delay_ram[fill_pointer] <= excitation_scaled >>> 7;
        else if (state == WRITE) delay_ram[write_pointer] <= loop_value;
        if (state==READ || state==FETCH_LEFT || state==FETCH_RIGHT || state==FETCH_FAR)
            ram_value <= delay_ram[read_pointer];
    end

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state<=IDLE; write_pointer<=0; fill_pointer<=0; delay_length<=1;
            previous_delay<=0; lowpass_value<=0; previous_lowpass<=0;
            allpass_value<=0; loop_value<=0; product<=0;
            allpass_coefficient<=0; loss_coefficient<=0;
            fill_phase<=0; fill_increment<=0; noise<=NOISE_SEED;
            strike_force<=0; ramp<=0; age<=0; pending<=0;
            pending_note<=0; pending_force<=0; dc_state<=0; sample<=0; active<=0;
            level<=0; quiet_count<=0;
            period_q12<=0;delay_q12<=21'd8192;
            tap_left<=0;tap_center<=0;tap_right<=0;tap_far<=0;interpolated<=0;
            interp_product<=0;interp_acc<=0;
        end else if (!enable) begin
            state<=IDLE; pending<=0; active<=0; ramp<=0; sample<=0; dc_state<=0;
            level<=0; quiet_count<=0;
        end else begin
            if(sample_strobe && active && !pending)begin
                if(delay_error<=slew_step)delay_q12<=target_delay;
                else if(target_delay>delay_q12)delay_q12<=delay_q12+slew_step;
                else delay_q12<=delay_q12-slew_step;
            end
            if (trigger) begin
                pending<=1; pending_note<=note; pending_force<=force_value;
            end
            if (state==AP_MUL || state==LOSS_MUL)
                product<=feedback_operand * feedback_coefficient;
            case(state)
                IDLE: if (sample_strobe) begin
                    if (pending && ramp==0) begin
                        pending<=0; state<=FILL; fill_pointer<=0; write_pointer<=0;
                        delay_length<=tuning[72:64]; allpass_coefficient<=tuning[63:48];
                        period_q12<=string_period(pending_note);
                        delay_q12<={tuning[72:64],12'd0};
                        loss_coefficient<=tuning[47:32]; fill_increment<=tuning[31:0];
                        strike_force<=pending_force; fill_phase<=0;
                        previous_delay<=0; previous_lowpass<=0; allpass_value<=0;
                        dc_state<=0; sample<=0; age<=0; active<=1;
                        level<=0; quiet_count<=0;
                    end else if (active) begin
                        if (pending || age>=19'd240000 || quiet_count==12'd2047) begin
                            if (ramp>0) ramp<=ramp-7'd2;
                            else begin active<=0; sample<=0; level<=0; end
                        end else if (ramp<7'd64) ramp<=ramp+7'd2;
                        if (age<19'd240000) age<=age+19'd1;
                        if (ramp!=0 || !(pending || age>=19'd240000 || quiet_count==12'd2047))
                            state<=READ;
                    end
                end
                FILL: begin
                    noise<={noise[14:0],noise[15]^noise[13]^noise[12]^noise[10]};
                    fill_phase<=fill_phase+fill_increment;
                    if (fill_pointer==9'd511)begin state<=IDLE;delay_q12<=target_delay;end
                    else fill_pointer<=fill_pointer+9'd1;
                end
                READ: state<=fractional ? FETCH_LEFT : LOWPASS;
                FETCH_LEFT: begin tap_center<=ram_value;state<=FETCH_RIGHT;end
                FETCH_RIGHT: begin tap_left<=ram_value;state<=FETCH_FAR;end
                FETCH_FAR: begin tap_right<=ram_value;state<=CAPTURE;end
                CAPTURE: begin tap_far<=ram_value;state<=IM0;end
                IM0,IM1,IM2,IM3: begin
                    interp_product<=interp_operand*interp_coefficient;
                    state<=state+5'd1;
                end
                IS0: begin interp_acc<={{2{interp_product[31]}},interp_product};state<=IM1;end
                IS1: begin interp_acc<=interp_acc+$signed({{2{interp_product[31]}},interp_product});state<=IM2;end
                IS2: begin interp_acc<=interp_acc+$signed({{2{interp_product[31]}},interp_product});state<=IM3;end
                IS3: begin interp_acc<=interp_acc+$signed({{2{interp_product[31]}},interp_product});state<=IEND;end
                IEND: begin interpolated<=clamp(interp_acc >>> 14);state<=LOWPASS;end
                LOWPASS: begin
                    lowpass_value<=lowpass_sum >>> 3;
                    previous_delay<=delayed_value;
                    state<=AP_MUL;
                end
                AP_MUL: begin
                    state<=AP_SUM;
                end
                AP_SUM: begin
                    allpass_value<=clamp(ap_sum); previous_lowpass<=lowpass_value;
                    state<=LOSS_MUL;
                end
                LOSS_MUL: begin
                    state<=LOSS_SUM;
                end
                LOSS_SUM: begin
                    // Truncate toward zero, avoiding a negative fixed-point DC floor.
                    if (damped) begin
                        if(damping_product<0) loop_value<=-((-damping_product) >>> 3);
                        else loop_value<=damping_product >>> 3;
                    end
                    else if (product<0) loop_value<=-((-product) >>> 15);
                    else loop_value<=product >>> 15;
                    state<=WRITE;
                end
                WRITE: begin
                    dc_state<=dc_state+(dc_error >>> 8);
                    sample<=next_sample;
                    if (magnitude>level) level<=magnitude;
                    else if (level!=0) level<=level-(level>>8)-16'd1;
                    // Ignore isolated zero crossings when retiring quiet tails.
                    if (quiet_count!=12'd2047) begin
                        if (age>19'd2048 && magnitude<=16'd8)
                            quiet_count<=quiet_count+12'd1;
                        else quiet_count<=0;
                    end
                    write_pointer<=write_pointer+9'd1; state<=IDLE;
                end
                default: begin state<=IDLE; active<=0; sample<=0; end
            endcase
        end
    end
endmodule
`default_nettype wire
