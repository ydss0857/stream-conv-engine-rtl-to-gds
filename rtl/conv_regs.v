`timescale 1ns / 1ps
// conv_regs: AXI4-Lite control/status registers for the convolution engine.
//
// Register map (32-bit, byte offsets; unlisted offsets read 0, writes ignored)
//   0x00 CTRL    [0] ENABLE  [1] THRESH_EN  [3:2] MODE (0 LANE0, 1 ABS0, 2 MAG)
//   0x04 STATUS  [0] FRAME_ERR  sticky, write 1 to clear
//   0x08 SHIFT   [3:0] SHIFT0  [11:8] SHIFT1
//   0x0C THRESH  [7:0]
//   0x10 WIDTH   [11:0] pixels per line
//   0x14 HEIGHT  [11:0] lines per frame
//   0x20 K0_ROW0 0x24 K0_ROW1 0x28 K0_ROW2   [7:0] col0 [15:8] col1 [23:16] col2 (s8)
//   0x30 K1_ROW0 0x34 K1_ROW1 0x38 K1_ROW2
//   0x3C ID      read-only 0x434F4E56 ("CONV")
//
// Reset state: filter disabled (luma passes through), K0 = identity,
// 1280 x 720, threshold 128.
//
// The engine latches these settings at start of frame, so software may
// write them at any time without tearing the picture.
//
// AXI4-Lite: AW and W are accepted independently, in either order or
// together; the write happens once both have arrived. One outstanding
// write and one outstanding read. All responses are OKAY.

module conv_regs (
    input  wire        clk,
    input  wire        rstn,

    // AXI4-Lite slave
    input  wire [5:0]  s_axi_awaddr,
    input  wire        s_axi_awvalid,
    output wire        s_axi_awready,
    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output wire        s_axi_wready,
    output wire [1:0]  s_axi_bresp,
    output reg         s_axi_bvalid,
    input  wire        s_axi_bready,
    input  wire [5:0]  s_axi_araddr,
    input  wire        s_axi_arvalid,
    output wire        s_axi_arready,
    output reg  [31:0] s_axi_rdata,
    output wire [1:0]  s_axi_rresp,
    output reg         s_axi_rvalid,
    input  wire        s_axi_rready,

    // To the engine
    output wire        cfg_enable,
    output wire        cfg_thresh_en,
    output wire [1:0]  cfg_mode,
    output wire [3:0]  cfg_shift0,
    output wire [3:0]  cfg_shift1,
    output wire [7:0]  cfg_thresh,
    output wire [11:0] cfg_width,
    output wire [11:0] cfg_height,
    output wire [71:0] cfg_k0,          // coefficient (r, c) at [8*(3r+c) +: 8]
    output wire [71:0] cfg_k1,

    // From the engine
    input  wire        frame_err,       // sticky error flag inside conv_window
    output reg         frame_err_clr    // one-cycle pulse on a write-1-to-clear
);
    localparam [31:0] ID = 32'h434F_4E56;

    // ------------------------------------------------------------ storage
    reg [3:0]  ctrl;
    reg [11:0] shift;      // [3:0] shift0, [11:8] shift1 (bits 7:4 unused)
    reg [7:0]  thresh;
    reg [11:0] width, height;
    reg [23:0] k0r [0:2];
    reg [23:0] k1r [0:2];

    assign cfg_enable    = ctrl[0];
    assign cfg_thresh_en = ctrl[1];
    assign cfg_mode      = ctrl[3:2];
    assign cfg_shift0    = shift[3:0];
    assign cfg_shift1    = shift[11:8];
    assign cfg_thresh    = thresh;
    assign cfg_width     = width;
    assign cfg_height    = height;
    assign cfg_k0        = {k0r[2], k0r[1], k0r[0]};
    assign cfg_k1        = {k1r[2], k1r[1], k1r[0]};

    // ------------------------------------------------------------ write channel
    reg        aw_held, w_held;
    reg [5:0]  aw_addr;
    reg [31:0] w_data;
    reg [3:0]  w_strb;

    assign s_axi_awready = !aw_held && !s_axi_bvalid;
    assign s_axi_wready  = !w_held  && !s_axi_bvalid;
    assign s_axi_bresp   = 2'b00;

    wire aw_fire = s_axi_awvalid && s_axi_awready;
    wire w_fire  = s_axi_wvalid  && s_axi_wready;

    // Address and data for the write, whether they arrive now or arrived earlier.
    wire        have_aw = aw_held || aw_fire;
    wire        have_w  = w_held  || w_fire;
    wire [5:0]  wa      = aw_held ? aw_addr : s_axi_awaddr;
    wire [31:0] wd      = w_held  ? w_data  : s_axi_wdata;
    wire [3:0]  ws      = w_held  ? w_strb  : s_axi_wstrb;
    wire        do_wr   = have_aw && have_w && !s_axi_bvalid;

    // Merge write data into an existing register under the byte strobes.
    function [31:0] merge(input [31:0] cur, input [31:0] upd, input [3:0] strb);
        integer b;
        begin
            merge = cur;
            for (b = 0; b < 4; b = b + 1)
                if (strb[b]) merge[8*b +: 8] = upd[8*b +: 8];
        end
    endfunction

    always @(posedge clk) begin
        if (!rstn) begin
            aw_held      <= 1'b0;
            w_held       <= 1'b0;
            s_axi_bvalid <= 1'b0;
        end else begin
            if (do_wr) begin
                aw_held      <= 1'b0;
                w_held       <= 1'b0;
                s_axi_bvalid <= 1'b1;
            end else begin
                if (aw_fire) aw_held <= 1'b1;
                if (w_fire)  w_held  <= 1'b1;
                if (s_axi_bvalid && s_axi_bready) s_axi_bvalid <= 1'b0;
            end
        end
        if (aw_fire) aw_addr <= s_axi_awaddr;
        if (w_fire) begin
            w_data <= s_axi_wdata;
            w_strb <= s_axi_wstrb;
        end
    end

    // ------------------------------------------------------------ register writes
    always @(posedge clk) begin
        frame_err_clr <= 1'b0;
        if (!rstn) begin
            ctrl   <= 4'd0;
            shift  <= 12'd0;
            thresh <= 8'd128;
            width  <= 12'd1280;
            height <= 12'd720;
            k0r[0] <= 24'h000000;
            k0r[1] <= 24'h000100;   // centre coefficient = 1
            k0r[2] <= 24'h000000;
            k1r[0] <= 24'h000000;
            k1r[1] <= 24'h000000;
            k1r[2] <= 24'h000000;
        end else if (do_wr) begin
            case (wa[5:2])
                4'h0: ctrl   <= merge({28'd0, ctrl},   wd, ws) & 32'h0000_000F;
                4'h1: frame_err_clr <= ws[0] && wd[0];
                4'h2: shift  <= merge({20'd0, shift},  wd, ws) & 32'h0000_0F0F;
                4'h3: thresh <= merge({24'd0, thresh}, wd, ws);
                4'h4: width  <= merge({20'd0, width},  wd, ws);
                4'h5: height <= merge({20'd0, height}, wd, ws);
                4'h8: k0r[0] <= merge({8'd0, k0r[0]}, wd, ws);
                4'h9: k0r[1] <= merge({8'd0, k0r[1]}, wd, ws);
                4'hA: k0r[2] <= merge({8'd0, k0r[2]}, wd, ws);
                4'hC: k1r[0] <= merge({8'd0, k1r[0]}, wd, ws);
                4'hD: k1r[1] <= merge({8'd0, k1r[1]}, wd, ws);
                4'hE: k1r[2] <= merge({8'd0, k1r[2]}, wd, ws);
                default: ;
            endcase
        end
    end

    // ------------------------------------------------------------ read channel
    assign s_axi_arready = !s_axi_rvalid;
    assign s_axi_rresp   = 2'b00;

    reg [31:0] rd_mux;
    always @(*) begin
        case (s_axi_araddr[5:2])
            4'h0: rd_mux = {28'd0, ctrl};
            4'h1: rd_mux = {31'd0, frame_err};
            4'h2: rd_mux = {20'd0, shift};
            4'h3: rd_mux = {24'd0, thresh};
            4'h4: rd_mux = {20'd0, width};
            4'h5: rd_mux = {20'd0, height};
            4'h8: rd_mux = {8'd0, k0r[0]};
            4'h9: rd_mux = {8'd0, k0r[1]};
            4'hA: rd_mux = {8'd0, k0r[2]};
            4'hC: rd_mux = {8'd0, k1r[0]};
            4'hD: rd_mux = {8'd0, k1r[1]};
            4'hE: rd_mux = {8'd0, k1r[2]};
            4'hF: rd_mux = ID;
            default: rd_mux = 32'd0;
        endcase
    end

    always @(posedge clk) begin
        if (!rstn) begin
            s_axi_rvalid <= 1'b0;
        end else if (s_axi_arvalid && s_axi_arready) begin
            s_axi_rvalid <= 1'b1;
            s_axi_rdata  <= rd_mux;
        end else if (s_axi_rready) begin
            s_axi_rvalid <= 1'b0;
        end
    end

`ifdef FORMAL
    // ---------------------------------------------------------------------
    // Formal properties (SymbiYosys: formal/regs). Ignored by other tools.
    // ---------------------------------------------------------------------
    reg f_past_valid = 1'b0;
    always @(posedge clk) f_past_valid <= 1'b1;
    always @(*) if (!f_past_valid) assume(!rstn);

    wire f_b_fire  = s_axi_bvalid && s_axi_bready;
    wire f_ar_fire = s_axi_arvalid && s_axi_arready;
    wire f_r_fire  = s_axi_rvalid && s_axi_rready;

    // The master obeys AXI4-Lite: requests offered and not taken are held.
    always @(posedge clk) if (f_past_valid && $past(rstn)) begin
        if ($past(s_axi_awvalid && !s_axi_awready))
            assume(s_axi_awvalid && s_axi_awaddr == $past(s_axi_awaddr));
        if ($past(s_axi_wvalid && !s_axi_wready))
            assume(s_axi_wvalid && s_axi_wdata == $past(s_axi_wdata) && s_axi_wstrb == $past(s_axi_wstrb));
        if ($past(s_axi_arvalid && !s_axi_arready))
            assume(s_axi_arvalid && s_axi_araddr == $past(s_axi_araddr));
    end

    // Responses offered and not taken are held.
    always @(posedge clk) if (f_past_valid && $past(rstn) && rstn) begin
        if ($past(s_axi_bvalid && !s_axi_bready)) assert(s_axi_bvalid);
        if ($past(s_axi_rvalid && !s_axi_rready))
            assert(s_axi_rvalid && s_axi_rdata == $past(s_axi_rdata));
    end

    // Transaction counting: every AW and every W produce exactly one B, and
    // every AR exactly one R; at most one of each outstanding.
    reg [1:0] f_aw, f_w, f_b, f_ar, f_r;
    always @(posedge clk) begin
        if (!rstn) begin
            {f_aw, f_w, f_b, f_ar, f_r} <= 10'd0;
        end else begin
            if (aw_fire)   f_aw <= f_aw + 2'd1;
            if (w_fire)    f_w  <= f_w  + 2'd1;
            if (f_b_fire)  f_b  <= f_b  + 2'd1;
            if (f_ar_fire) f_ar <= f_ar + 2'd1;
            if (f_r_fire)  f_r  <= f_r  + 2'd1;
        end
    end

    always @(*) if (rstn && f_past_valid) begin
        assert(f_aw - f_b == {1'b0, aw_held} + {1'b0, s_axi_bvalid});
        assert(f_w  - f_b == {1'b0, w_held}  + {1'b0, s_axi_bvalid});
        assert(f_ar - f_r == {1'b0, s_axi_rvalid});
        assert(!(s_axi_bvalid && (aw_held || w_held)));
        assert(s_axi_bresp == 2'b00 && s_axi_rresp == 2'b00);
    end

    // Functional spot checks, using address/data captured independently from
    // the bus handshakes (not the design's own muxes).
    reg [5:0]  f_awaddr;
    reg [31:0] f_wdata;
    reg [3:0]  f_wstrb;
    always @(posedge clk) begin
        if (aw_fire) f_awaddr <= s_axi_awaddr;
        if (w_fire) begin
            f_wdata <= s_axi_wdata;
            f_wstrb <= s_axi_wstrb;
        end
    end
    // Induction invariants: the checker's copies match the design's held copies.
    always @(*) if (rstn && f_past_valid) begin
        if (aw_held) assert(f_awaddr == aw_addr);
        if (w_held)  assert(f_wdata == w_data && f_wstrb == w_strb);
    end

    wire [5:0]  f_wa = aw_fire ? s_axi_awaddr : f_awaddr;
    wire [31:0] f_wd = w_fire  ? s_axi_wdata  : f_wdata;
    wire [3:0]  f_ws = w_fire  ? s_axi_wstrb  : f_wstrb;

    // A full-strobe write to CTRL lands in the register.
    always @(posedge clk)
        if (f_past_valid && $past(rstn) && rstn && $past(do_wr) && $past(f_wa[5:2]) == 4'h0 && $past(f_ws) == 4'hF)
            assert(ctrl == $past(f_wd[3:0]));
    // A read of WIDTH returns the value the register held when the read was accepted.
    always @(posedge clk)
        if (f_past_valid && $past(rstn) && rstn && $past(f_ar_fire) && $past(s_axi_araddr[5:2]) == 4'h4)
            assert(s_axi_rdata == {20'd0, $past(width)});
    // The clear pulse only follows a write of 1 to STATUS bit 0.
    always @(posedge clk)
        if (f_past_valid && $past(rstn) && rstn && frame_err_clr)
            assert($past(do_wr) && $past(wa[5:2]) == 4'h1 && $past(ws[0]) && $past(wd[0]));

    // Reachability.
    always @(posedge clk) if (rstn) begin
        cover(f_b_fire && f_past_valid && $past(w_held));    // data arrived before address
        cover(f_b_fire && f_past_valid && $past(aw_held));   // address arrived before data
        cover(f_r_fire && s_axi_rdata == ID);                // ID read back
        cover(frame_err_clr);
    end
`endif
endmodule
