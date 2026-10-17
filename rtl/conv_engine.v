`timescale 1ns / 1ps
// conv_engine: top level of the streaming 3x3 convolution engine.
//
//   s_axis_video -> skid -> luma_axis -> conv_window -> conv_datapath -> {Y,Y,Y} -> skid -> m_axis_video
//                                       ^               ^
//                                       +-- conv_regs --+ <- s_axi_ctrl (AXI4-Lite)
//
// Video: 24-bit AXI4-Stream video, {R[23:16], B[15:8], G[7:0]}, tuser = start
// of frame, tlast = end of line. Output has the same pixel count and framing.
// Control: AXI4-Lite register map in conv_regs.v / docs/spec.md.
// One clock domain: aclk runs both the video stream and the control port.
//
// Bit-exact with model/conv_model.py: process_frame().

module conv_engine #(
    parameter integer MAX_WIDTH = 2048,
    parameter integer AW        = 11       // clog2(MAX_WIDTH)
) (
    input  wire        aclk,
    input  wire        aresetn,

    // AXI4-Stream video in
    input  wire [23:0] s_axis_video_tdata,
    input  wire        s_axis_video_tvalid,
    output wire        s_axis_video_tready,
    input  wire        s_axis_video_tuser,
    input  wire        s_axis_video_tlast,

    // AXI4-Stream video out
    output wire [23:0] m_axis_video_tdata,
    output wire        m_axis_video_tvalid,
    input  wire        m_axis_video_tready,
    output wire        m_axis_video_tuser,
    output wire        m_axis_video_tlast,

    // AXI4-Lite control
    input  wire [5:0]  s_axi_ctrl_awaddr,
    input  wire        s_axi_ctrl_awvalid,
    output wire        s_axi_ctrl_awready,
    input  wire [31:0] s_axi_ctrl_wdata,
    input  wire [3:0]  s_axi_ctrl_wstrb,
    input  wire        s_axi_ctrl_wvalid,
    output wire        s_axi_ctrl_wready,
    output wire [1:0]  s_axi_ctrl_bresp,
    output wire        s_axi_ctrl_bvalid,
    input  wire        s_axi_ctrl_bready,
    input  wire [5:0]  s_axi_ctrl_araddr,
    input  wire        s_axi_ctrl_arvalid,
    output wire        s_axi_ctrl_arready,
    output wire [31:0] s_axi_ctrl_rdata,
    output wire [1:0]  s_axi_ctrl_rresp,
    output wire        s_axi_ctrl_rvalid,
    input  wire        s_axi_ctrl_rready
);
    // ------------------------------------------------------------ registers
    wire        cfg_enable, cfg_thresh_en;
    wire [1:0]  cfg_mode;
    wire [3:0]  cfg_shift0, cfg_shift1;
    wire [7:0]  cfg_thresh;
    wire [11:0] cfg_width, cfg_height;
    wire [71:0] cfg_k0, cfg_k1;
    wire        frame_err, frame_err_clr;

    conv_regs u_regs (
        .clk(aclk), .rstn(aresetn),
        .s_axi_awaddr(s_axi_ctrl_awaddr), .s_axi_awvalid(s_axi_ctrl_awvalid), .s_axi_awready(s_axi_ctrl_awready),
        .s_axi_wdata(s_axi_ctrl_wdata), .s_axi_wstrb(s_axi_ctrl_wstrb),
        .s_axi_wvalid(s_axi_ctrl_wvalid), .s_axi_wready(s_axi_ctrl_wready),
        .s_axi_bresp(s_axi_ctrl_bresp), .s_axi_bvalid(s_axi_ctrl_bvalid), .s_axi_bready(s_axi_ctrl_bready),
        .s_axi_araddr(s_axi_ctrl_araddr), .s_axi_arvalid(s_axi_ctrl_arvalid), .s_axi_arready(s_axi_ctrl_arready),
        .s_axi_rdata(s_axi_ctrl_rdata), .s_axi_rresp(s_axi_ctrl_rresp),
        .s_axi_rvalid(s_axi_ctrl_rvalid), .s_axi_rready(s_axi_ctrl_rready),
        .cfg_enable(cfg_enable), .cfg_thresh_en(cfg_thresh_en), .cfg_mode(cfg_mode),
        .cfg_shift0(cfg_shift0), .cfg_shift1(cfg_shift1), .cfg_thresh(cfg_thresh),
        .cfg_width(cfg_width), .cfg_height(cfg_height), .cfg_k0(cfg_k0), .cfg_k1(cfg_k1),
        .frame_err(frame_err), .frame_err_clr(frame_err_clr));

    // ------------------------------------------------------------ input skid
    wire [23:0] in_rgb;
    wire        in_user, in_last, in_valid, in_ready;

    axis_skid #(.DATA_W(26)) u_in_skid (
        .clk(aclk), .rstn(aresetn),
        .s_data({s_axis_video_tuser, s_axis_video_tlast, s_axis_video_tdata}),
        .s_valid(s_axis_video_tvalid), .s_ready(s_axis_video_tready),
        .m_data({in_user, in_last, in_rgb}), .m_valid(in_valid), .m_ready(in_ready));

    // ------------------------------------------------------------ luma
    wire [7:0] luma;
    wire       luma_valid, luma_ready, luma_user, luma_last;

    luma_axis u_luma (
        .clk(aclk), .rstn(aresetn),
        .s_data(in_rgb), .s_valid(in_valid), .s_user(in_user), .s_last(in_last), .s_ready(in_ready),
        .m_data(luma), .m_valid(luma_valid), .m_user(luma_user), .m_last(luma_last), .m_ready(luma_ready));

    // ------------------------------------------------------------ 3x3 window
    wire [71:0] win;
    wire        win_valid, win_ready, win_user, win_last;

    conv_window #(.MAX_WIDTH(MAX_WIDTH), .AW(AW)) u_window (
        .clk(aclk), .rstn(aresetn),
        .cfg_width(cfg_width), .cfg_height(cfg_height),
        .err(frame_err), .err_clr(frame_err_clr),
        .s_data(luma), .s_valid(luma_valid), .s_user(luma_user), .s_last(luma_last), .s_ready(luma_ready),
        .m_data(win), .m_valid(win_valid), .m_user(win_user), .m_last(win_last), .m_ready(win_ready));

    // ------------------------------------------------------------ MAC datapath
    wire [7:0] pix;
    wire       pix_valid, pix_ready, pix_user, pix_last;

    conv_datapath u_datapath (
        .clk(aclk), .rstn(aresetn),
        .cfg_enable(cfg_enable), .cfg_k0(cfg_k0), .cfg_k1(cfg_k1),
        .cfg_shift0(cfg_shift0), .cfg_shift1(cfg_shift1), .cfg_mode(cfg_mode),
        .cfg_thresh_en(cfg_thresh_en), .cfg_thresh(cfg_thresh),
        .s_data(win), .s_valid(win_valid), .s_user(win_user), .s_last(win_last), .s_ready(win_ready),
        .m_data(pix), .m_valid(pix_valid), .m_user(pix_user), .m_last(pix_last), .m_ready(pix_ready));

    // ------------------------------------------------------------ output skid
    axis_skid #(.DATA_W(26)) u_out_skid (
        .clk(aclk), .rstn(aresetn),
        .s_data({pix_user, pix_last, pix, pix, pix}), .s_valid(pix_valid), .s_ready(pix_ready),
        .m_data({m_axis_video_tuser, m_axis_video_tlast, m_axis_video_tdata}),
        .m_valid(m_axis_video_tvalid), .m_ready(m_axis_video_tready));
endmodule
