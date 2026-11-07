`default_nettype none
// State reconciliation, not edge pulses: stalled ON is followed by its OFF even
// if the physical key was released before the bank accepted it.
// Each ON owns an ID; OFF reuses the accepted ID rather than matching pitch.
// Hold the payload while valid is stalled; update sounding only on acceptance.
// After leaving a menu, require a release before rearming a still-held key.
module keyboard_note_events #(parameter integer CE_ENABLE=0,
    
    parameter integer PER_KEY_FORCE_ENABLE=0
)(
    input wire clock_enable,
    
    input wire clk, reset_n, enable,
    input wire [11:0] keys,
    input wire [1:0] octave,
    input wire [6:0] velocity,
    input wire [83:0] key_forces,
    input wire event_ready,
    output reg event_valid,event_on,
    output reg [15:0] event_id,
    output reg [3:0] event_note,
    output reg [1:0] event_octave,
    output reg [6:0] event_force,
    output wire [11:0] held_notes
);
    reg [11:0] armed, sounding;
    reg [15:0] ids [0:11];
    reg [15:0] next_id;
    assign held_notes = enable ? sounding : 12'd0;
    wire [11:0] wanted=keys & armed;
    wire [11:0] off_mask=sounding & ~wanted;
    wire [11:0] on_mask=wanted & ~sounding;
    reg found;
    reg [3:0] selected;
    integer k,i;
    always @*begin
        found=0;selected=0;
        for(i=0;i<12;i=i+1)begin
            if(!found && (off_mask!=0 ? off_mask[i] : on_mask[i]))begin found=1;selected=i;end
        end
    end
    always @(posedge clk or negedge reset_n)begin
        if(!reset_n)begin
            armed<=0;sounding<=0;next_id<=0;event_valid<=0;event_on<=0;
            event_id<=0;event_note<=0;event_octave<=0;event_force<=0;
            for(k=0;k<12;k=k+1)ids[k]<=0;
        end else if ((!CE_ENABLE || clock_enable)) if(!enable)begin
            armed<=0;sounding<=0;event_valid<=0;
        end else begin
            // Each held key must be released after menu/timeout before reuse.
            armed<=armed | ~keys;
            if(event_valid)begin
                if(event_ready)begin
                    event_valid<=0;
                    sounding[event_note]<=event_on;
                    if(event_on)begin ids[event_note]<=event_id;next_id<=next_id+1'b1;end
                end
            end else if(found)begin
                event_valid<=1;event_on<=off_mask==0;event_note<=selected;
                event_id<=off_mask==0 ? next_id : ids[selected];
                event_octave<=octave;
                event_force<=PER_KEY_FORCE_ENABLE ? key_forces[selected*7+:7] : velocity;
            end
        end
    end
endmodule
`default_nettype wire
