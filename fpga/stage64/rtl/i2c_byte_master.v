`default_nettype none
// Single-master open-drain I2C. Commands: START=0, STOP=1, WRITE=2,
// READ_ACK=3, READ_NACK=4. done/error pulse; pins stay owned between bytes.
module i2c_byte_master #(
    parameter integer HALF_CYCLES = 250,
    parameter integer TIMEOUT_CYCLES = 500000
) (
    input wire clk, reset_n, request,
    input wire [2:0] command,
    input wire [7:0] tx_data,
    input wire scl_in, sda_in,
    output reg scl_low, sda_low,
    output reg busy, done, error,
    output reg [7:0] rx_data
);
    localparam IDLE=0, START_WAIT=1, START_HOLD=2, STOP_LOW=3,
        STOP_WAIT=4, STOP_HOLD=5, BIT_LOW=6, BIT_WAIT=7, BIT_HIGH=8, START_LOW=9;
    reg [3:0] state;
    reg [2:0] operation;
    reg [3:0] bit_index;
    reg [7:0] shift;
    reg [$clog2(HALF_CYCLES+1)-1:0] phase_count;
    reg [$clog2(TIMEOUT_CYCLES+1)-1:0] timeout_count;
    reg [1:0] scl_sync, sda_sync;
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin scl_sync<=3; sda_sync<=3; end
        else begin scl_sync<={scl_sync[0],scl_in}; sda_sync<={sda_sync[0],sda_in}; end
    end
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state<=IDLE; operation<=0; bit_index<=0; shift<=0;
            phase_count<=0; timeout_count<=0;
            scl_low<=0; sda_low<=0; busy<=0; done<=0; error<=0; rx_data<=0;
        end else begin
            done<=0; error<=0;
            if (busy && timeout_count == TIMEOUT_CYCLES-1) begin
                state<=IDLE; busy<=0; done<=1; error<=1;
                scl_low<=0; sda_low<=0; timeout_count<=0;
            end else begin
                if (busy) timeout_count<=timeout_count+1'b1;
                case (state)
                    IDLE: if (request) begin
                        busy<=1; timeout_count<=0; phase_count<=0;
                        operation<=command; shift<=tx_data; bit_index<=0;
                        case (command)
                            0: begin
                                sda_low<=0;
                                // Repeated START must preserve the preceding
                                // ACK clock's full low period before raising SCL.
                                state<=scl_low?START_LOW:START_WAIT;
                            end
                            1: begin scl_low<=1; sda_low<=1; state<=STOP_LOW; end
                            2,3,4: begin
                                scl_low<=1;
                                sda_low<=(command==2) && !tx_data[7];
                                state<=BIT_LOW;
                            end
                            default: begin busy<=0; done<=1; error<=1; end
                        endcase
                    end
                    START_LOW: if (phase_count==HALF_CYCLES-1) begin
                        scl_low<=0;phase_count<=0;state<=START_WAIT;
                    end else phase_count<=phase_count+1'b1;
                    START_WAIT: begin
                        if (scl_sync[1] && sda_sync[1]) begin
                            if (phase_count==HALF_CYCLES-1) begin
                                phase_count<=0; sda_low<=1; state<=START_HOLD;
                            end else phase_count<=phase_count+1'b1;
                        end else phase_count<=0;
                    end
                    START_HOLD: if (phase_count==HALF_CYCLES-1) begin
                        scl_low<=1; phase_count<=0; state<=IDLE; busy<=0; done<=1;
                    end else phase_count<=phase_count+1'b1;
                    STOP_LOW: if (phase_count==HALF_CYCLES-1) begin
                        scl_low<=0; phase_count<=0; state<=STOP_WAIT;
                    end else phase_count<=phase_count+1'b1;
                    STOP_WAIT: if (scl_sync[1]) begin
                        if (phase_count==HALF_CYCLES-1) begin
                            sda_low<=0; phase_count<=0; state<=STOP_HOLD;
                        end else phase_count<=phase_count+1'b1;
                    end else phase_count<=0;
                    STOP_HOLD: if (phase_count==HALF_CYCLES-1) begin
                        state<=IDLE; busy<=0; done<=1; phase_count<=0;
                        if (!sda_sync[1]) error<=1;
                    end else phase_count<=phase_count+1'b1;
                    BIT_LOW: if (phase_count==HALF_CYCLES-1) begin
                        scl_low<=0; phase_count<=0; state<=BIT_WAIT;
                    end else phase_count<=phase_count+1'b1;
                    BIT_WAIT: if (scl_sync[1]) begin phase_count<=0; state<=BIT_HIGH; end
                    BIT_HIGH: if (phase_count==HALF_CYCLES-1) begin
                        scl_low<=1; phase_count<=0;
                        if (bit_index==8) begin
                            error<=(operation==2) && sda_sync[1];
                            rx_data<=shift; sda_low<=0;
                            state<=IDLE; busy<=0; done<=1;
                        end else begin
                            if (operation!=2) shift<={shift[6:0],sda_sync[1]};
                            else shift<={shift[6:0],1'b0};
                            bit_index<=bit_index+1'b1;
                            if (bit_index==7) sda_low<=(operation==3);
                            else sda_low<=(operation==2) && !shift[6];
                            state<=BIT_LOW;
                        end
                    end else phase_count<=phase_count+1'b1;
                    default: begin state<=IDLE; busy<=0; scl_low<=0; sda_low<=0; end
                endcase
            end
        end
    end
endmodule
`default_nettype wire
