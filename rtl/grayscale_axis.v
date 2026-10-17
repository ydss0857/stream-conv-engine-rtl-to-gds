`timescale 1ns / 1ps
// grayscale_axis: AXI4-Stream luminance filter, one register stage.
//
// Pixel format follows the Xilinx AXI4-Stream Video RGB convention used by
// dvi2rgb / v_vid_in_axi4s: tdata = {R[23:16], B[15:8], G[7:0]}.
//
// Backpressure: the output register only loads when it is empty or its
// current beat is being accepted downstream this cycle, so no beat is ever
// overwritten or duplicated while m_axis_tready is low.

module grayscale_axis (
    input  wire        aclk,
    input  wire        aresetn,

    input  wire [23:0] s_axis_tdata,
    input  wire        s_axis_tvalid,
    input  wire        s_axis_tuser,   // start of frame
    input  wire        s_axis_tlast,   // end of line
    output wire        s_axis_tready,

    output reg  [23:0] m_axis_tdata,
    output reg         m_axis_tvalid,
    output reg         m_axis_tuser,
    output reg         m_axis_tlast,
    input  wire        m_axis_tready
);
    wire [7:0] r = s_axis_tdata[23:16];
    wire [7:0] b = s_axis_tdata[15:8];
    wire [7:0] g = s_axis_tdata[7:0];

    // Y = (77R + 150G + 29B) / 256  (BT.601 weights; 77+150+29 = 256)
    wire [15:0] y_sum = r * 8'd77 + g * 8'd150 + b * 8'd29;
    wire [7:0]  y     = y_sum[15:8];

    // Output slot is free if empty, or if its beat is taken this cycle.
    wire out_free = !m_axis_tvalid || m_axis_tready;
    assign s_axis_tready = out_free;

    always @(posedge aclk) begin
        if (!aresetn) begin
            m_axis_tvalid <= 1'b0;
        end else if (out_free) begin
            m_axis_tvalid <= s_axis_tvalid;
        end
    end

    always @(posedge aclk) begin
        if (out_free && s_axis_tvalid) begin
            m_axis_tdata <= {y, y, y};
            m_axis_tuser <= s_axis_tuser;
            m_axis_tlast <= s_axis_tlast;
        end
    end
endmodule
