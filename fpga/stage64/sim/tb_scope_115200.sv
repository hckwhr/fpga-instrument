`timescale 1ns/1ps
// Keep the original fast regression and also exercise real production line rate.
module tb_scope_115200;
    tb_scope_production_uart #(.CPB(434)) test();
endmodule
