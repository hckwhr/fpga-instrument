`default_nettype none
// Read-only PCM tap. 48 kHz -> 12 kHz, two cascaded length-4 moving averages.
// IMA ADPCM, 240 samples/block, three chronological nibbles -> two Base64 chars.
// Two immutable packet banks; full/overrun ends the take, never stalls the DAC.
// All state here is sys_clk; the caller supplies PCM through an acknowledged CDC.
module performance_recorder #(parameter integer MAX_BLOCKS=3000)(
    input wire clk, reset_n, start, stop,
    input wire [2:0] stop_reason,
    input wire pcm_valid,
    input wire signed [15:0] pcm,
    output reg active,
    output reg [2:0] reason,
    output reg [15:0] count,
    output wire block_valid,
    input wire block_release,
    input wire [7:0] read_address,
    output reg [5:0] read_code,
    output wire [15:0] block_predictor,
    output wire [6:0] block_index
);
    function [14:0] step_value;
        input [6:0] index;
        begin case(index)
            7'd0:step_value=15'd7;
            7'd1:step_value=15'd8;
            7'd2:step_value=15'd9;
            7'd3:step_value=15'd10;
            7'd4:step_value=15'd11;
            7'd5:step_value=15'd12;
            7'd6:step_value=15'd13;
            7'd7:step_value=15'd14;
            7'd8:step_value=15'd16;
            7'd9:step_value=15'd17;
            7'd10:step_value=15'd19;
            7'd11:step_value=15'd21;
            7'd12:step_value=15'd23;
            7'd13:step_value=15'd25;
            7'd14:step_value=15'd28;
            7'd15:step_value=15'd31;
            7'd16:step_value=15'd34;
            7'd17:step_value=15'd37;
            7'd18:step_value=15'd41;
            7'd19:step_value=15'd45;
            7'd20:step_value=15'd50;
            7'd21:step_value=15'd55;
            7'd22:step_value=15'd60;
            7'd23:step_value=15'd66;
            7'd24:step_value=15'd73;
            7'd25:step_value=15'd80;
            7'd26:step_value=15'd88;
            7'd27:step_value=15'd97;
            7'd28:step_value=15'd107;
            7'd29:step_value=15'd118;
            7'd30:step_value=15'd130;
            7'd31:step_value=15'd143;
            7'd32:step_value=15'd157;
            7'd33:step_value=15'd173;
            7'd34:step_value=15'd190;
            7'd35:step_value=15'd209;
            7'd36:step_value=15'd230;
            7'd37:step_value=15'd253;
            7'd38:step_value=15'd279;
            7'd39:step_value=15'd307;
            7'd40:step_value=15'd337;
            7'd41:step_value=15'd371;
            7'd42:step_value=15'd408;
            7'd43:step_value=15'd449;
            7'd44:step_value=15'd494;
            7'd45:step_value=15'd544;
            7'd46:step_value=15'd598;
            7'd47:step_value=15'd658;
            7'd48:step_value=15'd724;
            7'd49:step_value=15'd796;
            7'd50:step_value=15'd876;
            7'd51:step_value=15'd963;
            7'd52:step_value=15'd1060;
            7'd53:step_value=15'd1166;
            7'd54:step_value=15'd1282;
            7'd55:step_value=15'd1411;
            7'd56:step_value=15'd1552;
            7'd57:step_value=15'd1707;
            7'd58:step_value=15'd1878;
            7'd59:step_value=15'd2066;
            7'd60:step_value=15'd2272;
            7'd61:step_value=15'd2499;
            7'd62:step_value=15'd2749;
            7'd63:step_value=15'd3024;
            7'd64:step_value=15'd3327;
            7'd65:step_value=15'd3660;
            7'd66:step_value=15'd4026;
            7'd67:step_value=15'd4428;
            7'd68:step_value=15'd4871;
            7'd69:step_value=15'd5358;
            7'd70:step_value=15'd5894;
            7'd71:step_value=15'd6484;
            7'd72:step_value=15'd7132;
            7'd73:step_value=15'd7845;
            7'd74:step_value=15'd8630;
            7'd75:step_value=15'd9493;
            7'd76:step_value=15'd10442;
            7'd77:step_value=15'd11487;
            7'd78:step_value=15'd12635;
            7'd79:step_value=15'd13899;
            7'd80:step_value=15'd15289;
            7'd81:step_value=15'd16818;
            7'd82:step_value=15'd18500;
            7'd83:step_value=15'd20350;
            7'd84:step_value=15'd22385;
            7'd85:step_value=15'd24623;
            7'd86:step_value=15'd27086;
            7'd87:step_value=15'd29794;
            7'd88:step_value=15'd32767;
            default:step_value=15'd7;
        endcase end
    endfunction
    reg write_bank, read_bank;
    reg [1:0] ready;
    (* syn_ramstyle="block_ram" *) reg [5:0] memory[0:511];
    reg [15:0] predictors[0:1];
    reg [6:0] indices[0:1];
    assign block_valid=ready[read_bank];
    assign block_predictor=predictors[read_bank];
    assign block_index=indices[read_bank];
    always @(posedge clk) read_code<=memory[{read_bank,read_address}];
    reg [7:0] address;
    reg [3:0] state;
    reg [7:0] in_block;
    reg [1:0] group, decimate, history_pos;
    reg [7:0] nibble_pair;
    reg signed [15:0] history1[0:3], history2[0:3];
    reg signed [17:0] sum1,sum2;
    wire signed [17:0] next_sum1=sum1+$signed({{2{pcm[15]}},pcm})-
        $signed({{2{history1[history_pos][15]}},history1[history_pos]});
    reg signed [15:0] filtered1, filtered2;
    wire signed [17:0] next_sum2=sum2+$signed({{2{filtered1[15]}},filtered1})-
        $signed({{2{history2[history_pos][15]}},history2[history_pos]});
    reg signed [15:0] predictor;
    reg [6:0] index;
    reg [15:0] magnitude, step, delta;
    reg [3:0] code;
    reg signed [16:0] difference;
    reg signed [17:0] reconstructed;
    reg stop_pending;
    wire [15:0] quarter=step>>2, half_step=step>>1;
    wire [4:0] index_add=code[2:0]==4?5'd2:code[2:0]==5?5'd4:code[2:0]==6?5'd6:5'd8;
    integer i;
    // Registered write addresses/data; no resets on RAM.
    always @(posedge clk) begin
        if(reset_n && state==9) memory[{write_bank,address}]<=nibble_pair[7:2];
        if(reset_n && state==10) memory[{write_bank,address}]<={nibble_pair[1:0],code};
    end
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin
            active<=0;reason<=0;count<=0;write_bank<=0;read_bank<=0;ready<=0;
            address<=0;state<=0;in_block<=0;group<=0;decimate<=0;history_pos<=0;
            sum1<=0;sum2<=0;filtered1<=0;filtered2<=0;predictor<=0;index<=0;
            magnitude<=0;step<=0;delta<=0;code<=0;difference<=0;reconstructed<=0;
            stop_pending<=0;nibble_pair<=0;
            for(i=0;i<4;i=i+1)begin history1[i]<=0;history2[i]<=0;end
            for(i=0;i<2;i=i+1)begin predictors[i]<=0;indices[i]<=0;end
        end else begin
            if(block_release && block_valid)begin ready[read_bank]<=0;read_bank<=!read_bank;end
            if(stop && active)begin stop_pending<=1;if(stop_reason!=0)reason<=stop_reason;end
            if(start && !active && ready==0)begin
                active<=1;reason<=0;count<=0;write_bank<=0;read_bank<=0;ready<=0;
                address<=0;state<=0;in_block<=0;group<=0;decimate<=0;history_pos<=0;
                sum1<=0;sum2<=0;predictor<=0;index<=0;stop_pending<=0;nibble_pair<=0;
                for(i=0;i<4;i=i+1)begin history1[i]<=0;history2[i]<=0;end
            end else if(active)begin
                // A CDC source violating its sample deadline is a real error.
                if(pcm_valid && state!=0)begin active<=0;reason<=4;state<=0;end
                else case(state)
                    0:if(pcm_valid)begin
                        sum1<=next_sum1;history1[history_pos]<=pcm;
                        filtered1<=next_sum1>>>2;state<=1;
                    end
                    1:begin
                        sum2<=next_sum2;history2[history_pos]<=filtered1;history_pos<=history_pos+1'b1;
                        filtered2<=next_sum2>>>2;decimate<=decimate+1'b1;
                        if(decimate==3)begin
                            if(ready[write_bank])begin active<=0;reason<=1;state<=0;end
                            else begin
                                if(in_block==0)begin predictors[write_bank]<=predictor;indices[write_bank]<=index;end
                                state<=2;
                            end
                        end else state<=0;
                    end
                    2:begin difference<=$signed({filtered2[15],filtered2})-$signed({predictor[15],predictor});
                        step<={1'b0,step_value(index)};state<=3;end
                    3:begin
                        magnitude<=difference[16] ? -difference : difference;
                        code<={difference[16],3'b000};delta<=step>>3;state<=4;
                    end
                    4:begin
                        if(magnitude>=step)begin magnitude<=magnitude-step;code[2]<=1;delta<=delta+step;end
                        state<=5;
                    end
                    5:begin
                        if(magnitude>=half_step)begin magnitude<=magnitude-half_step;code[1]<=1;delta<=delta+half_step;end
                        state<=6;
                    end
                    6:begin
                        if(magnitude>=quarter)begin code[0]<=1;delta<=delta+quarter;end
                        state<=7;
                    end
                    7:begin
                        reconstructed<=code[3] ? $signed({{2{predictor[15]}},predictor})-$signed({2'b0,delta})
                            : $signed({{2{predictor[15]}},predictor})+$signed({2'b0,delta});
                        if(code[2])index<=({1'b0,index}+index_add>8'd88)?7'd88:index+index_add;
                        else if(index!=0)index<=index-1'b1;
                        state<=8;
                    end
                    8:begin
                        predictor<=reconstructed>18'sd32767 ? 16'sh7fff :
                            reconstructed< -18'sd32768 ? 16'sh8000 : reconstructed[15:0];
                        if(group==2)begin group<=0;state<=9;end
                        else begin nibble_pair<={nibble_pair[3:0],code};group<=group+1'b1;in_block<=in_block+1'b1;state<=0;end
                    end
                    9:begin address<=address+1'b1;state<=10;end
                    10:begin
                        if(in_block==239)begin
                            ready[write_bank]<=1;write_bank<=!write_bank;address<=0;in_block<=0;count<=count+1'b1;
                            if(stop_pending || count==MAX_BLOCKS-1)begin
                                active<=0;if(!stop_pending)reason<=3;
                            end
                        end else begin address<=address+1'b1;in_block<=in_block+1'b1;end
                        state<=0;
                    end
                    default:begin active<=0;reason<=4;state<=0;end
                endcase
            end
        end
    end
endmodule
`default_nettype wire
