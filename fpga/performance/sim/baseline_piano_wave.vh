// Soft keyboard timbre: 6900*(sin(p)+0.20*sin(2p)+0.06*sin(3p)).
// 64 periodic knots with 8-bit linear interpolation; no sampled piano claim.
function signed [15:0] piano_point;
    input [5:0] index;
    begin
        case (index)
            6'd0: piano_point = 16'sd0;
            6'd1: piano_point = 16'sd1066;
            6'd2: piano_point = 16'sd2104;
            6'd3: piano_point = 16'sd3090;
            6'd4: piano_point = 16'sd3999;
            6'd5: piano_point = 16'sd4812;
            6'd6: piano_point = 16'sd5514;
            6'd7: piano_point = 16'sd6096;
            6'd8: piano_point = 16'sd6552;
            6'd9: piano_point = 16'sd6882;
            6'd10: piano_point = 16'sd7093;
            6'd11: piano_point = 16'sd7192;
            6'd12: piano_point = 16'sd7192;
            6'd13: piano_point = 16'sd7107;
            6'd14: piano_point = 16'sd6951;
            6'd15: piano_point = 16'sd6740;
            6'd16: piano_point = 16'sd6486;
            6'd17: piano_point = 16'sd6201;
            6'd18: piano_point = 16'sd5895;
            6'd19: piano_point = 16'sd5574;
            6'd20: piano_point = 16'sd5241;
            6'd21: piano_point = 16'sd4897;
            6'd22: piano_point = 16'sd4543;
            6'd23: piano_point = 16'sd4175;
            6'd24: piano_point = 16'sd3792;
            6'd25: piano_point = 16'sd3389;
            6'd26: piano_point = 16'sd2965;
            6'd27: piano_point = 16'sd2517;
            6'd28: piano_point = 16'sd2047;
            6'd29: piano_point = 16'sd1556;
            6'd30: piano_point = 16'sd1048;
            6'd31: piano_point = 16'sd527;
            6'd32: piano_point = 16'sd0;
            6'd33: piano_point = -16'sd527;
            6'd34: piano_point = -16'sd1048;
            6'd35: piano_point = -16'sd1556;
            6'd36: piano_point = -16'sd2047;
            6'd37: piano_point = -16'sd2517;
            6'd38: piano_point = -16'sd2965;
            6'd39: piano_point = -16'sd3389;
            6'd40: piano_point = -16'sd3792;
            6'd41: piano_point = -16'sd4175;
            6'd42: piano_point = -16'sd4543;
            6'd43: piano_point = -16'sd4897;
            6'd44: piano_point = -16'sd5241;
            6'd45: piano_point = -16'sd5574;
            6'd46: piano_point = -16'sd5895;
            6'd47: piano_point = -16'sd6201;
            6'd48: piano_point = -16'sd6486;
            6'd49: piano_point = -16'sd6740;
            6'd50: piano_point = -16'sd6951;
            6'd51: piano_point = -16'sd7107;
            6'd52: piano_point = -16'sd7192;
            6'd53: piano_point = -16'sd7192;
            6'd54: piano_point = -16'sd7093;
            6'd55: piano_point = -16'sd6882;
            6'd56: piano_point = -16'sd6552;
            6'd57: piano_point = -16'sd6096;
            6'd58: piano_point = -16'sd5514;
            6'd59: piano_point = -16'sd4812;
            6'd60: piano_point = -16'sd3999;
            6'd61: piano_point = -16'sd3090;
            6'd62: piano_point = -16'sd2104;
            6'd63: piano_point = -16'sd1066;
            default: piano_point = 16'sd0;
        endcase
    end
endfunction

function signed [15:0] piano_wave;
    input [31:0] phase;
    reg signed [15:0] a, b;
    reg signed [16:0] delta;
    reg signed [25:0] interpolation;
    reg signed [26:0] result;
    begin
        a = piano_point(phase[31:26]);
        b = piano_point(phase[31:26] + 6'd1);
        delta = $signed({b[15], b}) - $signed({a[15], a});
        interpolation = delta * $signed({1'b0, phase[25:18]});
        result = $signed({{11{a[15]}}, a}) + (interpolation >>> 8);
        piano_wave = result[15:0];
    end
endfunction

