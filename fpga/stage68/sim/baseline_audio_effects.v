`default_nettype none
module baseline_audio_effects #(
    parameter integer ADDRESS_WIDTH=13,
    parameter [ADDRESS_WIDTH-1:0] DELAY_SAMPLES=13'd6144,
    parameter [ADDRESS_WIDTH-1:0] CHORUS_BASE_DELAY=13'd48,
    parameter [15:0] CHORUS_PHASE_STEP=16'd2
)(
    input wire clk, reset_n, sample_strobe, mute,
    input wire [1:0] effect_select,
    input wire signed [15:0] sample_in,
    output wire signed [15:0] sample_out
);
    localparam integer RAM_DEPTH=(1<<ADDRESS_WIDTH);
    (* syn_ramstyle="block_ram" *) reg signed [15:0] delay_ram[0:RAM_DEPTH-1];
    reg [ADDRESS_WIDTH-1:0] pointer;
    reg [ADDRESS_WIDTH:0] filled;
    reg [15:0] chorus_phase;
    reg [1:0] active_mode;
    reg [7:0] level;
    reg [3:0] step;
    reg signed [15:0] tap0,tap1,input_hold,wet,rendered;
    reg signed [25:0] interpolation;
    reg signed [24:0] output_product;
    reg [7:0] fraction;
    reg valid_tap;
    wire changing=mute || effect_select!=active_mode;
    wire running=!changing && level!=0;
    wire [14:0] triangle=chorus_phase[15]?~chorus_phase[14:0]:chorus_phase[14:0];
    wire [ADDRESS_WIDTH-1:0] delay_length=(active_mode==2)?
        CHORUS_BASE_DELAY+{{(ADDRESS_WIDTH-7){1'b0}},triangle[14:8]}:DELAY_SAMPLES;
    wire [ADDRESS_WIDTH-1:0] read_pointer=pointer-delay_length;
    wire signed [16:0] tap_difference=$signed({tap1[15],tap1})-$signed({tap0[15],tap0});
    wire signed [25:0] interpolated=$signed({{10{tap0[15]}},tap0})+(interpolation>>>8);
    wire signed [16:0] feedback=$signed({input_hold[15],input_hold})/17'sd2+
        $signed({wet[15],wet})/17'sd2;
    wire signed [15:0] r0,r1,r2,r3;
    wire signed [17:0] reverb_sum=$signed({{2{r0[15]}},r0})+$signed({{2{r1[15]}},r1})+
        $signed({{2{r2[15]}},r2})+$signed({{2{r3[15]}},r3});
    reg signed [15:0] reverb_wet;
    wire signed [15:0] selected_wet=(active_mode==3)?reverb_wet:wet;
    wire signed [16:0] mixed=$signed({input_hold[15],input_hold})/17'sd2+
        $signed({selected_wet[15],selected_wet})/17'sd2;
    wire reverb_enable=running && active_mode==3;
    reverb_comb #(.LENGTH(1499)) c0(.clk(clk),.reset_n(reset_n),.sample_strobe(sample_strobe),.enable(reverb_enable),.sample_in(sample_in),.sample_out(r0));
    reverb_comb #(.LENGTH(1601)) c1(.clk(clk),.reset_n(reset_n),.sample_strobe(sample_strobe),.enable(reverb_enable),.sample_in(sample_in),.sample_out(r1));
    reverb_comb #(.LENGTH(1747)) c2(.clk(clk),.reset_n(reset_n),.sample_strobe(sample_strobe),.enable(reverb_enable),.sample_in(sample_in),.sample_out(r2));
    reverb_comb #(.LENGTH(1867)) c3(.clk(clk),.reset_n(reset_n),.sample_strobe(sample_strobe),.enable(reverb_enable),.sample_in(sample_in),.sample_out(r3));
    // Output gain ramps for 128 samples when a mode changes or mute is requested.
    always @(posedge clk) output_product<=rendered*$signed({1'b0,level});
    assign sample_out=(level==128 && active_mode==0 && !changing)?sample_in:
        output_product[22:7];
    always @(posedge clk) begin
        if(sample_strobe && running) begin
            tap0<=delay_ram[read_pointer];
            tap1<=delay_ram[read_pointer-{{(ADDRESS_WIDTH-1){1'b0}},1'b1}];
        end
        if(step==4'd4 && running)
            delay_ram[pointer]<=(active_mode==1)?feedback[15:0]:input_hold;
    end
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin
            pointer<=0;filled<=0;chorus_phase<=0;active_mode<=0;level<=0;step<=0;
            input_hold<=0;wet<=0;rendered<=0;fraction<=0;valid_tap<=0;
            interpolation<=0;reverb_wet<=0;
        end else begin
            if(sample_strobe) begin
                if(changing) begin
                    step<=0;
                    if(level!=0) level<=level-8'd1;
                    else begin
                        active_mode<=effect_select;rendered<=0;pointer<=0;filled<=0;
                        chorus_phase<=0;wet<=0;valid_tap<=0;
                    end
                end else begin
                    if(level<128) level<=level+8'd1;
                    if(running) begin
                        input_hold<=sample_in; fraction<=triangle[7:0];
                        valid_tap<=filled>{1'b0,delay_length};
                        chorus_phase<=chorus_phase+CHORUS_PHASE_STEP;step<=1;
                    end
                end
            end else if(!changing) case(step)
                1:begin interpolation<=tap_difference*$signed({1'b0,fraction});step<=2;end
                2:begin
                    wet<=valid_tap?((active_mode==2)?interpolated[15:0]:tap0):16'sd0;
                    reverb_wet<=reverb_sum/18'sd4;step<=3;
                end
                3:begin rendered<=(active_mode==0)?input_hold:mixed[15:0];step<=4;end
                4:begin
                    pointer<=pointer+{{(ADDRESS_WIDTH-1){1'b0}},1'b1};
                    if(filled<RAM_DEPTH) filled<=filled+{{ADDRESS_WIDTH{1'b0}},1'b1};
                    step<=0;
                end
                default:step<=0;
            endcase
        end
    end
endmodule
`default_nettype wire
