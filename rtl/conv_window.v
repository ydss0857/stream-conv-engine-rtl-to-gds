`timescale 1ns / 1ps
// conv_window: turns a stream of 8-bit pixels into a stream of 3x3 windows.
//
// For every input pixel (r, c) of a W x H frame it outputs the 3x3
// neighbourhood centred on (r, c), with out-of-frame neighbours replicated
// from the nearest edge pixel (matches model/conv_model.py: window()).
//
// Window packing, row-major, p0 = top-left:
//   m_data[8*k +: 8] = p_k      p0 p1 p2
//                               p3 p4 p5
//                               p6 p7 p8
//
// How it works
//   A position counter (ir, ic) walks (H+1) x (W+1) positions per frame.
//   Positions with ir < H and ic < W consume one input pixel; the extra
//   column (ic == W) and extra row (ir == H) are flush positions that
//   consume nothing. The window centred on (ir-1, ic-1) is emitted at each
//   position with ir >= 1 and ic >= 1, so output runs one line plus one
//   pixel behind input.
//
//   Stage A  position counter; accepts a pixel; reads both line buffers at ic.
//   Stage B  builds the new column {LB2, LB1, pixel}, writes the line buffers
//            back (LB2[ic] <= LB1[ic], LB1[ic] <= pixel), shifts the column
//            registers, applies edge replication, and forms the window.
//   Output   registered window + tuser/tlast.
//   The pipeline advances as a whole whenever the output register is free.
//
// Framing
//   WIDTH/HEIGHT are latched at start of frame. Before a frame starts,
//   pixels without tuser are dropped. tlast at the wrong column, tuser in
//   mid-frame, or an invalid WIDTH/HEIGHT set the sticky err flag; the frame
//   still completes by count and the next tuser resynchronises.

module conv_window #(
    parameter integer MAX_WIDTH = 2048,
    parameter integer AW        = 11       // clog2(MAX_WIDTH)
) (
    input  wire        clk,
    input  wire        rstn,

    input  wire [11:0] cfg_width,
    input  wire [11:0] cfg_height,
    output reg         err,
    input  wire        err_clr,

    input  wire [7:0]  s_data,
    input  wire        s_valid,
    input  wire        s_user,
    input  wire        s_last,
    output wire        s_ready,

    output reg  [71:0] m_data,
    output reg         m_valid,
    output reg         m_user,
    output reg         m_last,
    input  wire        m_ready
);
    // ------------------------------------------------------------ stage A
    // Position tracking uses down-counters (columns/rows remaining) and
    // registered one-bit flags computed one step ahead, instead of comparing
    // 12-bit counters with WIDTH/HEIGHT every cycle. In the sky130 ASIC flow
    // those comparators fed a_fire and made a ~20-level critical path; here
    // a_fire depends only on flops through a couple of gates.
    //   column ic (0..width):  c_zero ic==0   c_one ic==1
    //                          c_last ic==width-1   c_flush ic==width
    //   row ir (0..height):    r_zero ir==0   r_one ir==1
    //                          r_last ir==height-1  r_flush ir==height
    reg        running;
    reg [11:0] width, height;     // latched at start of frame
    reg [11:0] ic;                // column, used as the line-buffer address
    reg [11:0] cl, rl;            // columns / rows remaining: width-ic, height-ir
    reg        c_zero, c_one, c_last, c_flush, w_is1;
    reg        r_zero, r_one, r_last, r_flush;

    wire cfg_ok   = (cfg_width != 0) && (cfg_height != 0) && (cfg_width <= MAX_WIDTH);
    wire adv      = !m_valid || m_ready;            // whole pipeline moves
    wire need_pix = !r_flush && !c_flush;           // not a flush position
    wire a_fire   = running && adv && (!need_pix || s_valid);
    wire pix_fire = a_fire && need_pix;
    wire at_end   = r_flush && c_flush;
    wire lb_rd    = a_fire && !c_flush;

    // Idle: swallow pixels until a start of frame arrives.
    assign s_ready = running ? (adv && need_pix) : (!s_user || !cfg_ok);

    always @(posedge clk) begin
        if (!rstn) begin
            running <= 1'b0;
        end else if (!running) begin
            if (s_valid && s_user && cfg_ok) begin
                running <= 1'b1;
                width   <= cfg_width;
                height  <= cfg_height;
                w_is1   <= (cfg_width == 12'd1);
                ic      <= 12'd0;
                cl      <= cfg_width;
                c_zero  <= 1'b1;
                c_one   <= 1'b0;
                c_last  <= (cfg_width == 12'd1);
                c_flush <= 1'b0;
                rl      <= cfg_height;
                r_zero  <= 1'b1;
                r_one   <= 1'b0;
                r_last  <= (cfg_height == 12'd1);
                r_flush <= 1'b0;
            end
        end else if (a_fire) begin
            if (at_end) begin
                running <= 1'b0;
            end else if (c_flush) begin           // wrap to the next row
                ic      <= 12'd0;
                cl      <= width;
                c_zero  <= 1'b1;
                c_one   <= 1'b0;
                c_last  <= w_is1;
                c_flush <= 1'b0;
                rl      <= rl - 12'd1;
                r_zero  <= 1'b0;
                r_one   <= r_zero;
                r_last  <= (rl == 12'd2);
                r_flush <= r_last;
            end else begin                        // next column
                ic      <= ic + 12'd1;
                cl      <= cl - 12'd1;
                c_zero  <= 1'b0;
                c_one   <= c_zero;
                c_last  <= (cl == 12'd2);
                c_flush <= c_last;
            end
        end
    end

    always @(posedge clk) begin
        if (!rstn)
            err <= 1'b0;
        else if ((!running && s_valid && s_user && !cfg_ok) ||
                 (pix_fire && (s_last != c_last)) ||
                 (pix_fire && s_user && !(r_zero && c_zero)))
            err <= 1'b1;
        else if (err_clr)
            err <= 1'b0;
    end

    // ------------------------------------------------------------ line buffers
    wire [7:0] lb1_q, lb2_q;      // rows ir-1 and ir-2 at column ic, one cycle later
    reg        b_valid;
    reg  [7:0] b_pix;
    reg [AW-1:0] b_ic;
    reg        b_lb, b_top, b_bot, b_left, b_right, b_emit, b_user, b_last;
    wire       b_fire = adv && b_valid;
    wire       lb_wr  = b_fire && b_lb;

    line_ram #(.DEPTH(MAX_WIDTH), .AW(AW), .DATA_W(8)) lb1 (
        .clk(clk), .we(lb_wr), .waddr(b_ic), .wdata(b_pix),
        .re(lb_rd), .raddr(ic[AW-1:0]), .rdata(lb1_q));

    line_ram #(.DEPTH(MAX_WIDTH), .AW(AW), .DATA_W(8)) lb2 (
        .clk(clk), .we(lb_wr), .waddr(b_ic), .wdata(lb1_q),
        .re(lb_rd), .raddr(ic[AW-1:0]), .rdata(lb2_q));

    // ------------------------------------------------------------ stage B
    always @(posedge clk) begin
        if (!rstn)
            b_valid <= 1'b0;
        else if (adv)
            b_valid <= a_fire;
    end

    always @(posedge clk) begin
        if (a_fire) begin
            b_pix   <= s_data;
            b_ic    <= ic[AW-1:0];
            b_lb    <= !c_flush;                    // touches the line buffers
            b_top   <= r_one;                       // row above is off-frame
            b_bot   <= r_flush;                     // row below is off-frame
            b_left  <= c_one;                       // column left is off-frame
            b_right <= c_flush;                     // column right is off-frame
            b_emit  <= !r_zero && !c_zero;
            b_user  <= r_one && c_one;
            b_last  <= c_flush;
        end
    end

    // New column at ic (rows ir-2, ir-1, ir), with vertical replication.
    wire [7:0] n_top = b_top ? lb1_q : lb2_q;
    wire [7:0] n_mid = lb1_q;
    wire [7:0] n_bot = b_bot ? lb1_q : b_pix;

    // Column registers: c1 = column ic-2, c2 = column ic-1.
    reg [7:0] c1_top, c1_mid, c1_bot, c2_top, c2_mid, c2_bot;

    always @(posedge clk) begin
        if (b_fire && b_lb) begin
            {c1_top, c1_mid, c1_bot} <= {c2_top, c2_mid, c2_bot};
            {c2_top, c2_mid, c2_bot} <= {n_top, n_mid, n_bot};
        end
    end

    // Horizontal replication.
    wire [7:0] l_top = b_left  ? c2_top : c1_top;
    wire [7:0] l_mid = b_left  ? c2_mid : c1_mid;
    wire [7:0] l_bot = b_left  ? c2_bot : c1_bot;
    wire [7:0] r_top = b_right ? c2_top : n_top;
    wire [7:0] r_mid = b_right ? c2_mid : n_mid;
    wire [7:0] r_bot = b_right ? c2_bot : n_bot;

    wire [71:0] window = {r_bot, c2_bot, l_bot,
                          r_mid, c2_mid, l_mid,
                          r_top, c2_top, l_top};

    // ------------------------------------------------------------ output
    always @(posedge clk) begin
        if (!rstn)
            m_valid <= 1'b0;
        else if (adv)
            m_valid <= b_valid && b_emit;
    end

    always @(posedge clk) begin
        if (b_fire && b_emit) begin
            m_data <= window;
            m_user <= b_user;
            m_last <= b_last;
        end
    end

`ifdef FORMAL
    // ---------------------------------------------------------------------
    // Formal properties (SymbiYosys: formal/window). Run with a small
    // MAX_WIDTH and small frames (F_MAXW x F_MAXH).
    //   default      : AXI4-Stream rules, framing, no false error
    //   FORMAL_DATA  : additionally, every window holds the right pixels
    // ---------------------------------------------------------------------
