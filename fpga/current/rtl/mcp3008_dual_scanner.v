`default_nettype none
// V3 U1 CH0..7 then U2 CH0..7. One coherent frame, shared mode-0 SPI.
module mcp3008_dual_scanner #(
    parameter integer CLK_DIV_CYCLES=25,
    parameter integer FRAME_IDLE_CYCLES=12500
)(
    input wire clk, reset_n, adc_miso,
    output wire adc_sclk, adc_mosi, adc_cs0_n, adc_cs1_n,
    output reg [159:0] channels,
    output reg frame_valid
);
    localparam integer IW=(FRAME_IDLE_CYCLES<2)?1:$clog2(FRAME_IDLE_CYCLES);
    localparam WAIT_FRAME=0, LAUNCH=1, RECEIVE=2;
    reg [1:0] state;
    reg [IW-1:0] idle_count;
    reg [3:0] index;
    reg [5:0] cs_gap;
    reg start;
    reg [159:0] pending;
    wire cs_n,valid;
    wire [9:0] value;
    assign adc_cs0_n=cs_n | index[3];
    assign adc_cs1_n=cs_n | ~index[3];
    mcp3008_reader #(.CLK_DIV_CYCLES(CLK_DIV_CYCLES),.EXTERNAL_START(1)) u_reader(
        .clk(clk),.reset_n(reset_n),.adc_miso(adc_miso),.start(start),.channel(index[2:0]),
        .adc_sclk(adc_sclk),.adc_mosi(adc_mosi),.adc_cs_n(cs_n),
        .adc_value(value),.sample_valid(valid),.busy());
    always @(posedge clk or negedge reset_n)begin
        if(!reset_n)begin
            state<=WAIT_FRAME;idle_count<=0;index<=0;cs_gap<=0;start<=0;
            pending<=0;channels<=0;frame_valid<=0;
        end else begin
            start<=0;frame_valid<=0;
            case(state)
                WAIT_FRAME:if(idle_count==FRAME_IDLE_CYCLES-1)begin
                    idle_count<=0;index<=0;state<=LAUNCH;
                end else idle_count<=idle_count+1'b1;
                // 50 clocks = 1 us deselect, including when changing chips.
                LAUNCH:if(cs_gap==49)begin start<=1;cs_gap<=0;state<=RECEIVE;end
                    else cs_gap<=cs_gap+1'b1;
                RECEIVE:if(valid)begin
                    pending[index*10+:10]<=value;
                    if(index==15)begin
                        channels<={value,pending[149:0]};frame_valid<=1;state<=WAIT_FRAME;
                    end else begin index<=index+1'b1;state<=LAUNCH;end
                end
                default:state<=WAIT_FRAME;
            endcase
        end
    end
endmodule
`default_nettype wire
