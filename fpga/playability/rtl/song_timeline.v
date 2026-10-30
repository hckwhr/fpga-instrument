`default_nettype none
// Data-driven timestamp player. Prefetch one complete <=16-event group.
// Score time NEVER stalls for the allocator. All events are issued just after
// their due sample and must drain by physical clock 1000 of a 1024-clock slot
// (500 enabled steps at half rate). The next sample also checks the deadline.
// The bank then attacks every new lane together at the following sample.
// Offline admission reserves lanes/tails; full-pool stealing is unsupported.
module song_timeline #(parameter integer SCORE_BITS=9, PROGRESS_BITS=8,
    parameter integer CE_ENABLE=0) (
    input wire clock_enable,
    
    input wire clk, reset_n, sample_strobe, enable,
    input wire stop_pressed, replay_pressed, remote_start, remote_stop,
    input wire [1:0] tempo_select,
    output wire [SCORE_BITS-1:0] score_index,
    input wire [63:0] score_data,
    input wire [SCORE_BITS:0] score_length,
    input wire [23:0] score_end_tick,
    output reg [PROGRESS_BITS-1:0] note_index,
    output reg done, deadline_fault,
    output wire event_flush, event_valid, event_on, event_melody,
    output wire [15:0] event_id,
    output wire [3:0] event_note,
    output wire [1:0] event_octave,
    output wire [6:0] event_force,
    input wire event_ready
);
    localparam [2:0] IDLE=0, FETCH_WAIT=1, FETCH_STORE=2, WAIT_DUE=3, SEND=4, DRAIN=5;
    localparam [9:0] DRAIN_DEADLINE = CE_ENABLE ? 10'd500 : 10'd1000;
    reg [2:0] state;
    reg enable_d, stop_d, replay_d, started;
    reg [PROGRESS_BITS-1:0] melody_position;
    reg [12:0] launch_samples;
    reg [8:0] sub_sample;
    reg [23:0] music_tick, group_tick, previous_tick;
    reg previous_valid;
    reg [SCORE_BITS:0] read_index;
    reg [9:0] slot_age;
    reg [3:0] write_member, send_member, last_member;
    // Preserve the one-event/clock SEND contract with a shallow FF table.
    reg [63:0] batch [0:15] /* synthesis syn_ramstyle="registers" */;
    reg [8:0] samples_per_tick;
    wire stop_event = (stop_pressed && !stop_d) || remote_stop;
    wire replay_event = (replay_pressed && !replay_d) || remote_start;
    wire restart = !enable_d || replay_event;
    wire cancelled = !enable || stop_event || restart;
    wire music_boundary = sample_strobe && !done &&
        ((!started && launch_samples==13'd1) || (started && sub_sample==samples_per_tick-1'b1));
    wire [23:0] due_tick = started ? music_tick+24'd1 : 24'd0;
    wire [63:0] current_event = batch[send_member];
    assign score_index = read_index[SCORE_BITS-1:0];
    assign event_flush = cancelled || deadline_fault;
    assign event_valid = state==SEND && !event_flush;
    assign event_on = current_event[39];
    assign event_id = current_event[38:23];
    assign event_note = current_event[22:19];
    assign event_octave = current_event[18:17];
    assign event_force = current_event[16:10];
    assign event_melody = current_event[8];
    always @* begin
        case(tempo_select)
            0:samples_per_tick=9'd375; 1:samples_per_tick=9'd300;
            2:samples_per_tick=9'd250; default:samples_per_tick=9'd200;
        endcase
    end
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin
            state<=IDLE; enable_d<=0; stop_d<=0; replay_d<=0;
            started<=0; launch_samples<=0; sub_sample<=0; music_tick<=0;
            group_tick<=0; previous_tick<=0; previous_valid<=0;
            read_index<=0; slot_age<=0; write_member<=0; send_member<=0; last_member<=0;
            note_index<=0; melody_position<=0; done<=0; deadline_fault<=0;
        end else if ((!CE_ENABLE || clock_enable)) begin
            enable_d<=enable; stop_d<=stop_pressed; replay_d<=replay_pressed;
            if(sample_strobe) slot_age<=0;
            else if(slot_age!=10'd1023) slot_age<=slot_age+1'b1;
            if(cancelled) begin
                state<=IDLE; started<=0; sub_sample<=0; music_tick<=0;
                launch_samples<=13'd7200; read_index<=0; write_member<=0;
                send_member<=0; last_member<=0; previous_valid<=0;
                note_index<=0; melody_position<=0; done<=enable && stop_event; deadline_fault<=0;
                if(enable && !stop_event) state<=FETCH_WAIT;
            end else if(deadline_fault) begin
                state<=IDLE; done<=1;
            end else if((state==SEND || state==DRAIN) && (sample_strobe || slot_age>=DRAIN_DEADLINE)) begin
                deadline_fault<=1; done<=1; state<=IDLE;
            end else begin
                if(sample_strobe && !done) begin
                    if(!started) begin
                        if(launch_samples>1) launch_samples<=launch_samples-1'b1;
                        else begin started<=1; sub_sample<=0; end
                    end else if(music_boundary) begin
                        music_tick<=due_tick; sub_sample<=0;
                    end else sub_sample<=sub_sample+1'b1;
                end
                case(state)
                    FETCH_WAIT: state<=FETCH_STORE;
                    FETCH_STORE: begin
                        if(score_length==0 || score_length>(1 << SCORE_BITS) || read_index>=score_length ||
                           score_data[63:40]>score_end_tick || score_data[22:19]>=4'd12 ||
                           score_data[18:17]>=2'd3 || score_data[16:10]==7'd0 ||
                           (write_member==0 && previous_valid && score_data[63:40]<=previous_tick) ||
                           (write_member!=0 && score_data[63:40]!=group_tick) ||
                           (!score_data[9] && (write_member==4'd15 || read_index+1'b1==score_length))) begin
                            deadline_fault<=1; done<=1; state<=IDLE;
                        end else begin
                            batch[write_member]<=score_data; read_index<=read_index+1'b1;
                            if(write_member==0) group_tick<=score_data[63:40];
                            if(score_data[9]) begin
                                last_member<=write_member; send_member<=0; state<=WAIT_DUE;
                            end else begin write_member<=write_member+1'b1; state<=FETCH_WAIT; end
                        end
                    end
                    WAIT_DUE: if(music_boundary && group_tick==due_tick) state<=SEND;
                    SEND: if(event_ready) begin
                        if(event_melody && event_on) begin
                            note_index<=PROGRESS_BITS>8 ? melody_position : current_event[7:0];
                            melody_position<=melody_position+1'b1;
                        end
                        if(send_member==last_member) state<=DRAIN;
                        else send_member<=send_member+1'b1;
                    end
                    DRAIN: if(event_ready) begin
                        previous_valid<=1; previous_tick<=group_tick; write_member<=0;
                        state<=read_index<score_length ? FETCH_WAIT : IDLE;
                        if(read_index==score_length && started && music_tick>=score_end_tick) done<=1;
                    end
                    IDLE: if(music_boundary && due_tick>=score_end_tick) done<=1;
                    default: begin deadline_fault<=1; done<=1; state<=IDLE; end
                endcase
                // Incomplete prefetch or late timestamp: terminate rather than
                // stall score time. End-of-song OFF at end_tick is allowed.
                if(music_boundary && ((state==WAIT_DUE && group_tick<due_tick) ||
                    state==FETCH_WAIT || state==FETCH_STORE)) begin
                    deadline_fault<=1; done<=1; state<=IDLE;
                end
            end
        end
    end
endmodule
`default_nettype wire