`ifndef F_MAXW
`define F_MAXW 3
`endif
`ifndef F_MAXH
`define F_MAXH 3
`endif
    reg f_past_valid = 1'b0;
    always @(posedge clk) f_past_valid <= 1'b1;
    always @(*) if (!f_past_valid) assume(!rstn);

    // Static, small configuration; error flag never cleared by software.
    always @(*) begin
        assume(cfg_width  >= 1 && cfg_width  <= `F_MAXW);
        assume(cfg_height >= 1 && cfg_height <= `F_MAXH);
        assume(!err_clr);
    end
    always @(posedge clk) if (f_past_valid)
        assume(cfg_width == $past(cfg_width) && cfg_height == $past(cfg_height));

    // Upstream obeys AXI4-Stream and sends well-formed frames.
    always @(posedge clk)
        if (f_past_valid && $past(rstn) && $past(s_valid && !s_ready))
            assume(s_valid && s_data == $past(s_data) && s_user == $past(s_user) && s_last == $past(s_last));

    reg [3:0] f_ir, f_ic;     // input position of the next beat
    reg       f_ifr;          // input frame parity
    wire      f_s_fire = s_valid && s_ready;
    always @(*) if (s_valid) begin
        assume(s_user == (f_ir == 0 && f_ic == 0));
        assume(s_last == (f_ic == cfg_width - 1));
    end
    always @(posedge clk) begin
        if (!rstn) begin
            f_ir <= 0; f_ic <= 0; f_ifr <= 0;
        end else if (f_s_fire) begin
            if (f_ic == cfg_width - 1) begin
                f_ic <= 0;
                if (f_ir == cfg_height - 1) begin f_ir <= 0; f_ifr <= !f_ifr; end
                else f_ir <= f_ir + 1;
            end else f_ic <= f_ic + 1;
        end
    end

    // Downstream sees AXI4-Stream: offered beats are held.
    always @(posedge clk)
        if (f_past_valid && $past(rstn) && rstn && $past(m_valid && !m_ready))
            assert(m_valid && m_data == $past(m_data) && m_user == $past(m_user) && m_last == $past(m_last));

    // Well-formed input never raises the error flag.
    always @(*) if (rstn) assert(!err);

    // Output framing: tuser on the first window of each frame, tlast on each line end.
    reg [3:0] f_or, f_oc;
    reg       f_ofr;
    wire      f_m_fire = m_valid && m_ready;
    always @(posedge clk) begin
        if (!rstn) begin
            f_or <= 0; f_oc <= 0; f_ofr <= 0;
        end else if (f_m_fire) begin
            if (f_oc == cfg_width - 1) begin
                f_oc <= 0;
                if (f_or == cfg_height - 1) begin f_or <= 0; f_ofr <= !f_ofr; end
                else f_or <= f_or + 1;
            end else f_oc <= f_oc + 1;
        end
    end
    always @(*) if (rstn && m_valid) begin
        assert(m_user == (f_or == 0 && f_oc == 0));
        assert(m_last == (f_oc == cfg_width - 1));
    end

