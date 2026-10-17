`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/07/16 17:05:29
// Design Name: 
// Module Name: grayscale_axis
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module grayscale_axis(
    input  wire         aclk,
    input  wire         aresetn,
    input  wire [23:0]  s_axis_tdata,   // input pixel, e.g. {R,G,B}
    input  wire         s_axis_tvalid,
    input  wire         s_axis_tuser,   // start-of-frame
    input  wire         s_axis_tlast,   // end-of-line
    output wire         s_axis_tready,
    output reg  [23:0]  m_axis_tdata,
    output reg          m_axis_tvalid,
    output reg          m_axis_tuser,
    output reg          m_axis_tlast,
    input  wire         m_axis_tready
);
    wire [7:0] r = s_axis_tdata[23:16];
    wire [7:0] g = s_axis_tdata[15:8];
    wire [7:0] b = s_axis_tdata[7:0];
    // luminance-weighted grayscale
    wire [7:0] gray = (r*77 + g*150 + b*29) >> 8;

    assign s_axis_tready = m_axis_tready;

    always @(posedge aclk) begin
        if (!aresetn) begin
            m_axis_tvalid <= 0;
        end else begin
            m_axis_tdata  <= {gray, gray, gray}; // replicate to RGB
            m_axis_tvalid <= s_axis_tvalid;
            m_axis_tuser  <= s_axis_tuser;
            m_axis_tlast  <= s_axis_tlast;
        end
    end
endmodule
