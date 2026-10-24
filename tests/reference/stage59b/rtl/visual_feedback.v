`default_nettype none
// Pixel-domain panels. Input dry/wet pair is one coherent audio-domain
// snapshot. XY bitmap has explicit capture/display ownership and frame swap.
// The newest sample is committed once per LCD frame as a moving cursor; the
// existing double-buffered bitmap keeps the trace frame-atomic.
// Two RGB stages, matched by two sync stages in av_top.
module visual_feedback (
    input wire clk,reset_n,frame_start,enable,
    input wire [10:0] x,
    input wire [9:0] y,
    input wire [1023:0] spectrum,
    input wire spectrum_update,
    input wire [31:0] audio_pair,
    input wire audio_pair_valid,
    output reg overlay,
    output reg [17:0] rgb
);
    reg [1023:0] spectrum_shadow,spectrum_active;
    reg [31:0] label_rom[0:1535];
    `include "visual_labels.vh"
    reg xy_mem[0:32767];
    reg capture_bank,display_bank,capture_ready,display_valid;
    reg [13:0] clear_address;
    reg clearing;
    reg [9:0] pair_count;
    wire [6:0] point_x=audio_pair[31:25]^7'h40;
    wire [6:0] point_y=~(audio_pair[15:9]^7'h40);
    wire [14:0] write_point={capture_bank,point_y,point_x};
    wire xy_region=x>=552 && x<776 && y>=256 && y<464;
    wire [10:0] xy_x=x-11'd552;
    wire [9:0] xy_y=y-10'd256;
    // 2x pixels, 112x104 visible central crop of a 128x128 amplitude map.
    wire [6:0] read_x=xy_x[7:1]+7'd8;
    wire [6:0] read_y=xy_y[7:1]+7'd12;
    reg xy_pixel;
    reg [6:0] live_x,live_y,marker_x,marker_y;
    reg live_valid,live_frame_seen,marker_valid,marker_pixel;
    wire spectrum_region=x>=16 && x<528 && y>=362 && y<446;
    wire [10:0] sx=x-11'd16;
    wire [6:0] bin=sx[8:2];
    reg [7:0] height;
    reg [31:0] label_word;
    reg [10:0] label_address;
    reg [5:0] label_y;
    wire [10:0] label_x=x-11'd16;
    wire header=(y>=234 && y<252) || (y>=340 && y<360 && x<528) ||
        (y>=448 && y<466 && x<528);
    reg header_q,xy_region_q,spectrum_region_q,enable_q,display_enabled;
    reg [10:0] x_q;
    reg [9:0] y_q;
    reg [4:0] label_bit;
    always @* begin
        label_y=0;
        if(y>=448)label_y=y[5:0]-6'd22;
        else if(y>=340)label_y=y[5:0];
        else label_y=y[5:0]-6'd42;
        label_address={5'd0,label_y}*11'd24+label_x[10:5];
    end
    always @(posedge clk)begin
        label_word<=label_rom[label_address];
        height<=spectrum_active[{bin,3'b000} +: 8];
        xy_pixel<=xy_mem[{display_bank,read_y,read_x}];
        if(!reset_n)begin
            xy_pixel<=1'b0;
            live_x<=7'd64;live_y<=7'd64;marker_x<=7'd64;marker_y<=7'd64;
            live_valid<=1'b0;live_frame_seen<=1'b0;
            marker_valid<=1'b0;marker_pixel<=1'b0;
        end else begin
            // The CDC pulse is already in the pixel clock domain. Keep the
            // latest point and remember whether this frame saw live audio.
            if(audio_pair_valid)begin
                live_x<=point_x;live_y<=point_y;
                live_valid<=1'b1;live_frame_seen<=1'b1;
            end
            if(frame_start)begin
                // A sample arriving on this boundary belongs to this frame.
                // Consume it directly instead of clearing its seen flag unseen.
                marker_x<=audio_pair_valid ? point_x : live_x;
                marker_y<=audio_pair_valid ? point_y : live_y;
                marker_valid<=audio_pair_valid || (live_valid && live_frame_seen);
                live_frame_seen<=1'b0;
            end
            marker_pixel<=marker_valid && xy_region &&
                (read_x==marker_x) && (read_y==marker_y);
            if(clearing)begin
                xy_mem[{capture_bank,clear_address}]<=1'b0;
            end else if(!capture_ready && audio_pair_valid)begin
                xy_mem[write_point]<=1'b1;
            end
        end
    end
    always @(posedge clk or negedge reset_n)begin
        if(!reset_n)begin
            spectrum_shadow<=0;spectrum_active<=0;
            capture_bank<=0;display_bank<=1;capture_ready<=0;display_valid<=0;
            clearing<=1;clear_address<=0;pair_count<=0;
            header_q<=0;xy_region_q<=0;spectrum_region_q<=0;enable_q<=0;display_enabled<=0;
            x_q<=0;y_q<=0;label_bit<=0;overlay<=0;rgb<=0;
        end else begin
            if(spectrum_update)spectrum_shadow<=spectrum;
            if(frame_start)begin
                spectrum_active<=spectrum_update?spectrum:spectrum_shadow;
                display_enabled<=enable;
            end
            if(clearing)begin
                if(clear_address==14'd16383)begin clearing<=0;pair_count<=0;end
                else clear_address<=clear_address+14'd1;
            end else if(frame_start && capture_ready)begin
                display_bank<=capture_bank;display_valid<=1;capture_bank<=~capture_bank;
                capture_ready<=0;clearing<=1;clear_address<=0;
            end else if(audio_pair_valid && !capture_ready)begin
                if(pair_count==1023)capture_ready<=1;
                else pair_count<=pair_count+10'd1;
            end
            header_q<=header && x>=16 && x<784;
            xy_region_q<=xy_region;spectrum_region_q<=spectrum_region;
            enable_q<=display_enabled;x_q<=x;y_q<=y;label_bit<=~label_x[4:0];
            overlay<=enable_q && (header_q || xy_region_q || spectrum_region_q);
            rgb<={6'd1,6'd5,6'd8};
            if(header_q)begin
                rgb<=label_word[label_bit]?{6'd38,6'd56,6'd61}:{6'd1,6'd3,6'd5};
            end else if(spectrum_region_q)begin
                if(y_q==445 || x_q==16 || x_q==527)
                    rgb<={6'd4,6'd35,6'd44};
                else if(height!=0 && y_q>=10'd444-{2'd0,height} && x_q[1:0]!=3)
                    rgb<={6'd7,6'd54,6'd61};
                else if(x_q[6:0]==16 || y_q==404 || y_q==364)
                    rgb<={6'd2,6'd14,6'd20};
            end else if(xy_region_q)begin
                if(x_q==552 || x_q==775 || y_q==256 || y_q==463)
                    rgb<={6'd4,6'd35,6'd44};
                else if(display_valid && marker_valid && marker_pixel)
                    rgb<={6'd63,6'd50,6'd63};
                else if(display_valid && xy_pixel)
                    rgb<={6'd55,6'd18,6'd61};
                else if(x_q==664 || y_q==360)rgb<={6'd2,6'd14,6'd20};
            end
        end
    end
endmodule
`default_nettype wire
