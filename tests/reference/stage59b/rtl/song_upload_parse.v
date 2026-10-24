`default_nettype none
// Reads a held CRC-checked synchronous RAM line one byte/two clocks.
// The wait edge after each address change precedes byte consumption.
// Numeric fields are canonical
// decimal; hex is uppercase. No output may be executed until done && valid.
module song_upload_parse (
    input wire clk, reset_n, start,
    input wire [7:0] frame_length,
    output reg [7:0] frame_index,
    input wire [7:0] frame_byte,
    output reg done, valid,
    output reg [63:0] session_id,
    output reg [15:0] sequence_id,
    output reg [2:0] operation,
    output reg [23:0] arg0, arg1, arg2, arg3,
    output reg [15:0] song_crc,
    output reg [511:0] payload
);
    // CAPS=0 BEGIN=1 DATA=2 COMMIT=3 ABORT=4 PLAY=5 STOP=6 STATUS=7.
    reg running, finish_pending, bad, first_zero, read_wait;
    reg [3:0] field;
    reg [7:0] token_length;
    reg [63:0] token;
    reg [31:0] number;
    reg [511:0] hex_value;
    wire delimiter = frame_byte==8'd44 || frame_index==frame_length-8'd5;
    wire decimal_field = field==4'd2 ||
        (operation==3'd1 && field>=4'd4 && field<=4'd7) ||
        (operation==3'd2 && (field==4'd4 || field==4'd5)) ||
        (operation==3'd3 && field==4'd4) ||
        (operation==3'd5 && (field==4'd4 || field==4'd6));
    wire hex_field = field==4'd1 || (operation==3'd1 && field==4'd8) ||
        (operation==3'd2 && field==4'd6) || ((operation==3'd3 || operation==3'd5) && field==4'd5);
    wire hex_ok=(frame_byte>=8'd48 && frame_byte<=8'd57)||(frame_byte>=8'd65 && frame_byte<=8'd70);
    wire [7:0] hex_digit=frame_byte<=8'd57 ? frame_byte-8'd48 : frame_byte-8'd55;
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin
            running<=0; finish_pending<=0; bad<=0; first_zero<=0; read_wait<=0; field<=0; token_length<=0;
            token<=0; number<=0; hex_value<=0; frame_index<=0; done<=0; valid<=0;
            session_id<=0; sequence_id<=0; operation<=7; arg0<=0; arg1<=0; arg2<=0; arg3<=0; song_crc<=0; payload<=0;
        end else begin
            done<=0;
            if(start && !running) begin
                running<=1; finish_pending<=0; bad<=frame_length<8'd6; first_zero<=0; read_wait<=1;
                field<=0; token_length<=0; token<=0; number<=0; hex_value<=0; frame_index<=0; valid<=0;
                session_id<=0; sequence_id<=0; operation<=7; arg0<=0; arg1<=0; arg2<=0; arg3<=0; song_crc<=0; payload<=0;
            end else if(running && finish_pending) begin
                running<=0; done<=1;
                valid<=!bad && ((operation==0 && field==3) || (operation==1 && field==8) ||
                    (operation==2 && field==6 && arg1>=1 && arg1<=8 && token_length==arg1*24'd16) ||
                    (operation==3 && field==5) || (operation==4 && field==3) ||
                    (operation==5 && field==6) || (operation>=6 && field==3));
            end else if(running && read_wait) read_wait<=0;
            else if(running) begin
                read_wait<=1;
                if(frame_index>frame_length-8'd5 || field>8) begin bad<=1; finish_pending<=1; end
                else if(delimiter) begin
                    if(token_length==0) bad<=1;
                    case(field)
                        0: if(token_length!=5 || token!=64'h534f4e4732) bad<=1;
                        1: begin session_id<=hex_value[63:0]; if(token_length!=16) bad<=1; end
                        2: begin sequence_id<=number[15:0]; if(number>65535) bad<=1; end
                        3: begin
                            case(token)
                                64'h43415053: if(token_length==4) operation<=0; else bad<=1;
                                64'h424547494e: if(token_length==5) operation<=1; else bad<=1;
                                64'h44415441: if(token_length==4) operation<=2; else bad<=1;
                                64'h434f4d4d4954: if(token_length==6) operation<=3; else bad<=1;
                                64'h41424f5254: if(token_length==5) operation<=4; else bad<=1;
                                64'h504c4159: if(token_length==4) operation<=5; else bad<=1;
                                64'h53544f50: if(token_length==4) operation<=6; else bad<=1;
                                64'h535441545553: if(token_length==6) operation<=7; else bad<=1;
                                default: bad<=1;
                            endcase
                        end
                        4: arg0<=number[23:0];
                        5: if(operation==3 || operation==5) begin song_crc<=hex_value[15:0]; if(token_length!=4) bad<=1; end
                           else arg1<=number[23:0];
                        6: if(operation==2) payload<=hex_value; else arg2<=number[23:0];
                        7: arg3<=number[23:0];
                        8: begin song_crc<=hex_value[15:0]; if(token_length!=4) bad<=1; end
                        default: bad<=1;
                    endcase
                    if(frame_index==frame_length-8'd5) finish_pending<=1;
                    else begin
                        field<=field+1'b1; token_length<=0; token<=0; number<=0; hex_value<=0; first_zero<=0;
                        frame_index<=frame_index+1'b1;
                    end
                end else begin
                    if(token_length==8'd128) bad<=1;
                    else token_length<=token_length+1'b1;
                    token<={token[55:0],frame_byte};
                    if(decimal_field) begin
                        if(frame_byte<8'd48 || frame_byte>8'd57 || (token_length!=0 && first_zero) ||
                            number>32'd1677721 || (number==32'd1677721 && frame_byte>8'd53)) bad<=1;
                        // The guard above accepts only ASCII 0..9. Its low
                        // nibble is the digit; avoid a full-width subtract-48
                        // carry chain feeding the decimal accumulator DSP.
                        else number<=number*32'd10+{28'd0,frame_byte[3:0]};
                        if(token_length==0) first_zero<=frame_byte==8'd48;
                    end
                    if(hex_field) begin
                        if(!hex_ok) bad<=1;
                        hex_value<={hex_value[507:0],hex_digit[3:0]};
                    end
                    frame_index<=frame_index+1'b1;
                end
            end
        end
    end
endmodule
`default_nettype wire
