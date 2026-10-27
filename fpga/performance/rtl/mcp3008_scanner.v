`default_nettype none
// One physical ADC, sequential CH0=pressure, CH1=X, CH2=Y.
// Publish only complete triplets; no mixed old/new axis frame crosses the CDC.
module mcp3008_scanner #(
    parameter integer CLK_DIV_CYCLES=25,
    parameter integer FRAME_IDLE_CYCLES=12500
)(
    input wire clk, reset_n, adc_miso,
    output wire adc_sclk, adc_mosi, adc_cs_n,
    output reg [9:0] force_raw, x_raw, y_raw,
    output reg frame_valid
);
    localparam integer IW=(FRAME_IDLE_CYCLES<2)?1:$clog2(FRAME_IDLE_CYCLES);
    localparam WAIT_FRAME=0, LAUNCH=1, RECEIVE=2;
    reg [1:0] state;
    reg [IW-1:0] idle_count;
    reg [2:0] channel;
    reg start;
    reg [7:0] cs_gap;
    reg [9:0] force_pending, x_pending;
    wire [9:0] value;
    wire valid;
    mcp3008_reader #(.CLK_DIV_CYCLES(CLK_DIV_CYCLES),.EXTERNAL_START(1)) u_reader(
        .clk(clk),.reset_n(reset_n),.adc_miso(adc_miso),.start(start),.channel(channel),
        .adc_sclk(adc_sclk),.adc_mosi(adc_mosi),.adc_cs_n(adc_cs_n),
        .adc_value(value),.sample_valid(valid),.busy());
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n)begin
            state<=WAIT_FRAME;idle_count<=0;channel<=0;start<=0;cs_gap<=0;
            force_pending<=0;x_pending<=0;force_raw<=0;x_raw<=0;y_raw<=0;frame_valid<=0;
        end else begin
            start<=0;frame_valid<=0;
            case(state)
                WAIT_FRAME: if(idle_count==FRAME_IDLE_CYCLES-1)begin
                    idle_count<=0;channel<=0;state<=LAUNCH;
                end else idle_count<=idle_count+1'b1;
                // >=1 us deselect at the production 50 MHz clock.
                LAUNCH: if(cs_gap==49)begin start<=1;cs_gap<=0;state<=RECEIVE;end
                    else cs_gap<=cs_gap+1'b1;
                RECEIVE: if(valid) begin
                    if(channel==0)force_pending<=value;
                    else if(channel==1)x_pending<=value;
                    else begin
                        force_raw<=force_pending;x_raw<=x_pending;y_raw<=value;frame_valid<=1;
                    end
                    if(channel==2)state<=WAIT_FRAME;
                    else begin channel<=channel+1'b1;state<=LAUNCH;end
                end
                default:state<=WAIT_FRAME;
            endcase
        end
    end
endmodule
`default_nettype wire
