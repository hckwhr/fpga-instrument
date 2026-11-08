`default_nettype none
// Pixel-domain panels. Input dry/wet pair is one coherent audio-domain
// snapshot. Two RGB stages, matched by two sync stages in av_top.
//
// The XY panel is a phase portrait with phosphor persistence:
//
//  - PT8211 is fed {sample,sample}, so there are no independent stereo
//    channels, and dry against wet is nearly collinear. Both degenerate into
//    a 45-degree line. Plotting x(t-TAU) against x(t) instead traces a closed
//    loop once per period, so pitch and chords each draw their own figure.
//  - Cells hold a 3-bit intensity written at full brightness and decayed by a
//    background scan, which only runs while the panel is not being read, so
//    the single read port is never contended. New points always win the write
//    port; a point dropping one decay step is invisible.
//  - A per-frame peak sets a shift so quiet playing still fills the box.
//    Below the noise floor the trace is suppressed and only the live cursor
//    remains, which is also what silence should look like.
module visual_feedback #(parameter integer LIGHT_UI_ENABLE=0, PERFORMANCE_UI=0) (
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
    localparam integer TAU=32;              // delay in audio samples
    localparam integer DECAY_PRESCALE=64;    // free pixels per decay step
    reg [2:0] xy_mem[0:16383];
    reg signed [9:0] history[0:TAU-1];
    reg [9:0] frame_peak;
    reg [2:0] shift_left,shift_right;
    reg trace_active;
    reg [13:0] decay_address;
    reg [5:0] decay_divider;
    reg decay_phase;
    wire signed [9:0] sample_now=audio_pair[15:6];
    wire signed [9:0] sample_old=history[TAU-1];
    wire [9:0] magnitude_now=sample_now[9] ? (~sample_now)+10'd1 : sample_now;
    wire xy_region=x>=552 && x<776 && y>=256 && y<464;
    wire [10:0] xy_x=x-11'd552;
    wire [9:0] xy_y=y-10'd256;
    // 2x pixels, 112x104 visible central crop of a 128x128 amplitude map.
    wire [6:0] read_x=xy_x[7:1]+7'd8;
    wire [6:0] read_y=xy_y[7:1]+7'd12;
    // Scale to the visible half-width before offsetting to the map centre.
    // Clamp to the visible crop so the loop cannot run outside the box.
    function signed [10:0] scaled;
        input signed [9:0] value;
        input signed [10:0] limit;
        input [2:0] left_shift,right_shift;
        reg signed [13:0] wide;
        begin
            wide = (left_shift!=3'd0) ? (value<<<left_shift) : (value>>>right_shift);
            scaled = (wide>limit) ? limit : (wide<-limit) ? -limit : wide[10:0];
        end
    endfunction
    // Explicit gain arguments make a gain/reset change reevaluate even while
    // the audio sample stays at zero; no hidden function sensitivity inputs.
    wire signed [8:0] plot_x=9'sd64+scaled(sample_old,11'sd55,shift_left,shift_right);
    wire signed [8:0] plot_y=9'sd64-scaled(sample_now,11'sd51,shift_left,shift_right);
    wire [6:0] point_x=plot_x[6:0];
    wire [6:0] point_y=plot_y[6:0];
    reg [2:0] xy_pixel;
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
    integer tap;
    always @(posedge clk)begin
        label_word<=label_rom[label_address];
        height<=spectrum_active[{bin,3'b000} +: 8];
        // One read port, shared: the panel owns it while it is on screen and
        // the decay scan owns it the rest of the time.
        xy_pixel<=xy_mem[xy_region ? {read_y,read_x} : decay_address];
        if(!reset_n)begin
            xy_pixel<=3'd0;
            live_x<=7'd64;live_y<=7'd64;marker_x<=7'd64;marker_y<=7'd64;
            live_valid<=1'b0;live_frame_seen<=1'b0;
            marker_valid<=1'b0;marker_pixel<=1'b0;
            for(tap=0;tap<TAU;tap=tap+1)history[tap]<=10'sd0;
        end else begin
            // The CDC pulse is already in the pixel clock domain. Keep the
            // latest point and remember whether this frame saw live audio.
            if(audio_pair_valid)begin
                history[0]<=sample_now;
                for(tap=1;tap<TAU;tap=tap+1)history[tap]<=history[tap-1];
                live_x<=point_x;live_y<=point_y;
                live_valid<=1'b1;live_frame_seen<=1'b1;
            end
            if(frame_start)begin
                // A sample arriving on this boundary belongs to this frame.
                // Consume it directly instead of dropping its seen flag unseen.
                marker_x<=audio_pair_valid ? point_x : live_x;
                marker_y<=audio_pair_valid ? point_y : live_y;
                marker_valid<=audio_pair_valid || (live_valid && live_frame_seen);
                live_frame_seen<=1'b0;
            end
            marker_pixel<=marker_valid && xy_region &&
                (read_x==marker_x) && (read_y==marker_y);
            // A new point always wins the write port. Losing one decay step is
            // invisible; losing a point would break the trace.
            if(audio_pair_valid && trace_active)begin
                xy_mem[{point_y,point_x}]<=3'd7;
            end else if(!xy_region && decay_phase && xy_pixel!=3'd0)begin
                xy_mem[decay_address]<=xy_pixel-3'd1;
            end
        end
    end
    // The divider is held in reset while the panel is on screen, so a decay
    // write only happens after DECAY_PRESCALE consecutive free pixels. That
    // guarantees xy_pixel was last loaded from decay_address, not the panel.
    always @(posedge clk or negedge reset_n)begin
        if(!reset_n)begin
            decay_address<=14'd0;decay_divider<=6'd0;decay_phase<=1'b0;
        end else if(xy_region)begin
            decay_divider<=6'd0;decay_phase<=1'b0;
        end else if(decay_phase)begin
            decay_phase<=1'b0;decay_address<=decay_address+14'd1;
        end else if(decay_divider==DECAY_PRESCALE-1)begin
            decay_divider<=6'd0;decay_phase<=1'b1;
        end else begin
            decay_divider<=decay_divider+6'd1;
        end
    end
    // Per-frame peak drives the shift so quiet playing still fills the box.
    // Significant bits of the peak accumulated so far this frame. Reading the
    // accumulator directly, rather than a copy latched on the same edge, keeps
    // the gain one frame behind the audio instead of two.
    reg [3:0] peak_bits;
    integer b;
    always @* begin
        peak_bits=4'd0;
        for(b=0;b<10;b=b+1)if(frame_peak[b])peak_bits=b[3:0]+4'd1;
    end
    always @(posedge clk or negedge reset_n)begin
        if(!reset_n)begin
            frame_peak<=10'd0;
            shift_left<=3'd0;shift_right<=3'd0;trace_active<=1'b0;
        end else begin
            if(audio_pair_valid && magnitude_now>frame_peak)frame_peak<=magnitude_now;
            if(frame_start)begin
                frame_peak<=10'd0;
                // Six significant bits put the scaled magnitude near 48, just
                // inside the 56-pixel half-width. Below four bits the signal is
                // at the noise floor and is not worth amplifying.
                trace_active<=(peak_bits>=4'd4);
                shift_right<=(peak_bits>4'd6) ? (peak_bits[2:0]-3'd6) : 3'd0;
                shift_left<=(peak_bits>=4'd4 && peak_bits<4'd6)
                            ? (3'd6-peak_bits[2:0]) : 3'd0;
            end
        end
    end
    always @(posedge clk or negedge reset_n)begin
        if(!reset_n)begin
            spectrum_shadow<=0;spectrum_active<=0;
            header_q<=0;xy_region_q<=0;spectrum_region_q<=0;enable_q<=0;display_enabled<=0;
            x_q<=0;y_q<=0;label_bit<=0;overlay<=0;rgb<=0;
        end else begin
            if(spectrum_update)spectrum_shadow<=spectrum;
            if(frame_start)begin
                spectrum_active<=spectrum_update?spectrum:spectrum_shadow;
                display_enabled<=enable;
            end
            header_q<=header && x>=16 && x<784;
            xy_region_q<=xy_region;spectrum_region_q<=spectrum_region;
            enable_q<=display_enabled;x_q<=x;y_q<=y;label_bit<=~label_x[4:0];
            overlay<=enable_q && (header_q || xy_region_q || spectrum_region_q);
            rgb<=PERFORMANCE_UI ? {6'd63,6'd63,6'd63} : (LIGHT_UI_ENABLE ? {6'd63,6'd63,6'd61} : {6'd1,6'd5,6'd8});
            if(header_q)begin
                rgb<=PERFORMANCE_UI ? {6'd63,6'd63,6'd63} : label_word[label_bit]?(LIGHT_UI_ENABLE ? {6'd22,6'd28,6'd30} : {6'd38,6'd56,6'd61}):(LIGHT_UI_ENABLE ? {6'd60,6'd60,6'd58} : {6'd1,6'd3,6'd5});
            end else if(spectrum_region_q)begin
                if(y_q==445 || x_q==16 || x_q==527)
                    rgb<=(LIGHT_UI_ENABLE ? {6'd43,6'd47,6'd47} : {6'd4,6'd35,6'd44});
                else if(height!=0 && y_q>=10'd444-{2'd0,height} && x_q[1:0]!=3)
                    rgb<=PERFORMANCE_UI ? {6'd12,6'd32,6'd55} : (LIGHT_UI_ENABLE ? {6'd27,6'd41,6'd34} : {6'd7,6'd54,6'd61});
                else if(x_q[6:0]==16 || y_q==404 || y_q==364)
                    rgb<=(LIGHT_UI_ENABLE ? {6'd53,6'd55,6'd54} : {6'd2,6'd14,6'd20});
            end else if(xy_region_q)begin
                if(x_q==552 || x_q==775 || y_q==256 || y_q==463)
                    rgb<=(LIGHT_UI_ENABLE ? {6'd43,6'd47,6'd47} : {6'd4,6'd35,6'd44});
                else if(marker_valid && marker_pixel)
                    rgb<=PERFORMANCE_UI ? {6'd35,6'd14,6'd50} : (LIGHT_UI_ENABLE ? {6'd21,6'd34,6'd39} : {6'd63,6'd63,6'd40});
                else if(xy_pixel!=3'd0)begin
                    // Phosphor ramp: the freshest trace is near white and older
                    // passes fade through violet.
                    if(PERFORMANCE_UI)begin
                        case(xy_pixel)
                            7:rgb<={6'd35,6'd14,6'd50};
                            6:rgb<={6'd39,6'd21,6'd52};
                            5:rgb<={6'd43,6'd28,6'd54};
                            4:rgb<={6'd47,6'd35,6'd56};
                            3:rgb<={6'd51,6'd42,6'd58};
                            2:rgb<={6'd55,6'd49,6'd60};
                            default:rgb<={6'd59,6'd56,6'd62};
                        endcase
                    end else case(xy_pixel)
                        3'd7:rgb<=(LIGHT_UI_ENABLE ? {6'd21,6'd34,6'd39} : {6'd63,6'd52,6'd63});
                        3'd6:rgb<=(LIGHT_UI_ENABLE ? {6'd27,6'd39,6'd43} : {6'd57,6'd34,6'd62});
                        3'd5:rgb<=(LIGHT_UI_ENABLE ? {6'd33,6'd43,6'd46} : {6'd49,6'd22,6'd58});
                        3'd4:rgb<=(LIGHT_UI_ENABLE ? {6'd39,6'd47,6'd49} : {6'd41,6'd16,6'd50});
                        3'd3:rgb<=(LIGHT_UI_ENABLE ? {6'd45,6'd51,6'd52} : {6'd32,6'd12,6'd42});
                        3'd2:rgb<=(LIGHT_UI_ENABLE ? {6'd51,6'd55,6'd55} : {6'd23,6'd8,6'd33});
                        default:rgb<=(LIGHT_UI_ENABLE ? {6'd57,6'd59,6'd58} : {6'd14,6'd6,6'd23});
                    endcase
                end
                else if(x_q==664 || y_q==360)rgb<=(LIGHT_UI_ENABLE ? {6'd53,6'd55,6'd54} : {6'd2,6'd14,6'd20});
            end
        end
    end
endmodule
`default_nettype wire
