`default_nettype none
// Deterministic formatter. Inputs latched at start; token, CRC and output byte
// remain stable when tx_ready is low. Emits LF after body CRC, never CR.
module stage54c_song_upload_reply #(parameter integer CONTROL_ENABLE=0) (
    input wire clk, reset_n, start,
    input wire [63:0] session_id,
    input wire [15:0] sequence_id,
    input wire [2:0] operation,
    input wire [3:0] error_code,
    input wire [9:0] count,
    input wire [15:0] song_crc,
    input wire [53:0] control_status,
    output wire [7:0] tx_data,
    output wire tx_valid,
    input wire tx_ready,
    output reg done
);
    localparam [1:0] IDLE=0, LOAD=1, SEND=2;
    reg [1:0] state;
    reg [4:0] step;
    reg [4:0] remaining;
    reg [127:0] token;
    reg [63:0] sid;
    reg [15:0] seq, scrc, crc;
    reg [2:0] op;
    reg [3:0] err;
    reg [9:0] n;
    reg [53:0] status;
    assign tx_data=token[127:120];
    assign tx_valid=state==SEND;
    function [7:0] hexchar;
        input [3:0] v;
        begin hexchar=v<10 ? 8'd48+{4'd0,v} : 8'd55+{4'd0,v}; end
    endfunction
    function [127:0] hex64;
        input [63:0] v;
        integer i;
        begin for(i=0;i<16;i=i+1) hex64[127-i*8 -: 8]=hexchar(v[63-i*4 -: 4]); end
    endfunction
    function [4:0] digits;
        input [15:0] v;
        begin digits=v>=10000 ? 5 : v>=1000 ? 4 : v>=100 ? 3 : v>=10 ? 2 : 1; end
    endfunction
    function [127:0] decimal_token;
        input [15:0] v;
        reg [39:0] d;
        reg [15:0] d4,d3,d2,d1,d0;
        begin
            d4=v/16'd10000; d3=(v/16'd1000)%16'd10; d2=(v/16'd100)%16'd10;
            d1=(v/16'd10)%16'd10; d0=v%16'd10;
            d={8'd48+d4[7:0],8'd48+d3[7:0],8'd48+d2[7:0],8'd48+d1[7:0],8'd48+d0[7:0]};
            decimal_token={d,88'd0} << ((5-digits(v))*8);
        end
    endfunction
    function [15:0] crc_byte;
        input [15:0] old_crc;
        input [7:0] value;
        reg [15:0] c;
        integer i;
        begin c=old_crc^{value,8'd0}; for(i=0;i<8;i=i+1)c=c[15]?(c<<1)^16'h1021:c<<1; crc_byte=c; end
    endfunction
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin state<=IDLE; step<=0; remaining<=0; token<=0; sid<=0; seq<=0; scrc<=0; crc<=16'hffff; op<=0; err<=0; n<=0; status<=0; done<=0; end
        else begin
            done<=0;
            case(state)
                IDLE: if(start) begin sid<=session_id; seq<=sequence_id; op<=operation; err<=error_code; n<=count; scrc<=song_crc; status<=control_status; crc<=16'hffff; step<=0; state<=LOAD; end
                LOAD: begin
                    state<=SEND;
                    case(step)
                        0: begin token<=err==0 ? {"ACK2,",88'd0} : {"ERR2,",88'd0}; remaining<=5; end
                        1: begin token<=hex64(sid); remaining<=16; end
                        2,4,8,12,14,16,18,20: begin token<={8'd44,120'd0}; remaining<=1; end
                        3: begin token<=decimal_token(seq); remaining<=digits(seq); end
                        5: case(op)
                            0: begin token<={"CAPS",96'd0}; remaining<=4; end
                            1: begin token<={"BEGIN",88'd0}; remaining<=5; end
                            2: begin token<={"DATA",96'd0}; remaining<=4; end
                            3: begin token<={"COMMIT",80'd0}; remaining<=6; end
                            4: begin token<={"ABORT",88'd0}; remaining<=5; end
                            5: begin token<={"PLAY",96'd0}; remaining<=4; end
                            6: begin token<={"STOP",96'd0}; remaining<=4; end
                            default: begin token<={"STATUS",80'd0}; remaining<=6; end
                        endcase
                        6: if(err!=0) begin
                            case(err)
                                1: begin token<={",BUSY",88'd0}; remaining<=5; end
                                2: begin token<={",ABI",96'd0}; remaining<=4; end
                                3: begin token<={",CAPACITY",56'd0}; remaining<=9; end
                                4: begin token<={",SESSION",64'd0}; remaining<=8; end
                                5: begin token<={",SEQUENCE",56'd0}; remaining<=9; end
                                6: begin token<={",CONFLICT",56'd0}; remaining<=9; end
                                7: begin token<={",OFFSET",72'd0}; remaining<=7; end
                                8: begin token<={",FORMAT",72'd0}; remaining<=7; end
                                9: begin token<={",STATE",80'd0}; remaining<=6; end
                                11: begin token<={",NOSCORE",64'd0}; remaining<=8; end
                                default: begin token<={",CONTENT",64'd0}; remaining<=8; end
                            endcase
                        end else case(op)
                            0: if(CONTROL_ENABLE!=0) begin token<={",12,512,8,1",40'd0}; remaining<=11; end
                               else begin token<={",12,512,8",56'd0}; remaining<=9; end
                            1: begin token<={",0",112'd0}; remaining<=2; end
                            4: begin step<=10; state<=LOAD; end
                            default: begin token<={8'd44,120'd0}; remaining<=1; end
                        endcase
                        7: begin token<=decimal_token({6'd0,n}); remaining<=digits({6'd0,n}); end
                        9: begin token<={hexchar(scrc[15:12]),hexchar(scrc[11:8]),hexchar(scrc[7:4]),hexchar(scrc[3:0]),96'd0}; remaining<=4; end
                        10: begin token<={8'd44,hexchar(crc[15:12]),hexchar(crc[11:8]),hexchar(crc[7:4]),hexchar(crc[3:0]),8'd10,80'd0}; remaining<=6; end
                        11: begin token<=decimal_token({13'd0,status[53:51]}); remaining<=1; end
                        13: begin token<=decimal_token({8'd0,status[50:43]}); remaining<=digits({8'd0,status[50:43]}); end
                        15: begin token<=decimal_token({6'd0,status[42:33]}); remaining<=digits({6'd0,status[42:33]}); end
                        17: begin token<={hexchar(status[32:29]),hexchar(status[28:25]),hexchar(status[24:21]),hexchar(status[20:17]),96'd0}; remaining<=4; end
                        19: begin token<={7'd24,status[16],120'd0}; remaining<=1; end
                        21: begin token<={hexchar(status[15:12]),hexchar(status[11:8]),hexchar(status[7:4]),hexchar(status[3:0]),96'd0}; remaining<=4; end
                        default: begin state<=IDLE; done<=1; end
                    endcase
                end
                SEND: if(tx_ready) begin
                    token<={token[119:0],8'd0}; remaining<=remaining-1'b1;
                    if(step!=10) crc<=crc_byte(crc,tx_data);
                    if(remaining==1) begin
                        state<=LOAD;
                        if(step==10) begin state<=IDLE; done<=1; end
                        else if(step==6 && err==0 && op>=5) step<=11;
                        else if((step==6 && (err!=0 || op==0 || op==1)) || (step==7 && op==2) || step==9 || step==21) step<=10;
                        else step<=step+1'b1;
                    end
                end
                default: state<=IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
