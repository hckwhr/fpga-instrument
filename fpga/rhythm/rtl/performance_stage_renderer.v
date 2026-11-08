`default_nettype none
// One-cycle, frame-atomic HDMI performance surface. Fixed 12 lanes match the
// physical keyboard; no moving hit targets and no UI work in the audio domain.
module performance_stage_renderer(
    input wire clk,reset_n,frame_start,status_update,
    input wire [10:0] x,
    input wire [9:0] y,
    input wire de,
    input wire [67:0] status_payload,
    input wire [12:0] guide_payload,
    output reg [17:0] rgb
);
    reg [80:0] shadow,active;
    always @(posedge clk or negedge reset_n)begin
        if(!reset_n)begin shadow<=0;active<=0;end
        else begin
            if(status_update)shadow<={guide_payload,status_payload};
            if(frame_start)begin
                active<=status_update?{guide_payload,status_payload}:shadow;
            end
        end
    end
    wire [11:0] held=active[23] ? 12'd0 : active[67:56];
    wire [11:0] guide=active[79:68];
    reg [17:0] color;
    integer k;
    always @*begin
        color={6'd63,6'd63,6'd63};
        // Large paper keys and a restrained activity ribbon. Visualization
        // panels above remain supplied by the existing spectrum/XY renderer.
        if(y>=10'd100 && y<10'd220 && x>=11'd16 && x<11'd784)
            color={6'd47,6'd51,6'd52};
        for(k=0;k<12;k=k+1)begin
            if(x>=16+k*64 && x<78+k*64 && y>=100 && y<218)begin
                color=held[k] ? {6'd31,6'd48,6'd44} : {6'd63,6'd63,6'd61};
                if(y<108 && guide[k])color={6'd25,6'd43,6'd51};
                if(y>=202)color=held[k] ? {6'd25,6'd39,6'd37} : {6'd53,6'd56,6'd55};
            end
            if(x>=20+k*64 && x<74+k*64 && y>=42 && y<84 && held[k])
                color={6'd39,6'd51,6'd49};
            if(x>=20+k*64 && x<74+k*64 && y>=80 && y<88 && guide[k])
                color={6'd25,6'd43,6'd51};
        end
        // Black key caps locate the two octave groups; pressure-key hit
        // positions remain the twelve white-key columns.
        for(k=0;k<11;k=k+1)begin
            if(k!=2 && k!=6 && k!=9 && x>=64+k*64 && x<92+k*64 && y>=100 && y<166)
                color=y<159 ? {6'd12,6'd14,6'd17} : {6'd7,6'd9,6'd12};
        end
        if(y==220 && x>=16 && x<784)color={6'd36,6'd46,6'd47};
        if(y>=24 && y<28 && x>=16 && x<784)color={6'd28,6'd41,6'd44};
    end
    always @(posedge clk or negedge reset_n)
        if(!reset_n)rgb<=0;
        else rgb<=de?color:18'd0;
endmodule
`default_nettype wire
