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
    reg        running;
    reg [11:0] width, height;     // latched at start of frame
    reg [11:0] ir, ic;            // position: 0..height, 0..width

    wire cfg_ok   = (cfg_width != 0) && (cfg_height != 0) && (cfg_width <= MAX_WIDTH);
    wire adv      = !m_valid || m_ready;            // whole pipeline moves
    wire need_pix = (ir < height) && (ic < width);  // not a flush position
    wire a_fire   = running && adv && (!need_pix || s_valid);
    wire pix_fire = a_fire && need_pix;
    wire at_end   = (ir == height) && (ic == width);
    wire lb_rd    = a_fire && (ic < width);

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
                ir      <= 12'd0;
                ic      <= 12'd0;
            end
        end else if (a_fire) begin
            if (at_end) begin
                running <= 1'b0;
            end else if (ic == width) begin
                ic <= 12'd0;
                ir <= ir + 12'd1;
            end else begin
                ic <= ic + 12'd1;
            end
        end
    end

    always @(posedge clk) begin
        if (!rstn)
            err <= 1'b0;
        else if ((!running && s_valid && s_user && !cfg_ok) ||
                 (pix_fire && (s_last != (ic == width - 12'd1))) ||
                 (pix_fire && s_user && (ir != 0 || ic != 0)))
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
            b_lb    <= (ic < width);                // touches the line buffers
            b_top   <= (ir == 12'd1);               // row above is off-frame
            b_bot   <= (ir == height);              // row below is off-frame
            b_left  <= (ic == 12'd1);               // column left is off-frame
            b_right <= (ic == width);               // column right is off-frame
            b_emit  <= (ir != 0) && (ic != 0);
            b_user  <= (ir == 12'd1) && (ic == 12'd1);
            b_last  <= (ic == width);
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
endmodule
