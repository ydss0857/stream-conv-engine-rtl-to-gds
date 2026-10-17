`timescale 1ns / 1ps
// mul_u8s8: registered u8 x s8 -> s17 multiplier.
//
// Kept as its own module so the use_dsp hint applies to the multiply only:
// on Xilinx parts it maps to one DSP48 (the output register goes into the
// DSP's MREG/PREG). Other tools ignore the attribute.

(* use_dsp = "yes" *)
module mul_u8s8 (
    input  wire               clk,
    input  wire               en,
    input  wire        [7:0]  a,     // unsigned pixel
    input  wire signed [7:0]  b,     // signed coefficient
    output reg  signed [16:0] p
);
    always @(posedge clk)
        if (en) p <= $signed({1'b0, a}) * b;
endmodule
