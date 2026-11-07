`default_nettype none
// Audio-domain follow-along gate. The UART request payload is held by the
// existing PERF1 req/ack handshake. Only fresh key edges after a cue may hit.
// Sticky per-cue hits survive fast releases and polling latency; polling never
// retriggers a note. Timeout keeps the keyboard guarded/silent until explicit
// stop, rather than falling back to unrestricted playing on a lost BLE link.
module rhythm_key_gate #(parameter integer CE_ENABLE=0,
    parameter integer LEASE_STEPS=75000000)(
    input wire clk, reset_n, clock_enable,
    input wire command_valid, command_set,
    input wire [71:0] command_payload,
    input wire blocked, keyboard_busy,
    input wire [11:0] physical_keys,
    output reg guard, active,
    output wire [11:0] play_keys, guide_keys,
    output wire [71:0] status,
    output reg [1:0] result
);
    localparam integer LW=LEASE_STEPS>1?$clog2(LEASE_STEPS+1):1;
    reg [LW-1:0] lease;
    reg [31:0] cue;
    reg [11:0] target, hits, held, previous_keys, inhibited;
    wire [11:0] fresh_hits=physical_keys & ~previous_keys & target & ~hits;
    wire [11:0] accepted=active && !blocked && lease!=0 ? fresh_hits : 12'd0;
    assign play_keys=guard ? (held & physical_keys) : (physical_keys & ~inhibited);
    assign guide_keys=active && !blocked ? target & ~hits : 12'd0;
    assign status={2'b10,guard,active,cue,physical_keys,hits,guide_keys};
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin
            guard<=0;active<=0;lease<=0;cue<=0;target<=0;hits<=0;
            held<=0;previous_keys<=0;inhibited<=0;result<=0;
        end else if(!CE_ENABLE || clock_enable) begin
            previous_keys<=physical_keys;
            inhibited<=inhibited & physical_keys;
            held<=(held | accepted) & physical_keys;
            hits<=hits | accepted;
            if(active) begin
                if(lease!=0) lease<=lease-1'b1;
                if(blocked || lease==0) begin active<=0;held<=0;end
            end
            if(command_valid) begin
                result<=0;
                if(!command_set) begin
                    if(active && !blocked && lease!=0) lease<=LEASE_STEPS;
                end else if(command_payload[71:45]!=0 ||
                    (!command_payload[44] && command_payload[43:0]!=0)) result<=3;
                else if(!command_payload[44]) begin
                    guard<=0;active<=0;target<=0;hits<=0;held<=0;
                    inhibited<=physical_keys;lease<=0;
                end else if(blocked || (!guard && keyboard_busy) ||
                    (guard && (!active || lease==0))) result<=2;
                else if(active && cue==command_payload[43:12]) begin
                    // An identical retransmission can renew the lease but
                    // cannot clear hits. A mutated payload with this ID fails.
                    if(target!=command_payload[11:0]) result<=3;
                    else lease<=LEASE_STEPS;
                end else begin
                    guard<=1;active<=1;cue<=command_payload[43:12];
                    target<=command_payload[11:0];hits<=0;lease<=LEASE_STEPS;
                    if(!guard) held<=0;
                end
            end
        end
    end
endmodule
`default_nettype wire
