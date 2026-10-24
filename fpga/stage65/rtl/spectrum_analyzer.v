`default_nettype none
// 128 exact DFT frequencies k=1..128, 1024 samples at Fs=48000.53 Hz.
// Periodic Hann window. Two shared MACs process every bin within 900 clocks,
// below the fixed 1024-clock audio slot. No feedback/backpressure to audio.
// This is a band-limited DFT display, not a full-band FFT or peak-count proof.
module spectrum_analyzer #(
    // A one-frame quiet gap halves the DFT switching activity while keeping
    // the LCD update cadence below 50 ms. Testbenches use the default 0.
    parameter integer FRAME_GAP_SAMPLES = 0
) (
    input wire clk, reset_n, sample_strobe,
    input wire signed [15:0] sample_in,
    output reg [1023:0] levels,
    output reg frame_valid,
    output reg [7:0] deadline_misses
);
    reg signed [15:0] cosine[0:1023], sine[0:1023];
    reg [15:0] window[0:1023];
    `include "visual_coefficients.vh"
    reg signed [41:0] accum_re[0:127], accum_im[0:127];
    reg signed [41:0] old_re,old_im,sum_re,sum_im;
    reg signed [15:0] input_hold,windowed,cos_hold,sin_hold;
    reg [15:0] win_hold;
    reg signed [32:0] window_product;
    reg signed [31:0] product_re,product_im;
    reg [41:0] abs_re,abs_im;
    reg [42:0] magnitude;
    reg [1023:0] next_levels;
    reg [9:0] sample_index,phase;
    reg [6:0] bin_index;
    reg [3:0] step;
    reg frame_skip;
    wire signed [41:0] term_re={{10{product_re[31]}},product_re};
    wire signed [41:0] term_im={{10{product_im[31]}},product_im};

    // Relative logarithmic height, 0..80. Suppress <8 PCM equivalent.
    function [7:0] bar_height;
        input [19:0] amplitude;
        integer b;
        reg [7:0] result;
        begin
            result=0;
            for(b=3;b<20;b=b+1)
                if(amplitude[b]) result=(b-2)*5+((amplitude>>(b-2)) & 3);
            bar_height=(result>80)?8'd80:result;
        end
    endfunction

    // Synchronous memory access; reset metadata, never the RAM arrays.
    always @(posedge clk) begin
        if(step==3)begin
            old_re<=accum_re[bin_index];old_im<=accum_im[bin_index];
            cos_hold<=cosine[phase];sin_hold<=sine[phase];
        end
        if(step==6)begin
            accum_re[bin_index]<=sum_re;accum_im[bin_index]<=sum_im;
        end
    end
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n)begin
            levels<=0;next_levels<=0;frame_valid<=0;deadline_misses<=0;
            sample_index<=0;phase<=0;bin_index<=0;step<=0;
            frame_skip<=1'b0;
            input_hold<=0;windowed<=0;win_hold<=0;window_product<=0;
            product_re<=0;product_im<=0;sum_re<=0;sum_im<=0;
            abs_re<=0;abs_im<=0;magnitude<=0;
        end else begin
            frame_valid<=0;
            if(sample_strobe && step!=0 && deadline_misses!=255)
                deadline_misses<=deadline_misses+8'd1;
            case(step)
                0:if(sample_strobe)begin
                    if(frame_skip)begin
                        if(sample_index==1023)begin
                            frame_skip<=1'b0;
                            sample_index<=10'd0;
                        end else begin
                            sample_index<=sample_index+10'd1;
                        end
                    end
                    else begin
                        input_hold<=sample_in;win_hold<=window[sample_index];step<=1;
                    end
                end
                1:begin window_product<=input_hold*$signed({1'b0,win_hold});step<=2;end
                2:begin windowed<=window_product[30:15];phase<=sample_index;bin_index<=0;step<=3;end
                3:step<=4;
                4:begin product_re<=windowed*cos_hold;product_im<=windowed*sin_hold;step<=5;end
                5:begin
                    sum_re<=(sample_index==0)?term_re:old_re+term_re;
                    sum_im<=(sample_index==0)?term_im:old_im+term_im;step<=6;
                end
                6:begin abs_re<=sum_re[41]?-sum_re:sum_re;abs_im<=sum_im[41]?-sum_im:sum_im;step<=7;end
                7:begin magnitude<={1'b0,abs_re}+{1'b0,abs_im};step<=8;end
                8:begin
                    if(sample_index==1023)next_levels[{bin_index,3'b000} +: 8]<=bar_height(magnitude[42:23]);
                    step<=9;
                end
                9:begin
                    if(bin_index==127)begin
                        if(sample_index==1023)begin
                            levels<=next_levels;frame_valid<=1;
                            sample_index<=10'd0;
                            frame_skip<=FRAME_GAP_SAMPLES>0;
                        end else begin
                            sample_index<=sample_index+10'd1;
                        end
                        step<=0;
                    end else begin bin_index<=bin_index+7'd1;phase<=phase+sample_index;step<=3;end
                end
                default:step<=0;
            endcase
        end
    end
endmodule
`default_nettype wire
