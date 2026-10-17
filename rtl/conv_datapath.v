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
//   S7  threshold, enable/bypass mux -> output register
//
// Config is captured into S0 with the start-of-frame beat and the fields
// needed later travel down the pipeline with each beat, so beats of the old
// frame still in flight keep the old settings.
//
// The pipeline stalls as a whole: every stage advances when the output
// register is free. s_ready is therefore combinational from m_ready; the
// top level puts skid buffers on the external ports.

module conv_datapath (
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

    output reg  [7:0]  m_data,
    output reg         m_valid,
    output reg         m_user,
    output reg         m_last,
    input  wire        m_ready
);
    localparam MODE_LANE0 = 2'd0, MODE_ABS0 = 2'd1, MODE_MAG = 2'd2;

    wire adv = !m_valid || m_ready;
    assign s_ready = adv;

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

    wire s_fire = s_valid && s_ready;

    always @(posedge clk) begin
        if (!rstn) v0 <= 1'b0;
        else if (adv) v0 <= s_valid;
    end

    always @(posedge clk) begin
        if (s_fire) begin
            win0  <= s_data;
            user0 <= s_user;
            last0 <= s_last;
            if (s_user) begin
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
    end

    wire [CTL_W-1:0] ctl0 = {user0, last0, en_a, win0[39:32], sh1_a, sh0_a, mode_a, th_en_a, th_a};

    // ------------------------------------------------------------ S1: products
    // 18 registered multipliers (DSP48 slices on Xilinx parts).
    reg                v1;
    reg [CTL_W-1:0]    ctl1;
    wire signed [16:0] p0 [0:8];
    wire signed [16:0] p1 [0:8];

    genvar g;
    generate
        for (g = 0; g < 9; g = g + 1) begin : g_mul
            mul_u8s8 u_m0 (.clk(clk), .en(adv), .a(win0[8*g +: 8]), .b(k0_a[8*g +: 8]), .p(p0[g]));
            mul_u8s8 u_m1 (.clk(clk), .en(adv), .a(win0[8*g +: 8]), .b(k1_a[8*g +: 8]), .p(p1[g]));
        end
    endgenerate

    always @(posedge clk)
        if (adv) ctl1 <= ctl0;

    // ------------------------------------------------------------ S2: row sums
    reg               v2;
    reg [CTL_W-1:0]   ctl2;
    reg signed [18:0] r0 [0:2];
    reg signed [18:0] r1 [0:2];

    integer j;
    always @(posedge clk) begin
        if (adv) begin
            for (j = 0; j < 3; j = j + 1) begin
                r0[j] <= p0[3*j] + p0[3*j+1] + p0[3*j+2];
                r1[j] <= p1[3*j] + p1[3*j+1] + p1[3*j+2];
            end
            ctl2 <= ctl1;
        end
    end

    // ------------------------------------------------------------ S3: lane sums + rounding
    reg               v3;
    reg [CTL_W-1:0]   ctl3;
    reg signed [19:0] acc0, acc1;

    wire [3:0] sh0_2 = ctl2[14:11];
    wire [3:0] sh1_2 = ctl2[18:15];
    wire signed [19:0] rnd0 = (sh0_2 == 0) ? 20'sd0 : (20'sd1 <<< (sh0_2 - 4'd1));
    wire signed [19:0] rnd1 = (sh1_2 == 0) ? 20'sd0 : (20'sd1 <<< (sh1_2 - 4'd1));

    always @(posedge clk) begin
        if (adv) begin
            acc0 <= r0[0] + r0[1] + r0[2] + rnd0;
            acc1 <= r1[0] + r1[1] + r1[2] + rnd1;
            ctl3 <= ctl2;
        end
    end

    // ------------------------------------------------------------ S4: shift
    reg               v4;
    reg [CTL_W-1:0]   ctl4;
    reg signed [19:0] sv0, sv1;

    wire [3:0] sh0_3 = ctl3[14:11];
    wire [3:0] sh1_3 = ctl3[18:15];

    always @(posedge clk) begin
        if (adv) begin
            sv0  <= acc0 >>> sh0_3;
            sv1  <= acc1 >>> sh1_3;
            ctl4 <= ctl3;
        end
    end

    // ------------------------------------------------------------ S5: abs + pre-saturation
    // The final result saturates at 255, so each magnitude only needs to be
    // known up to 256: min(|x|, 256) gives the same saturated sum and keeps
    // the S6 adder at 10 bits instead of 21.
    reg              v5;
    reg [CTL_W-1:0]  ctl5;
    reg [7:0]        lane0_sat;          // lane0 clamped to [0, 255]
    reg [8:0]        m0, m1;             // min(|lane|, 256)

    wire [19:0] abs0 = sv0[19] ? -sv0 : sv0;
    wire [19:0] abs1 = sv1[19] ? -sv1 : sv1;

    always @(posedge clk) begin
        if (adv) begin
            lane0_sat <= sv0[19] ? 8'd0 : (sv0 > 20'sd255 ? 8'd255 : sv0[7:0]);
            m0        <= (abs0 > 20'd256) ? 9'd256 : abs0[8:0];
            m1        <= (abs1 > 20'd256) ? 9'd256 : abs1[8:0];
            ctl5      <= ctl4;
        end
    end

    // ------------------------------------------------------------ S6: combine / saturate
    reg              v6;
    reg [CTL_W-1:0]  ctl6;
    reg [7:0]        sat6;

    wire [1:0] mode5 = ctl5[10:9];
    wire [9:0] mag   = {1'b0, m0} + {1'b0, m1};

    always @(posedge clk) begin
        if (adv) begin
            case (mode5)
                MODE_LANE0: sat6 <= lane0_sat;
                MODE_ABS0:  sat6 <= m0[8] ? 8'd255 : m0[7:0];
                default:    sat6 <= (mag > 10'd255) ? 8'd255 : mag[7:0];
            endcase
            ctl6 <= ctl5;
        end
    end

    // ------------------------------------------------------------ S7: threshold / bypass
    wire        user6  = ctl6[CTL_W-1];
    wire        last6  = ctl6[CTL_W-2];
    wire        en6    = ctl6[CTL_W-3];
    wire [7:0]  ctr6   = ctl6[CTL_W-4 -: 8];
    wire        th_en6 = ctl6[8];
    wire [7:0]  th6    = ctl6[7:0];

    wire [7:0] filtered = th_en6 ? ((sat6 >= th6) ? 8'd255 : 8'd0) : sat6;

    always @(posedge clk) begin
        if (adv && v6) begin
            m_data <= en6 ? filtered : ctr6;
            m_user <= user6;
            m_last <= last6;
        end
    end

    // ------------------------------------------------------------ valid chain
    always @(posedge clk) begin
        if (!rstn) begin
            {v1, v2, v3, v4, v5, v6, m_valid} <= 7'b0;
        end else if (adv) begin
            v1      <= v0;
            v2      <= v1;
            v3      <= v2;
            v4      <= v3;
            v5      <= v4;
            v6      <= v5;
            m_valid <= v6;
        end
    end
endmodule
