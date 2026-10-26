`default_nettype none
// Near 165 H..A followed by far 165 H..A. Active-low parallel inputs.
// Capture QH before the first rising shift edge; otherwise every key is shifted.
module keypad_165 #(
    parameter integer CLK_DIV_CYCLES=25,
    parameter integer SCAN_IDLE_CYCLES=12500,
    parameter integer DEBOUNCE_FRAMES=4
)(
    input wire clk, reset_n, serial_data,
    output reg load_n, shift_clk,
    output reg [15:0] keys,
    output reg frame_valid, ready
);
    localparam integer DW=(CLK_DIV_CYCLES<2)?1:$clog2(CLK_DIV_CYCLES);
    localparam integer IW=(SCAN_IDLE_CYCLES<2)?1:$clog2(SCAN_IDLE_CYCLES);
    localparam integer CW=(DEBOUNCE_FRAMES<2)?1:$clog2(DEBOUNCE_FRAMES+1);
    localparam IDLE=0, LOAD=1, SAMPLE=2, HIGH=3, PUBLISH=4;
    reg [2:0] state;
    reg [DW-1:0] divider;
    reg [IW-1:0] idle_count;
    reg [CW-1:0] startup_frames;
    reg [CW-1:0] stable_count [0:15];
    reg [3:0] index;
    reg [15:0] captured;
    reg [1:0] data_sync;
    integer k;
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) data_sync<=2'b11;
        else data_sync<={data_sync[0],serial_data};
    end
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin
            load_n<=1;shift_clk<=0;keys<=0;frame_valid<=0;ready<=0;
            state<=IDLE;divider<=0;idle_count<=0;index<=0;captured<=0;startup_frames<=0;
            for(k=0;k<16;k=k+1)stable_count[k]<=0;
        end else begin
            frame_valid<=0;
            if(state==IDLE) begin
                if(idle_count==SCAN_IDLE_CYCLES-1) begin
                    idle_count<=0;load_n<=0;divider<=0;state<=LOAD;
                end else idle_count<=idle_count+1'b1;
            end else if(state==PUBLISH) begin
                for(k=0;k<16;k=k+1) begin
                    if(captured[k]==keys[k])stable_count[k]<=0;
                    else if(stable_count[k]==DEBOUNCE_FRAMES-1)begin
                        keys[k]<=captured[k];stable_count[k]<=0;
                    end else stable_count[k]<=stable_count[k]+1'b1;
                end
                if(!ready)begin
                    if(startup_frames==DEBOUNCE_FRAMES-1)ready<=1;
                    else startup_frames<=startup_frames+1'b1;
                end
                frame_valid<=1;state<=IDLE;
            end else if(divider==CLK_DIV_CYCLES-1) begin
                divider<=0;
                case(state)
                    LOAD: begin load_n<=1;index<=0;state<=SAMPLE;end
                    SAMPLE: begin
                        captured[index]<=~data_sync[1];
                        if(index==15)state<=PUBLISH;
                        else begin shift_clk<=1;state<=HIGH;end
                    end
                    HIGH: begin shift_clk<=0;index<=index+1'b1;state<=SAMPLE;end
                    default: state<=IDLE;
                endcase
            end else divider<=divider+1'b1;
        end
    end
endmodule
`default_nettype wire
