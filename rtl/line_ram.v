`timescale 1ns / 1ps
// line_ram: simple dual-port RAM, one synchronous read port and one write port.
//
// Written in the template Vivado infers as block RAM. In the ASIC flow this
// module is the one place to swap in flip-flops or an SRAM macro.

module line_ram #(
    parameter integer DEPTH  = 2048,
    parameter integer AW     = 11,
    parameter integer DATA_W = 8
) (
    input  wire              clk,

    input  wire              we,
    input  wire [AW-1:0]     waddr,
    input  wire [DATA_W-1:0] wdata,

    input  wire              re,
    input  wire [AW-1:0]     raddr,
    output reg  [DATA_W-1:0] rdata
);
    reg [DATA_W-1:0] mem [0:DEPTH-1];

    always @(posedge clk) begin
        if (we) mem[waddr] <= wdata;
        if (re) rdata <= mem[raddr];
    end
endmodule
