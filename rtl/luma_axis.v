`timescale 1ns / 1ps
// luma_axis: RGB -> 8-bit luma, pipelined over two stages.
//
//   Y = (77 R + 150 G + 29 B) >> 8         (BT.601 weights, 77 + 150 + 29 = 256)
//
// Input {R[23:16], B[15:8], G[7:0]} (Xilinx AXI4-Stream video RGB order).
// Stage 1 forms 77R + 29B and 150G in parallel; stage 2 adds them. Splitting
// the sum keeps each stage to one short carry chain at 150 MHz.
// The two stages stall together; s_ready is combinational from m_ready.

module luma_axis (
    input  wire        clk,
    input  wire        rstn,

    input  wire [23:0] s_data,
    input  wire        s_valid,
    input  wire        s_user,
    input  wire        s_last,
    output wire        s_ready,

    output reg  [7:0]  m_data,
    output reg         m_valid,
    output reg         m_user,
    output reg         m_last,
    input  wire        m_ready
);
    wire adv = !m_valid || m_ready;
    assign s_ready = adv;

    wire [7:0] r = s_data[23:16];
    wire [7:0] b = s_data[15:8];
    wire [7:0] g = s_data[7:0];

    reg        v1, user1, last1;
    reg [15:0] rb1;     // 77R + 29B  <= 26,010
    reg [15:0] g1;      // 150G       <= 38,250

    always @(posedge clk) begin
        if (adv) begin
            rb1   <= r * 8'd77 + b * 8'd29;
            g1    <= g * 8'd150;
            user1 <= s_user;
            last1 <= s_last;
        end
    end

    wire [15:0] y_sum = rb1 + g1;   // <= 65,280, fits 16 bits

    always @(posedge clk) begin
        if (adv && v1) begin
            m_data <= y_sum[15:8];
            m_user <= user1;
            m_last <= last1;
        end
    end

    always @(posedge clk) begin
        if (!rstn) begin
            v1      <= 1'b0;
            m_valid <= 1'b0;
        end else if (adv) begin
            v1      <= s_valid;
            m_valid <= v1;
        end
    end
endmodule
