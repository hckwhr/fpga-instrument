`default_nettype none
// Eight independent waveguides; only the note-event allocator is sequential.
module physical_string_bank #(parameter integer CE_ENABLE=0, parameter integer EVENT_SUPPORT=0) (
    input wire clock_enable,
    
    input wire clk, reset_n, sample_strobe, enable,
    input wire event_mode, event_flush, event_valid, event_on,
    input wire [15:0] event_id,
    input wire [3:0] event_note_in,
    input wire [1:0] event_octave_in,
    input wire [6:0] event_force_in,
    output wire event_ready,
    input wire [2:0] voice_trigger, voice_gate,
    input wire play_mode, keymap_select,
    input wire [3:0] note_select,
    input wire [1:0] octave_select,
    input wire [6:0] force_value,
    input wire signed [7:0] bend,
    input wire [7:0] vibrato_depth,
    output reg signed [15:0] sample,
    output wire [7:0] active_voices,
    output reg [3:0] active_voice_count,
    output reg [7:0] deadline_miss_count
);
    localparam [2:0] IDLE=0, PREPARE=1, SEARCH=2, PICK=3, WRITE=4;
    reg [2:0] state, pending_keys, cursor, scan, destination;
    reg [3:0] remaining, scanned;
    reg [1:0] member, chord_source;
    reg [5:0] root, event_note;
    reg [6:0] batch_force, event_force;
    reg batch_chord;
    reg [2:0] event_mask;
    reg [7:0] reserved, released;
    reg [2:0] gate_mask [0:7];
    // IDs identify occurrences, not pitches. Only the event owner may release.
    reg [15:0] voice_id [0:7];
    reg [7:0] voice_id_valid;
    reg [15:0] batch_id;
    reg mode_q;
    wire events = EVENT_SUPPORT && event_mode;
    wire flush = EVENT_SUPPORT && (event_flush || (mode_q != events));
    assign event_ready = reset_n && enable && events && !flush &&
        (!CE_ENABLE || clock_enable) && !sample_strobe && state==IDLE;
    wire accept_event = event_valid && event_ready;
    reg best_valid, best_released;
    reg [2:0] best_index;
    reg [15:0] best_level;
    wire [7:0] busy, accepting;
    wire [15:0] level [0:7];
    wire signed [15:0] voice_sample [0:7];
    wire [2:0] requested = pending_keys | voice_trigger;
    wire signed [16:0] delay_delta;
    string_pitch_control #(.CE_ENABLE(CE_ENABLE)) pitch_control(.clock_enable(clock_enable),.clk(clk),.reset_n(reset_n),.sample_strobe(sample_strobe),
        .enable(enable),.bend(bend),.vibrato_depth(vibrato_depth),.delay_delta(delay_delta));
    wire [5:0] octave_base = (octave_select==0)?6'd0:(octave_select==1)?6'd12:6'd24;
    wire eligible = accepting[scan] && !reserved[scan];
    wire better = !best_valid || (released[scan] && !best_released) ||
        ((released[scan]==best_released) && level[scan]<best_level);

    integer i;
    always @* begin
        active_voice_count=0;
        for(i=0;i<8;i=i+1) active_voice_count=active_voice_count+{3'd0,active_voices[i]};
    end
    // Sticky, saturating diagnostic survives menu entry / source disable.
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) deadline_miss_count<=0;
        else if ((!CE_ENABLE || clock_enable)) if(enable && sample_strobe && (|busy) && deadline_miss_count!=8'hff)
            deadline_miss_count<=deadline_miss_count+8'd1;
    end
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin
            state<=IDLE; pending_keys<=0; cursor<=0; scan<=0;
            destination<=0; remaining<=0; scanned<=0; member<=0; chord_source<=0;
            root<=0; event_note<=0; batch_force<=0; event_force<=0; batch_chord<=0;
            event_mask<=0; best_valid<=0; best_released<=0; best_index<=0; best_level<=0;
            batch_id<=0; mode_q<=0;
        end else if ((!CE_ENABLE || clock_enable)) if(!enable) begin state<=IDLE; pending_keys<=0; cursor<=0; end
        else if(flush) begin state<=IDLE; pending_keys<=0; mode_q<=events; end
        else begin
            pending_keys<=requested;
            case(state)
                IDLE: if(events) begin
                    pending_keys<=0;
                    if(accept_event && event_on) begin
                        root<={2'b0,event_note_in} + ((event_octave_in==0)?6'd0:
                            (event_octave_in==1)?6'd12:6'd24);
                        batch_force<=event_force_in; batch_id<=event_id;
                        batch_chord<=0; member<=0; remaining<=4'b0001;
                        state<=PREPARE;
                    end
                end else if(sample_strobe && (|requested)) begin
                    pending_keys<=0; batch_chord<=keymap_select;
                    batch_force<=force_value; member<=0;
                    // Same physical chord map: simultaneous chord keys choose
                    // KEY2, then KEY1, then KEY0. Each chord has four notes.
                    chord_source<=requested[2]?2'd2:requested[1]?2'd1:2'd0;
                    root<={2'b0,note_select}+octave_base+
                        (keymap_select?(requested[2]?6'd7:requested[1]?6'd5:6'd0):6'd0);
                    remaining<=keymap_select?4'b1111:{(&voice_gate),requested};
                    state<=PREPARE;
                end
                PREPARE: begin
                    if(!remaining[member]) begin
                        if(member==3) state<=IDLE;
                        else member<=member+2'd1;
                    end else begin
                        event_note<=root+((member==0)?6'd0:(member==1)?
                            (batch_chord?6'd4:6'd2):(member==2)?(batch_chord?6'd7:6'd4):6'd12);
                        event_force<=(member==3)?(batch_force>>1):batch_force;
                        event_mask<=batch_chord?(3'b001<<chord_source):
                            ((member==3)?3'b111:(3'b001<<member));
                        scan<=cursor; scanned<=0; best_valid<=0; state<=SEARCH;
                    end
                end
                SEARCH: begin
                    if(eligible && !active_voices[scan]) begin destination<=scan; state<=WRITE; end
                    else begin
                        if(eligible && better) begin
                            best_valid<=1; best_index<=scan; best_level<=level[scan];
                            best_released<=released[scan];
                        end
                        if(scanned==7) state<=PICK;
                        else begin scan<=scan+3'd1; scanned<=scanned+4'd1; end
                    end
                end
                PICK: if(best_valid) begin destination<=best_index; state<=WRITE; end
                    else begin scan<=cursor; scanned<=0; state<=SEARCH; end
                WRITE: begin
                    cursor<=destination+3'd1;
                    if(events || member==3) state<=IDLE;
                    else begin member<=member+2'd1; state<=PREPARE; end
                end
                default: begin state<=IDLE; pending_keys<=0; end
            endcase
        end
    end
    genvar g, id_pair;
    generate for(g=0;g<8;g=g+1) begin: strings
        wire fire = enable && !flush && state==WRITE && destination==g;
        // Match the polyphony bank's parallel 2-bit LUT equality tree; a
        // single 16-bit equality inferred a long ALU carry chain there.
        wire [7:0] id_pair_equal /* synthesis syn_keep=1 */;
        for(id_pair=0;id_pair<8;id_pair=id_pair+1) begin: u_id_pair
            assign id_pair_equal[id_pair] =
                voice_id[g][id_pair*2+:2] == event_id[id_pair*2+:2];
        end
        wire id_match = voice_id_valid[g] && (&id_pair_equal);
        always @(posedge clk or negedge reset_n) begin
            if(!reset_n) begin reserved[g]<=0; released[g]<=0; gate_mask[g]<=0;
                voice_id[g]<=0; voice_id_valid[g]<=0; end
            else if ((!CE_ENABLE || clock_enable)) if(!enable) begin reserved[g]<=0; released[g]<=0; gate_mask[g]<=0;
                voice_id_valid[g]<=0; end
            else if(flush) begin reserved[g]<=0; released[g]<=1; voice_id_valid[g]<=0; end
            else if(fire) begin
                reserved[g]<=1; gate_mask[g]<=event_mask;
                released[g]<=events ? 1'b0 : ((voice_gate & event_mask)!=event_mask);
                voice_id[g]<=batch_id; voice_id_valid[g]<=events;
            end else begin
                if(active_voices[g]) reserved[g]<=0;
                // A fresh key press must not revive an earlier released note.
                if(events) begin
                    if(accept_event && !event_on && id_match) begin
                        released[g]<=1; voice_id_valid[g]<=0;
                    end
                end else if((voice_gate & gate_mask[g])!=gate_mask[g]) released[g]<=1;
            end
        end
        physical_string_voice #(.CE_ENABLE(CE_ENABLE),.NOISE_SEED(16'h1ace + g*16'h1234)) voice (.clock_enable(clock_enable),
            .clk(clk),.reset_n(reset_n),.sample_strobe(sample_strobe),.enable(enable),
            .trigger(fire),.held(!released[g]),.pluck_mode(play_mode),.note(event_note),
            .force_value(event_force),.sample(voice_sample[g]),.active(active_voices[g]),
            .delay_delta(delay_delta),
            .level(level[g]),.busy(busy[g]),.accepting(accepting[g]));
    end endgenerate
    // Registered balanced sum. Fixed half gain leaves room for overlapping
    // four-note chords without changing gain as the voice count changes.
    reg signed [16:0] sum1 [0:3];
    reg signed [17:0] sum2 [0:1];
    reg signed [18:0] mix;
    generate for(g=0;g<4;g=g+1) begin: sum_pairs
        always @(posedge clk) if ((!CE_ENABLE || clock_enable)) sum1[g]<=
            $signed({voice_sample[2*g][15],voice_sample[2*g]})+
            $signed({voice_sample[2*g+1][15],voice_sample[2*g+1]});
    end endgenerate
    always @(posedge clk) if ((!CE_ENABLE || clock_enable)) begin
        sum2[0]<=$signed({sum1[0][16],sum1[0]})+$signed({sum1[1][16],sum1[1]});
        sum2[1]<=$signed({sum1[2][16],sum1[2]})+$signed({sum1[3][16],sum1[3]});
        mix<=$signed({sum2[0][17],sum2[0]})+$signed({sum2[1][17],sum2[1]});
    end
    reg [2:0] ready;
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin sample<=0; ready<=0; end
        else if ((!CE_ENABLE || clock_enable)) if(!enable) begin sample<=0; ready<=0; end
        else begin
            ready<={ready[1:0],1'b1};
            if(sample_strobe) begin
                if(!ready[2]) sample<=0;
                else if(mix>19'sd65534) sample<=16'sh7fff;
                else if(mix < -19'sd65536) sample<=16'sh8000;
                else sample<=mix>>>1;
            end
        end
    end
endmodule
`default_nettype wire