`ifdef FORMAL_DATA
    // Window contents: track one arbitrary pixel position per frame parity and
    // check every output window that should contain it.
    (* anyconst *) reg [3:0] f_pr, f_pc;
    always @(*) assume(f_pr < cfg_height && f_pc < cfg_width);
    reg [7:0] f_pix [0:1];
    reg [1:0] f_have;
    always @(posedge clk) begin
        if (!rstn) f_have <= 2'b00;
        else if (f_s_fire && f_ir == f_pr && f_ic == f_pc) begin
            f_pix[f_ifr]  <= s_data;
            f_have[f_ifr] <= 1'b1;
        end
    end

    function [3:0] clampi(input signed [5:0] v, input [3:0] n);
        clampi = (v < 0) ? 4'd0 : (v >= $signed({2'b0, n})) ? n - 4'd1 : v[3:0];
    endfunction

    genvar f_k;
    generate for (f_k = 0; f_k < 9; f_k = f_k + 1) begin : g_fwin
        wire [3:0] sr = clampi($signed({2'b0, f_or}) + (f_k / 3) - 1, cfg_height);
        wire [3:0] sc = clampi($signed({2'b0, f_oc}) + (f_k % 3) - 1, cfg_width);
        always @(*)
            if (rstn && m_valid && sr == f_pr && sc == f_pc)
                assert(f_have[f_ofr] && m_data[8*f_k +: 8] == f_pix[f_ofr]);
    end endgenerate

`endif

    // Reachability: a largest-size frame completes, and the next one starts.
    always @(posedge clk) if (rstn) begin
        cover(f_m_fire && m_last && f_or == cfg_height - 1 && cfg_width == `F_MAXW && cfg_height == `F_MAXH);
        cover(f_m_fire && f_ofr && m_user);
    end
`endif
endmodule
