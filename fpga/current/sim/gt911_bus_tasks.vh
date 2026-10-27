// Independent pin-level slave tasks; no DUT internal-state dependencies.
task bus_start;
    begin : wait_start
        forever begin @(negedge sda); if (scl===1'b1) disable wait_start; end
    end
endtask
task bus_stop;
    begin : wait_stop
        forever begin @(posedge sda); if (scl===1'b1) disable wait_stop; end
    end
endtask
task receive_byte;
    input [7:0] expected;
    input ack;
    reg [7:0] actual;
    integer b;
    begin
        for (b=7;b>=0;b=b-1) begin @(posedge scl); #1;actual[b]=sda; end
        if (actual!==expected) $fatal(1,"I2C byte expected %h got %h",expected,actual);
        @(negedge scl); #1;slave_sda_low=ack;
        @(posedge scl); @(negedge scl); #1;slave_sda_low=0;
    end
endtask
task send_byte;
    input [7:0] value;
    input expected_ack;
    integer b;
    begin
        for (b=7;b>=0;b=b-1) begin
            #1;slave_sda_low=!value[b]; @(posedge scl); @(negedge scl);
        end
        #1;slave_sda_low=0; @(posedge scl); #1;
        if (sda!==!expected_ack) $fatal(1,"Master ACK/NACK mismatch");
        @(negedge scl); #1;
    end
endtask
task serve_read;
    input [15:0] address;
    input integer length;
    input [79:0] bytes;
    integer i;
    begin
        bus_start;receive_byte(8'hba,1);receive_byte(address[15:8],1);
        receive_byte(address[7:0],1);bus_start;receive_byte(8'hbb,1);
        for(i=0;i<length;i=i+1) send_byte(bytes[i*8 +: 8],i!=length-1);
        bus_stop;
    end
endtask
task serve_clear;
    begin
        bus_start;receive_byte(8'hba,1);receive_byte(8'h81,1);
        receive_byte(8'h4e,1);receive_byte(8'h00,1);bus_stop;
    end
endtask
