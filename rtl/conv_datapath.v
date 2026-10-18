`timescale 1ns / 1ps
// conv_datapath: two 3x3 MAC lanes plus combine / saturate / threshold.
//
// Input : a stream of 3x3 windows from conv_window (p_k = s_data[8*k +: 8]).
// Output: one u8 pixel per window, bit-exact with model/conv_model.py:
//         apply_windows().
//
// Pipeline (8 register stages, 1 window per clock):
//   S0  register window; latch config when this is a start-of-frame beat
//   S1  18 products   u8 * s8        -> s17   (mul_u8s8, DSP48 on Xilinx)
//   S2  row sums      3 x s17        -> s19
//   S3  lane sums     3 x s19 + rnd  -> s20   (rnd = 2^(shift-1), or 0)
//   S4  arithmetic shift
//   S5  absolute values, pre-saturated to 9 bits
//   S6  combine (LANE0 / ABS0 / MAG), saturate to [0,255]
//   S7  threshold, enable/bypass mux
//   -> output FIFO (FIFO_DEPTH entries)
//
// Flow control: free-running pipeline + credits.
//   The pipeline registers never stall: they load every cycle and a valid
//   bit travels with each beat. Results land in a small output FIFO. A
//   credit counter tracks the FIFO slots not yet claimed by a beat in the
//   pipeline or in the FIFO; a window is accepted only while a credit is
//   available, so the FIFO can never overflow.
//   An earlier version stalled every stage with one shared enable. In the
//   sky130 ASIC flow that enable fanned out to ~650 flops (each needing an
//   enable mux) and became the critical path at the slow corner; this
//   structure has no such net. s_ready depends only on the credit register.
//   Credit loop: accept -> S7 (8 cycles) -> FIFO -> pop -> credit back, about
//   10 cycles, so FIFO_DEPTH = 16 sustains one window per clock.
//
// Config is captured into S0 with the start-of-frame beat and the fields
// needed later travel down the pipeline with each beat, so beats of the old
// frame still in flight keep the old settings.

module conv_datapath #(
    parameter integer FIFO_DEPTH = 16,
    parameter integer FAW        = 4        // clog2(FIFO_DEPTH)
) (
    input  wire        clk,
    input  wire        rstn,

    input  wire        cfg_enable,
    input  wire [71:0] cfg_k0,       // coefficient k (s8) at [8*k +: 8]
    input  wire [71:0] cfg_k1,
    input  wire [3:0]  cfg_shift0,
    input  wire [3:0]  cfg_shift1,
    input  wire [1:0]  cfg_mode,     // 0 LANE0, 1 ABS0, 2 MAG
    input  wire        cfg_thresh_en,
    input  wire [7:0]  cfg_thresh,

    input  wire [71:0] s_data,
    input  wire        s_valid,
    input  wire        s_user,
    input  wire        s_last,
    output wire        s_ready,

    output wire [7:0]  m_data,
    output wire        m_valid,
    output wire        m_user,
    output wire        m_last,
    input  wire        m_ready
);
    localparam MODE_LANE0 = 2'd0, MODE_ABS0 = 2'd1, MODE_MAG = 2'd2;

    // ------------------------------------------------------------ credits
    reg  [FAW:0] credits;                    // FIFO slots not yet claimed
    wire         pop    = m_valid && m_ready;
    assign       s_ready = (credits != 0);
    wire         s_fire = s_valid && s_ready;

    always @(posedge clk) begin
        if (!rstn)
            credits <= FIFO_DEPTH[FAW:0];
        else
            credits <= credits - {{FAW{1'b0}}, s_fire} + {{FAW{1'b0}}, pop};
    end

    // Fields carried down the pipeline with each beat:
    // {user, last, enable, centre pixel[7:0], shift1, shift0, mode, thresh_en, thresh[7:0]}
    localparam CTL_W = 1 + 1 + 1 + 8 + 4 + 4 + 2 + 1 + 8;

    // ------------------------------------------------------------ S0
    reg         v0;
    reg  [71:0] win0;
    reg         user0, last0;
    reg         en_a, th_en_a;           // active (latched) config
    reg  [71:0] k0_a, k1_a;
    reg  [3:0]  sh0_a, sh1_a;
    reg  [1:0]  mode_a;
    reg  [7:0]  th_a;

    always @(posedge clk) begin
        win0  <= s_data;                     // data loads every cycle;
        user0 <= s_user;                     // the valid bit says if it counts
        last0 <= s_last;
        if (s_fire && s_user) begin
            en_a    <= cfg_enable;
            k0_a    <= cfg_k0;
            k1_a    <= cfg_k1;
            sh0_a   <= cfg_shift0;
            sh1_a   <= cfg_shift1;
            mode_a  <= cfg_mode;
            th_en_a <= cfg_thresh_en;
            th_a    <= cfg_thresh;
        end
    end

    wire [CTL_W-1:0] ctl0 = {user0, last0, en_a, win0[39:32], sh1_a, sh0_a, mode_a, th_en_a, th_a};

    // ------------------------------------------------------------ S1: products
    // 18 registered multipliers (DSP48 slices on Xilinx parts).
    reg [CTL_W-1:0]    ctl1;
    wire signed [16:0] p0 [0:8];
    wire signed [16:0] p1 [0:8];

    genvar g;
    generate
        for (g = 0; g < 9; g = g + 1) begin : g_mul
            mul_u8s8 u_m0 (.clk(clk), .a(win0[8*g +: 8]), .b(k0_a[8*g +: 8]), .p(p0[g]));
            mul_u8s8 u_m1 (.clk(clk), .a(win0[8*g +: 8]), .b(k1_a[8*g +: 8]), .p(p1[g]));
        end
    endgenerate

    always @(posedge clk) ctl1 <= ctl0;

    // ------------------------------------------------------------ S2: row sums
    reg [CTL_W-1:0]   ctl2;
    reg signed [18:0] r0 [0:2];
    reg signed [18:0] r1 [0:2];

    integer j;
    always @(posedge clk) begin
        for (j = 0; j < 3; j = j + 1) begin
            r0[j] <= p0[3*j] + p0[3*j+1] + p0[3*j+2];
            r1[j] <= p1[3*j] + p1[3*j+1] + p1[3*j+2];
        end
        ctl2 <= ctl1;
    end

    // ------------------------------------------------------------ S3: lane sums + rounding
    reg [CTL_W-1:0]   ctl3;
    reg signed [19:0] acc0, acc1;

    wire [3:0] sh0_2 = ctl2[14:11];
    wire [3:0] sh1_2 = ctl2[18:15];
    wire signed [19:0] rnd0 = (sh0_2 == 0) ? 20'sd0 : (20'sd1 <<< (sh0_2 - 4'd1));
    wire signed [19:0] rnd1 = (sh1_2 == 0) ? 20'sd0 : (20'sd1 <<< (sh1_2 - 4'd1));

    always @(posedge clk) begin
        acc0 <= r0[0] + r0[1] + r0[2] + rnd0;
        acc1 <= r1[0] + r1[1] + r1[2] + rnd1;
        ctl3 <= ctl2;
    end

    // ------------------------------------------------------------ S4: shift
    reg [CTL_W-1:0]   ctl4;
    reg signed [19:0] sv0, sv1;

    wire [3:0] sh0_3 = ctl3[14:11];
    wire [3:0] sh1_3 = ctl3[18:15];

    always @(posedge clk) begin
        sv0  <= acc0 >>> sh0_3;
        sv1  <= acc1 >>> sh1_3;
        ctl4 <= ctl3;
    end

    // ------------------------------------------------------------ S5: abs + pre-saturation
    // The final result saturates at 255, so each magnitude only needs to be
    // known up to 256: min(|x|, 256) gives the same saturated sum and keeps
    // the S6 adder at 10 bits instead of 21.
    reg [CTL_W-1:0]  ctl5;
    reg [7:0]        lane0_sat;          // lane0 clamped to [0, 255]
    reg [8:0]        m0, m1;             // min(|lane|, 256)

    wire [19:0] abs0 = sv0[19] ? -sv0 : sv0;
    wire [19:0] abs1 = sv1[19] ? -sv1 : sv1;

    always @(posedge clk) begin
        lane0_sat <= sv0[19] ? 8'd0 : (sv0 > 20'sd255 ? 8'd255 : sv0[7:0]);
        m0        <= (abs0 > 20'd256) ? 9'd256 : abs0[8:0];
        m1        <= (abs1 > 20'd256) ? 9'd256 : abs1[8:0];
        ctl5      <= ctl4;
    end

    // ------------------------------------------------------------ S6: combine / saturate
    reg [CTL_W-1:0]  ctl6;
    reg [7:0]        sat6;

    wire [1:0] mode5 = ctl5[10:9];
    wire [9:0] mag   = {1'b0, m0} + {1'b0, m1};

    always @(posedge clk) begin
        case (mode5)
            MODE_LANE0: sat6 <= lane0_sat;
            MODE_ABS0:  sat6 <= m0[8] ? 8'd255 : m0[7:0];
            default:    sat6 <= (mag > 10'd255) ? 8'd255 : mag[7:0];
        endcase
        ctl6 <= ctl5;
    end

    // ------------------------------------------------------------ S7: threshold / bypass
    wire        user6  = ctl6[CTL_W-1];
    wire        last6  = ctl6[CTL_W-2];
    wire        en6    = ctl6[CTL_W-3];
    wire [7:0]  ctr6   = ctl6[CTL_W-4 -: 8];
    wire        th_en6 = ctl6[8];
    wire [7:0]  th6    = ctl6[7:0];

    wire [7:0] filtered = th_en6 ? ((sat6 >= th6) ? 8'd255 : 8'd0) : sat6;

    reg [7:0] pix7;
    reg       user7, last7;
    always @(posedge clk) begin
        pix7  <= en6 ? filtered : ctr6;
        user7 <= user6;
        last7 <= last6;
    end

    // ------------------------------------------------------------ valid chain
    reg v1, v2, v3, v4, v5, v6, v7;
    always @(posedge clk) begin
        if (!rstn)
            {v0, v1, v2, v3, v4, v5, v6, v7} <= 8'b0;
        else
            {v0, v1, v2, v3, v4, v5, v6, v7} <= {s_fire, v0, v1, v2, v3, v4, v5, v6};
    end

    // ------------------------------------------------------------ output FIFO
    reg [9:0]     fifo [0:FIFO_DEPTH-1];     // {user, last, pixel}
    reg [FAW-1:0] wptr, rptr;
    reg [FAW:0]   count;

    always @(posedge clk) begin
        if (!rstn) begin
            wptr  <= {FAW{1'b0}};
            rptr  <= {FAW{1'b0}};
            count <= {(FAW+1){1'b0}};
        end else begin
            if (v7)  wptr <= wptr + 1'b1;
            if (pop) rptr <= rptr + 1'b1;
            count <= count + {{FAW{1'b0}}, v7} - {{FAW{1'b0}}, pop};
        end
        if (v7) fifo[wptr] <= {user7, last7, pix7};
    end

    assign m_valid = (count != 0);
    assign {m_user, m_last, m_data} = fifo[rptr];
endmodule
