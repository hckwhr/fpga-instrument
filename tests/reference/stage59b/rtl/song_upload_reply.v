`default_nettype none
// Inputs are captured at start. SEND advances only on tx_ready; CRC and the
// presented byte hold under backpressure. LF follows the body CRC, never CR.
module song_upload_reply #(parameter integer CONTROL_ENABLE=0) (
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
    localparam [2:0] IDLE=0, LOAD=1, SEND=2, DECIMAL=3, ALIGN=4,
                     TEXT_FETCH=5, TEXT_LOAD=6;
    localparam [1:0] TEXT=0, HEX=1, DIGITS=2, TAIL=3;
    reg [2:0] state;
    reg [1:0] source;
    reg [4:0] step, remaining;
    reg [7:0] token;
    reg [63:0] sid;
    reg [15:0] seq, scrc, crc;
    reg [2:0] op;
    reg [3:0] err;
    reg [9:0] n;
    reg [53:0] status;
    reg [15:0] binary_shift;
    reg [19:0] bcd, corrected_bcd;
    reg [3:0] decimal_bit;
    reg [7:0] text_address, text_data;
    reg [7:0] text_rom[0:255];
    integer init_byte;
    initial begin
        for(init_byte=0;init_byte<256;init_byte=init_byte+1) text_rom[init_byte]=0;
        {text_rom[0],text_rom[1],text_rom[2],text_rom[3],text_rom[4]} = "ACK2,";
        {text_rom[5],text_rom[6],text_rom[7],text_rom[8],text_rom[9]} = "ERR2,";
        {text_rom[10],text_rom[11],text_rom[12],text_rom[13]} = "CAPS";
        {text_rom[14],text_rom[15],text_rom[16],text_rom[17],text_rom[18]} = "BEGIN";
        {text_rom[19],text_rom[20],text_rom[21],text_rom[22]} = "DATA";
        {text_rom[23],text_rom[24],text_rom[25],text_rom[26],text_rom[27],text_rom[28]} = "COMMIT";
        {text_rom[29],text_rom[30],text_rom[31],text_rom[32],text_rom[33]} = "ABORT";
        {text_rom[34],text_rom[35],text_rom[36],text_rom[37]} = "PLAY";
        {text_rom[38],text_rom[39],text_rom[40],text_rom[41]} = "STOP";
        {text_rom[42],text_rom[43],text_rom[44],text_rom[45],text_rom[46],text_rom[47]} = "STATUS";
        {text_rom[48],text_rom[49],text_rom[50],text_rom[51],text_rom[52]} = ",BUSY";
        {text_rom[53],text_rom[54],text_rom[55],text_rom[56]} = ",ABI";
        {text_rom[57],text_rom[58],text_rom[59],text_rom[60],text_rom[61],text_rom[62],text_rom[63],text_rom[64],text_rom[65]} = ",CAPACITY";
        {text_rom[66],text_rom[67],text_rom[68],text_rom[69],text_rom[70],text_rom[71],text_rom[72],text_rom[73]} = ",SESSION";
        {text_rom[74],text_rom[75],text_rom[76],text_rom[77],text_rom[78],text_rom[79],text_rom[80],text_rom[81],text_rom[82]} = ",SEQUENCE";
        {text_rom[83],text_rom[84],text_rom[85],text_rom[86],text_rom[87],text_rom[88],text_rom[89],text_rom[90],text_rom[91]} = ",CONFLICT";
        {text_rom[92],text_rom[93],text_rom[94],text_rom[95],text_rom[96],text_rom[97],text_rom[98]} = ",OFFSET";
        {text_rom[99],text_rom[100],text_rom[101],text_rom[102],text_rom[103],text_rom[104],text_rom[105]} = ",FORMAT";
        {text_rom[106],text_rom[107],text_rom[108],text_rom[109],text_rom[110],text_rom[111]} = ",STATE";
        {text_rom[112],text_rom[113],text_rom[114],text_rom[115],text_rom[116],text_rom[117],text_rom[118],text_rom[119]} = ",NOSCORE";
        {text_rom[120],text_rom[121],text_rom[122],text_rom[123],text_rom[124],text_rom[125],text_rom[126],text_rom[127]} = ",CONTENT";
        {text_rom[128],text_rom[129],text_rom[130],text_rom[131],text_rom[132],text_rom[133],text_rom[134],text_rom[135],text_rom[136],text_rom[137],text_rom[138]} = ",12,512,8,1";
        {text_rom[139],text_rom[140]} = ",0";
        {text_rom[141]} = ",";
    end
    // Synchronous, unreset ROM output permits BSRAM mapping. TEXT_FETCH
    // accounts for the address-to-data edge, TEXT_LOAD captures that byte.
    // Literal bytes incur two extra clocks, far below one UART bit time;
    // completed handshake byte sequences and CRC coverage remain unchanged.
    always @(posedge clk) text_data<=text_rom[text_address];
    wire [15:0] decimal_value=step==3 ? seq : step==7 ? {6'd0,n} :
        step==11 ? {13'd0,status[53:51]} : step==13 ? {8'd0,status[50:43]} : {6'd0,status[42:33]};
    integer digit;
    // Sixteen shift/add-3 clocks, then one fixed-slice alignment clock.
    always @* begin
        corrected_bcd=bcd;
        for(digit=0;digit<5;digit=digit+1)
            if(bcd[digit*4+:4]>=4'd5) corrected_bcd[digit*4+:4]=bcd[digit*4+:4]+4'd3;
    end
    assign tx_data=token;
    assign tx_valid=state==SEND;
    function [7:0] hexchar;
        input [3:0] v;
        begin hexchar=v<10 ? 8'd48+{4'd0,v} : 8'd55+{4'd0,v}; end
    endfunction
    function [15:0] crc_byte;
        input [15:0] old_crc;
        input [7:0] value;
        reg [15:0] c;
        integer i;
        begin c=old_crc^{value,8'd0}; for(i=0;i<8;i=i+1)c=c[15]?(c<<1)^16'h1021:c<<1; crc_byte=c; end
    endfunction
    reg [3:0] tail_nibble;
    always @* begin
        case(remaining)
            6:tail_nibble=crc[15:12];
            5:tail_nibble=crc[11:8];
            4:tail_nibble=crc[7:4];
            default:tail_nibble=crc[3:0];
        endcase
    end
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin
            state<=IDLE; source<=TEXT; step<=0; remaining<=0; token<=0;
            sid<=0; seq<=0; scrc<=0; crc<=16'hffff; op<=0; err<=0; n<=0; status<=0; done<=0;
            binary_shift<=0; bcd<=0; decimal_bit<=0; text_address<=0;
        end else begin
            done<=0;
            case(state)
                IDLE: if(start) begin
                    sid<=session_id; seq<=sequence_id; op<=operation; err<=error_code;
                    n<=count; scrc<=song_crc; status<=control_status;
                    crc<=16'hffff; step<=0; state<=LOAD;
                end
                LOAD: begin
                    state<=TEXT_FETCH; source<=TEXT;
                    case(step)
                        0: begin text_address<=err==0 ? 8'd0 : 8'd5; remaining<=5; end
                        1: begin source<=HEX; token<=hexchar(sid[63:60]); remaining<=16; state<=SEND; end
                        2,4,8,12,14,16,18,20: begin text_address<=141; remaining<=1; end
                        3,7,11,13,15: begin
                            binary_shift<=decimal_value; bcd<=0; decimal_bit<=0;
                            source<=DIGITS; state<=DECIMAL;
                        end
                        5: case(op)
                            0: begin text_address<=10; remaining<=4; end
                            1: begin text_address<=14; remaining<=5; end
                            2: begin text_address<=19; remaining<=4; end
                            3: begin text_address<=23; remaining<=6; end
                            4: begin text_address<=29; remaining<=5; end
                            5: begin text_address<=34; remaining<=4; end
                            6: begin text_address<=38; remaining<=4; end
                            default: begin text_address<=42; remaining<=6; end
                        endcase
                        6: if(err!=0) begin
                            case(err)
                                1: begin text_address<=48; remaining<=5; end
                                2: begin text_address<=53; remaining<=4; end
                                3: begin text_address<=57; remaining<=9; end
                                4: begin text_address<=66; remaining<=8; end
                                5: begin text_address<=74; remaining<=9; end
                                6: begin text_address<=83; remaining<=9; end
                                7: begin text_address<=92; remaining<=7; end
                                8: begin text_address<=99; remaining<=7; end
                                9: begin text_address<=106; remaining<=6; end
                                11: begin text_address<=112; remaining<=8; end
                                default: begin text_address<=120; remaining<=8; end
                            endcase
                        end else case(op)
                            0: begin text_address<=128; remaining<=CONTROL_ENABLE!=0 ? 5'd11 : 5'd9; end
                            1: begin text_address<=139; remaining<=2; end
                            4: begin step<=10; state<=LOAD; end
                            default: begin text_address<=141; remaining<=1; end
                        endcase
                        9: begin
                            source<=HEX; sid<={scrc,48'd0};
                            token<=hexchar(scrc[15:12]); remaining<=4; state<=SEND;
                        end
                        10: begin source<=TAIL; token<=8'd44; remaining<=6; state<=SEND; end
                        17: begin
                            source<=HEX; sid<={status[32:17],48'd0};
                            token<=hexchar(status[32:29]); remaining<=4; state<=SEND;
                        end
                        19: begin token<={7'd24,status[16]}; remaining<=1; state<=SEND; end
                        21: begin
                            source<=HEX; sid<={status[15:0],48'd0};
                            token<=hexchar(status[15:12]); remaining<=4; state<=SEND;
                        end
                        default: begin state<=IDLE; done<=1; end
                    endcase
                end
                TEXT_FETCH: state<=TEXT_LOAD;
                TEXT_LOAD: begin token<=text_data; state<=SEND; end
                DECIMAL: begin
                    bcd<={corrected_bcd[18:0],binary_shift[15]};
                    binary_shift<={binary_shift[14:0],1'b0};
                    if(decimal_bit==4'd15) state<=ALIGN;
                    else decimal_bit<=decimal_bit+1'b1;
                end
                ALIGN: begin
                    state<=SEND;
                    if(bcd[19:16]!=0) begin token<={4'h3,bcd[19:16]}; remaining<=5; end
                    else if(bcd[15:12]!=0) begin token<={4'h3,bcd[15:12]}; bcd<={bcd[15:0],4'd0}; remaining<=4; end
                    else if(bcd[11:8]!=0) begin token<={4'h3,bcd[11:8]}; bcd<={bcd[11:0],8'd0}; remaining<=3; end
                    else if(bcd[7:4]!=0) begin token<={4'h3,bcd[7:4]}; bcd<={bcd[7:0],12'd0}; remaining<=2; end
                    else begin token<={4'h3,bcd[3:0]}; bcd<={bcd[3:0],16'd0}; remaining<=1; end
                end
                SEND: if(tx_ready) begin
                    case(source)
                        TEXT: begin text_address<=text_address+1'b1; state<=TEXT_FETCH; end
                        HEX: begin sid<={sid[59:0],4'd0}; token<=hexchar(sid[59:56]); end
                        DIGITS: begin token<={4'h3,bcd[15:12]}; bcd<={bcd[15:0],4'd0}; end
                        TAIL: token<=remaining==2 ? 8'd10 : hexchar(tail_nibble);
                    endcase
                    remaining<=remaining-1'b1;
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

