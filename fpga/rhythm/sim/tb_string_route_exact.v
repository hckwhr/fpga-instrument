`timescale 1ns/1ps
module tb_string_route_exact;
    reg clk=0, reset_n=0, strobe=0, enable=1, trigger=0, held=1, pluck=1;
    reg [5:0] note=12;
    reg [6:0] force_value=96;
    reg signed [16:0] delta=0;
    wire signed [15:0] actual, expected;
    wire [15:0] level_actual, level_expected;
    wire active_actual,active_expected,busy_actual,busy_expected,accept_actual,accept_expected;
    integer i,j,k,cycles=0,interpolations=0;
    reg [31:0] rng=32'h7391a5ce;
    reg [63:0] packed_coefficients;
    physical_string_voice dut(.clk(clk),.reset_n(reset_n),.sample_strobe(strobe),
        .enable(enable),.trigger(trigger),.held(held),.pluck_mode(pluck),.note(note),
        .force_value(force_value),.delay_delta(delta),.sample(actual),.active(active_actual),
        .level(level_actual),.busy(busy_actual),.accepting(accept_actual));
    stage22_physical_string_voice reference(.clk(clk),.reset_n(reset_n),.sample_strobe(strobe),
        .enable(enable),.trigger(trigger),.held(held),.pluck_mode(pluck),.note(note),
        .force_value(force_value),.delay_delta({{2{delta[16]}},delta}),
        .sample(expected),.active(active_expected),.level(level_expected),
        .busy(busy_expected),.accepting(accept_expected));
    always #5 clk=~clk;
    always @(posedge clk) begin
        #1;
        if(reset_n)begin
            cycles=cycles+1;
            if({actual,level_actual,active_actual,busy_actual,accept_actual} !==
               {expected,level_expected,active_expected,busy_expected,accept_expected})
                $fatal(1,"cycle mismatch %0d: PCM %0d / %0d",cycles,actual,expected);
            if(dut.state==21)begin
                interpolations=interpolations+1;
                if(dut.interp_acc !== reference.interp_acc)
                    $fatal(1,"interpolation accumulator differs");
            end
        end
    end
    initial begin
        for(i=0;i<256;i=i+1)begin
            packed_coefficients=reference.string_interp(i[7:0]);
            for(j=0;j<4;j=j+1)
                if(dut.string_interp_serial({j[1:0],i[7:0]}) !==
                   ((packed_coefficients >> ((3-j)*16)) & 64'hffff))
                    $fatal(1,"coefficient mismatch fraction=%0d tap=%0d",i,j);
        end
        repeat(4)@(negedge clk);
        reset_n=1;
        // Fixed seed, unchanged 36 low/mid notes, full signed-17 range including clamp extremes.
        // Changes cover replacement, release, disable and reset while active.
        for(i=0;i<12000;i=i+1)begin
            rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);
            if(i%97==0)begin
                note=(i/97)%36;force_value=32+(rng%96);trigger=1;
            end
            if(i%19==0)delta=rng[16:0];
            if(i%251==0)delta=-17'sd40469;
            if(i%257==0)delta=17'sd50217;
            if(i%263==0)delta=0;
            held=(i%311)<280;pluck=(i%997)<700;
            enable=(i%2003)!=2002;
            if(i==5011 || i==9001)reset_n=0;
            strobe=1;
            @(negedge clk);strobe=0;trigger=0;
            for(k=1;k<64;k=k+1)@(negedge clk);
            while(busy_actual)@(negedge clk);
            reset_n=1;
        end
        if(interpolations<1000)$fatal(1,"insufficient fractional coverage");
        $display("PASS: 1024 coefficient entries; %0d cycle-exact checks; %0d interpolations",
                 cycles,interpolations);
        $finish;
    end
    initial begin #20000000;$fatal(1,"timeout");end
endmodule
