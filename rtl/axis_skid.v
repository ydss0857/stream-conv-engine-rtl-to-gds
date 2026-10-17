`timescale 1ns / 1ps
// axis_skid: two-entry AXI4-Stream skid buffer.
//
// Breaks the combinational tready path between stages while keeping full
// throughput (one beat per clock). s_ready is driven directly by a flop, so
// it has no combinational dependence on m_ready, and m_valid/m_data are
// registered as well.
//
// Entries:
//   main - the beat currently presented on the master port
//   skid - a beat accepted on the cycle the master port stalled; it is the
//          next one out, and while it is occupied the slave port is not ready
//
// Pack tdata/tuser/tlast (or anything else) into DATA_W.

module axis_skid #(
    parameter integer DATA_W = 8
) (
    input  wire              clk,
    input  wire              rstn,

    input  wire [DATA_W-1:0] s_data,
    input  wire              s_valid,
    output wire              s_ready,

    output reg  [DATA_W-1:0] m_data,
    output reg               m_valid,
    input  wire              m_ready
);
    reg [DATA_W-1:0] skid_data;
    reg              skid_valid;

    assign s_ready = !skid_valid;

    wire main_free = !m_valid || m_ready;   // main entry empties this cycle
    wire s_fire    = s_valid && s_ready;

    always @(posedge clk) begin
        if (!rstn) begin
            m_valid    <= 1'b0;
            skid_valid <= 1'b0;
        end else if (main_free) begin
            if (skid_valid) begin           // drain the skid entry first
                m_valid    <= 1'b1;
                skid_valid <= 1'b0;
            end else begin                  // pass the input straight to main
                m_valid    <= s_valid;
            end
        end else if (s_fire) begin          // main stalled: park the new beat
            skid_valid <= 1'b1;
        end
    end

    always @(posedge clk) begin
        if (main_free) begin
            if (skid_valid)  m_data <= skid_data;
            else if (s_valid) m_data <= s_data;
        end
        if (!main_free && s_fire)
            skid_data <= s_data;
    end
endmodule
