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

`ifdef FORMAL
    // ---------------------------------------------------------------------
    // Formal properties (SymbiYosys: formal/skid). Ignored by other tools.
    // ---------------------------------------------------------------------
    reg f_past_valid = 1'b0;
    always @(posedge clk) f_past_valid <= 1'b1;

    // Start in reset.
    always @(*) if (!f_past_valid) assume(!rstn);

    // Upstream obeys AXI4-Stream: a beat offered and not taken is held.
    always @(posedge clk)
        if (f_past_valid && $past(rstn) && $past(s_valid && !s_ready))
            assume(s_valid && s_data == $past(s_data));

    // Downstream sees AXI4-Stream: a beat offered and not taken is held.
    always @(posedge clk)
        if (f_past_valid && $past(rstn) && rstn && $past(m_valid && !m_ready))
            assert(m_valid && m_data == $past(m_data));

    // Reset empties the buffer.
    always @(posedge clk)
        if (f_past_valid && !$past(rstn))
            assert(!m_valid && !skid_valid);

    // The skid entry is only ever used behind a full main entry.
    always @(*) if (rstn && skid_valid) assert(m_valid);

    // Data integrity: track one arbitrary beat (the solver picks which) and
    // prove it leaves intact and in order. Because the index is arbitrary,
    // this covers every beat: nothing is dropped, duplicated, reordered or
    // corrupted.
    (* anyconst *) reg [3:0] f_idx;
    reg [3:0]        f_in_cnt, f_out_cnt;
    reg [DATA_W-1:0] f_data;
    wire [3:0] f_occ = f_in_cnt - f_out_cnt;     // beats inside the buffer
    wire [3:0] f_pos = f_idx - f_out_cnt;        // tracked beat's place in the queue
    wire       f_pending = (f_pos < f_occ);      // tracked beat is inside

    always @(posedge clk) begin
        if (!rstn) begin
            f_in_cnt  <= 4'd0;
            f_out_cnt <= 4'd0;
        end else begin
            if (s_fire) f_in_cnt <= f_in_cnt + 4'd1;
            if (m_valid && m_ready) f_out_cnt <= f_out_cnt + 4'd1;
            if (s_fire && f_in_cnt == f_idx) f_data <= s_data;
        end
    end

    always @(*) begin
        if (rstn && f_past_valid) begin
            assert(f_occ == {3'd0, m_valid} + {3'd0, skid_valid});
            if (f_pending && f_pos == 4'd0) assert(m_valid && m_data == f_data);
            if (f_pending && f_pos == 4'd1) assert(skid_valid && skid_data == f_data);
            if (m_valid && m_ready && f_out_cnt == f_idx) assert(f_pending && m_data == f_data);
        end
    end

    // Reachability: the interesting states actually happen.
    always @(posedge clk) begin
        if (rstn) begin
            cover(skid_valid);                                   // skid entry used
            cover(f_past_valid && $past(skid_valid) && !skid_valid && m_valid); // and drained
            cover(f_out_cnt == 4'd5);                            // a stream of beats
        end
    end
`endif
endmodule
