/*
 * NeuroBit64-Pancreas : 1000 pancreatic islet cells with adrenergic neurons on one time-shared
 * circuit. Variant of NeuroBit64-S for the pancreas.
 * Copyright (c) 2026 Asif Mehmood.  SPDX-License-Identifier: Apache-2.0
 *
 * Cell model: Hybrid Excitable Cell model for pancreatic alpha, beta and delta cells (A. Mehmood,
 * PhD thesis, UET Taxila 2025, section "Pancreatic Cells"), forward Euler, 1 ms per tick:
 *   v' = v + k f (v - Vr)(v - Vt) / C - u / C + (Va + Vb) / C + I       u' = u + a (b (v - Vr) - u)
 *   spike when v >= Vt + Va + Vb :  v = c, u = u + d
 *   Va = Vglu * glucagon level,  Vb = Vins * insulin level  (levels 0..1 made by the cells themselves:
 *   every alpha-cell spike adds glucagon, every beta- or delta-cell spike adds insulin)
 * Cells: groups 0-18 beta (594 cells), groups 19-28 alpha (313), groups 29-31 delta (93).
 * Glucose (mg/dL) drives the alpha cells below 90 and the beta and delta cells above 100; below
 * 100 it holds the beta and delta cells down. Beta cells are coupled to their neighbours.
 * Every cell has one adrenergic neuron (NeuroBit64 leaky integrate-and-fire rule) driven by the
 * sympathetic signal: alpha-2 type on beta and delta cells (a spike pushes the cell down),
 * beta-2 type on alpha cells (a spike pushes it up). The parasympathetic signal drives beta cells.
 *
 * Timing: one cell per slot of 8 clocks, N slots per tick; N = 1000 at 8 MHz is real time.
 * State:  35 bits per cell {ne[6:0], u[15:0], v[11:0]}   v 1/16 mV, u 1/32 mV
 *
 * cond[2:0]  0 healthy, glucose sweep 40..295 mg/dL (16.4 s)   1 healthy, 50   2 healthy, 95
 *            3 healthy, 240   4 13/16 of the beta cells lost, sweep   5 weak beta-cell response, sweep
 *            6 no alpha-cell response, sweep   7 high sympathetic tone, sweep
 * uart_rx    47 lo hi  = use this glucose value (mg/dL) instead of the built-in one; FFFF = built-in
 * Report (16 bytes, every 16 ticks): seq, 0x20|link<<3|cond, flags, mean v (mV), beta spikes,
 *   alpha spikes, delta spikes, glucose in (mg/dL), glucose read from the cells (mg/dL), insulin
 *   level, brain drive.  Flags: 0 low glucose 1 high glucose 2 beta cells do not answer
 *   3 alpha cells do not answer 4 strong sympathetic drive 7 islet response abnormal.
 * Bit-exact software model: design/model/nb64_pancreas_model.js
 */

`default_nettype none

module nb64_pancreas #(
    parameter N = 1000
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [2:0] cond,
    input  wire       link_en,
    input  wire       adv_en,
    input  wire       nb_sdo,
    input  wire       nb_sync,
    input  wire       uart_rx,
    output wire       nb_sdi,
    output reg        sdo,        // raster: one spike bit per cell per tick
    output reg        sck,
    output reg        sync,
    output wire       uart_tx,
    output wire       bb_data,
    output wire       bb_en,
    output wire       pll_en,
    output wire [1:0] rf_ch
);
    localparam SW = 35;
    localparam [9:0] NM1 = N - 1;

    // ---------------------------------------------------------------- condition table
    wire       c_loss    = (cond == 3'd4);
    wire       c_weak    = (cond == 3'd5);
    wire       c_noalpha = (cond == 3'd6);
    wire [4:0] c_symp    = (cond == 3'd7) ? 5'd12 : 5'd0;
    wire [8:0] c_gl      = (cond == 3'd1) ? 9'd50 : (cond == 3'd2) ? 9'd95 : (cond == 3'd3) ? 9'd240 : 9'd0;

    // ---------------------------------------------------------------- glucose command on uart_rx
    reg  [2:0]  rxs;
    reg  [6:0]  rxdiv;
    reg  [3:0]  rxbit;
    reg         rxbusy, rxstb;
    reg  [7:0]  rxsh, clo;
    reg  [1:0]  cst;
    reg  [13:0] cidle;                          // 2 ms without a byte puts the parser back to idle
    reg         gx_v;                           // an external glucose value has been written
    reg  [8:0]  gx;
    wire [15:0] cval = {rxsh, clo};
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rxs <= 3'b111; rxdiv <= 7'd0; rxbit <= 4'd0; rxbusy <= 1'b0; rxsh <= 8'd0; rxstb <= 1'b0;
            cst <= 2'd0; clo <= 8'd0; cidle <= 14'd0; gx_v <= 1'b0; gx <= 9'd0;
        end else begin
            rxs   <= {rxs[1:0], uart_rx};
            rxstb <= 1'b0;
            if (!rxbusy) begin
                if (!rxs[2]) begin rxbusy <= 1'b1; rxdiv <= 7'd34; rxbit <= 4'd0; end
            end else if (rxdiv != 7'd0) begin
                rxdiv <= rxdiv - 7'd1;
            end else begin
                rxdiv <= 7'd68;
                rxbit <= rxbit + 4'd1;
                if (rxbit == 4'd0) begin
                    if (rxs[2]) rxbusy <= 1'b0;
                end else if (rxbit <= 4'd8) begin
                    rxsh <= {rxs[2], rxsh[7:1]};
                end else begin
                    rxbusy <= 1'b0;
                    rxstb  <= rxs[2];
                end
            end
            if (rxstb) begin
                cidle <= 14'd0;
                case (cst)
                    2'd0: cst <= (rxsh == 8'h47) ? 2'd1 : 2'd0;
                    2'd1: begin clo <= rxsh; cst <= 2'd2; end
                    default: begin
                        gx_v <= (cval != 16'hFFFF);
                        gx   <= (cval > 16'd511) ? 9'd511 : cval[8:0];
                        cst  <= 2'd0;
                    end
                endcase
            end else if (cst != 2'd0) begin
                cidle <= cidle + 14'd1;
                if (&cidle) cst <= 2'd0;
            end
        end
    end

    // ---------------------------------------------------------------- sequencer
    reg  [2:0]      b;
    reg  [9:0]      ci;
    reg  [15:0]     t;
    reg  [31:0]     x32;
    reg  [N*SW-1:0] vm;
    reg  [10:0]     gacc;
    reg  [4:0]      g;
    reg  [5:0]      pm1;
    reg  [191:0]    cn;
    reg  [5:0]      gup;
    reg             valid;
    reg             gl_v;                       // glucose source of this tick, taken at the tick boundary
    reg  [8:0]      gl_x;
    wire            last  = (b == 3'd7);
    wire            tlast = last && (ci == NM1);

    wire [31:0] x1 = x32 ^ (x32 << 13);
    wire [31:0] x2 = x1 ^ (x1 >> 17);
    wire [31:0] x3 = x2 ^ (x2 << 5);

    // ---------------------------------------------------------------- brain link
    wire [7:0] aff_rd;
    wire [9:0] sym, par, sym_now, par_now;
    wire       gend;
    wire [7:0] aff_wd;
    nb64_link link (
        .clk(clk), .rst_n(rst_n), .nb_sdo(nb_sdo), .nb_sync(nb_sync), .nb_sdi(nb_sdi),
        .aff_we(last && gend), .aff_wa(g), .aff_wd(aff_wd), .aff_ra(g), .aff_rd(aff_rd),
        .tick_end(tlast), .sym_now(sym_now), .par_now(par_now), .sym(sym), .par(par)
    );

    // ---------------------------------------------------------------- values that hold for one tick
    reg  [11:0] glu, i1, i2;                    // hormone fields
    wire [13:0] ph   = t[13:0];
    wire [7:0]  trw  = ph[13] ? ~ph[12:5] : ph[12:5];                    // slow triangle, 16.4 s
    wire [8:0]  G    = gl_v ? gl_x : (c_gl != 9'd0) ? c_gl : (9'd40 + {1'b0, trw});
    wire [8:0]  glo  = (G < 9'd90) ? (9'd90 - G) : 9'd0;
    wire [10:0] glo3 = {2'b00, glo} + {1'b0, glo, 1'b0};
    wire [8:0]  d_alpha = c_noalpha ? 9'd0 : glo3[10:2];
    wire signed [11:0] gdf  = $signed({3'b000, G}) - (c_weak ? 12'sd160 : 12'sd100);
    wire signed [11:0] gdf3 = gdf + (gdf <<< 1);
    wire signed [11:0] gdfs = c_weak ? (gdf3 >>> 5) : (gdf3 >>> 4);
    wire signed [8:0]  d_beta = (gdfs < -12'sd16) ? -9'sd16 : (gdfs > 12'sd255) ? 9'sd255 : gdfs[8:0];
    wire [6:0]  sds  = {2'b00, c_symp} + (link_en ? {1'b0, sym[9:4]} : 7'd0);
    wire [4:0]  sd   = (sds > 7'd31) ? 5'd31 : sds[4:0];
    wire [4:0]  vag  = !link_en ? 5'd0 : (par[9:4] > 6'd31) ? 5'd31 : par[8:4];
    wire [7:0]  fg   = glu[11:4];
    wire [7:0]  fi   = i2[11:4];
    wire [18:0] eb_f = 19'd560 * fg + 19'd480 * fi;
    wire [18:0] ed_f = 19'd560 * fg + 19'd640 * fi;
    wire [10:0] e_beta  = eb_f[18:8];
    wire [10:0] e_delta = ed_f[18:8];

    // ---------------------------------------------------------------- one cell
    wire signed [11:0] v  = vm[11:0];
    wire signed [15:0] u  = vm[27:12];
    wire        [6:0]  ne = vm[34:28];

    wire [3:0] r     = {ci[0], ci[1], ci[2], ci[3]} ^ ci[7:4] ^ {2'b00, ci[9:8]};
    wire       t_b   = (g < 5'd19);
    wire       t_a   = !t_b && (g < 5'd29);
    wire       dead  = c_loss && t_b && (r < 4'd13);
    wire signed [4:0] nz = $signed({1'b0, x32[31:28]}) - $signed({1'b0, x32[27:24]});

    wire signed [6:0]  kq = t_b ? 7'sd25 : t_a ? 7'sd16 : 7'sd10;         // k f / C
    wire signed [8:0]  ka = t_a ? 9'sd123 : 9'sd82;                       // a
    wire signed [14:0] kd = t_b ? 15'sd1600 : t_a ? 15'sd3200 : 15'sd1920; // d
    wire        [10:0] e  = t_b ? e_beta : t_a ? 11'd0 : e_delta;         // Va + Vb

    wire signed [12:0] x   = v + 13'sd960;
    wire signed [12:0] y   = x - 13'sd320;
    wire signed [25:0] p   = x * y;
    wire signed [33:0] qf  = p * kq + 34'sd131072;
    wire signed [15:0] q   = qf >>> 18;
    wire signed [23:0] tuf = u * 24'sd41 + 24'sd4096;
    wire signed [10:0] tu  = tuf >>> 13;                                  // u / C
    wire        [16:0] def = e * 17'd41 + 17'd2048;
    wire        [4:0]  de  = def[16:12];                                  // (Va + Vb) / C
    wire signed [12:0] thr = -13'sd640 + $signed({2'b00, e});
    wire               fire = ($signed({v[11], v}) >= thr);

    wire [7:0] nes = {1'b0, ne} - {3'b000, ne[6:2]} + {3'b000, sd};       // adrenergic neuron
    wire       se  = (nes >= 8'd32);
    wire signed [7:0] kick = !se ? 8'sd0 : t_a ? 8'sd48 : -8'sd48;

    wire [6:0] cps = {1'b0, pm1} + {1'b0, cn[5:0]};
    wire [5:0] cpc = cps[6] ? 6'd63 : cps[5:0];
    wire [7:0] cpl = (t_b && !dead) ? {cpc, 2'b00} : 8'd0;
    wire signed [9:0] drv = dead ? 10'sd0 : t_a ? $signed({1'b0, d_alpha})
                          : (d_beta + (t_b ? $signed({5'b00000, vag}) : 10'sd0));

    wire signed [17:0] vsum = v + q - tu + $signed({1'b0, de}) + drv + nz + $signed({1'b0, cpl}) + kick;
    wire signed [11:0] vn   = (vsum > 18'sd2047) ? 12'sd2047 : (vsum < -18'sd2048) ? -12'sd2048 : vsum[11:0];
    wire signed [16:0] bx   = t_b ? -(17'sd10 * x) : t_a ? -(17'sd4 * x) : -(17'sd2 * x);   // b (v - Vr)
    wire signed [17:0] tt   = bx - u;
    wire signed [27:0] duf  = tt * ka + 28'sd2048;
    wire signed [19:0] us   = u + (duf >>> 12);
    wire signed [15:0] un   = (us > 20'sd32767) ? 16'sd32767 : (us < -20'sd32768) ? -16'sd32768 : us[15:0];
    wire signed [17:0] ud   = u + kd;
    wire signed [15:0] uf   = (ud > 18'sd32767) ? 16'sd32767 : ud[15:0];

    wire [11:0] v_nx  = fire ? -12'sd800 : vn;
    wire [15:0] u_nx  = fire ? uf : un;
    wire [6:0]  ne_nx = se ? 7'd0 : nes[6:0];

    // ---------------------------------------------------------------- groups
    wire [10:0] gsum  = gacc + 11'd32;
    assign      gend  = (gsum >= N);
    wire [6:0]  gupn  = {1'b0, gup} + {6'd0, fire};
    wire [5:0]  gupc  = gupn[6] ? 6'd63 : gupn[5:0];
    wire [9:0]  affs  = {2'b00, aff_rd} - {4'b0000, aff_rd[7:2]} + {1'b0, gupn[5:0], 3'b000};
    assign      aff_wd = (|affs[9:8]) ? 8'd255 : affs[7:0];

    // ---------------------------------------------------------------- per-tick totals
    reg  [9:0]  nsb, nsa, nsd;
    reg  signed [22:0] vacc;
    wire [9:0]  nsb_t = nsb + {9'd0, fire && t_b};
    wire [9:0]  nsa_t = nsa + {9'd0, fire && t_a};
    wire [9:0]  nsd_t = nsd + {9'd0, fire && !t_b && !t_a};
    wire signed [22:0] vacc_t = vacc + $signed(v_nx);

    // ---------------------------------------------------------------- hormone fields, rates, read-out
    reg  [11:0] rb, ra;
    reg  [7:0]  seq;
    reg  [15:0] wb, wa, wd;

    wire [12:0] glur  = {1'b0, glu} + 13'd255;
    wire [12:0] i1r   = {1'b0, i1} + 13'd31;
    wire [12:0] i2r   = {1'b0, i2} + 13'd31;
    wire [4:0]  gludec = glur[12:8];
    wire [7:0]  i1dec = i1r[12:5];
    wire [7:0]  i2dec = i2r[12:5];
    wire [12:0] gg3   = {3'b000, nsa_t} + {2'b00, nsa_t, 1'b0};                       // 3 * alpha spikes
    wire [13:0] glu_s = {2'b00, glu} - {9'd0, gludec} + {3'b000, gg3[12:2]};
    wire [11:0] glu_n = (|glu_s[13:12]) ? 12'd4095 : glu_s[11:0];
    wire [10:0] bd    = {1'b0, nsb_t} + {1'b0, nsd_t};
    wire [13:0] i1_s  = {2'b00, i1} - {6'd0, i1dec} + {2'b00, bd, 1'b0};
    wire [11:0] i1_n  = (|i1_s[13:12]) ? 12'd4095 : i1_s[11:0];
    wire [13:0] i2_s  = {2'b00, i2} - {6'd0, i2dec} + {7'd0, i1[11:5]};
    wire [11:0] i2_n  = (|i2_s[13:12]) ? 12'd4095 : i2_s[11:0];
    wire [13:0] rb_s  = {2'b00, rb} - {8'd0, rb[11:6]} + {4'd0, nsb_t};
    wire [11:0] rb_n  = (|rb_s[13:12]) ? 12'd4095 : rb_s[11:0];
    wire [13:0] ra_s  = {2'b00, ra} - {8'd0, ra[11:6]} + {4'd0, nsa_t};
    wire [11:0] ra_n  = (|ra_s[13:12]) ? 12'd4095 : ra_s[11:0];

    wire signed [18:0] gbm = ($signed({1'b0, rb_n}) - 19'sd1132) * 19'sd26;
    wire signed [18:0] gbe = 19'sd90 + (gbm >>> 8);
    wire        [16:0] gam = ra_n * 17'd25;
    wire signed [18:0] gae = 19'sd93 - $signed({11'd0, gam[16:9]});
    wire signed [18:0] gsel = (rb_n >= 12'd768) ? gbe : gae;
    wire [8:0]  gest_n = (gsel < 19'sd0) ? 9'd0 : (gsel > 19'sd511) ? 9'd511 : gsel[8:0];

    wire [6:0]  sda = {2'b00, c_symp} + (link_en ? {1'b0, sym_now[9:4]} : 7'd0);
    wire [7:0]  flags_n;
    assign flags_n[0] = (gest_n < 9'd70);
    assign flags_n[1] = (gest_n > 9'd180);
    assign flags_n[2] = (G > 9'd140) && (gest_n < 9'd110);
    assign flags_n[3] = (G < 9'd70) && (gest_n > 9'd80);
    assign flags_n[4] = (sda >= 7'd8);
    assign flags_n[6:5] = 2'b00;
    assign flags_n[7] = |flags_n[4:2];

    // ---------------------------------------------------------------- report
    wire [16:0] wb_s = {1'b0, wb} + {7'd0, nsb_t};
    wire [16:0] wa_s = {1'b0, wa} + {7'd0, nsa_t};
    wire [16:0] wd_s = {1'b0, wd} + {7'd0, nsd_t};
    wire [15:0] wb_n = wb_s[16] ? 16'hFFFF : wb_s[15:0];
    wire [15:0] wa_n = wa_s[16] ? 16'hFFFF : wa_s[15:0];
    wire [15:0] wd_n = wd_s[16] ? 16'hFFFF : wd_s[15:0];
    wire signed [8:0]  mvs  = vacc_t >>> 14;
    wire signed [10:0] dnow = $signed({1'b0, sym_now}) - $signed({1'b0, par_now});
    wire [7:0]  brb = !link_en ? 8'd0 : (dnow > 11'sd127) ? 8'd127 : (dnow < -11'sd128) ? 8'h80 : dnow[7:0];
    wire        wend = tlast && (t[3:0] == 4'd15);
    wire [127:0] payload = {brb, i2_n[11:4], 7'd0, gest_n, 7'd0, G, wd_n, wa_n, wb_n,
                            mvs[7:0], flags_n, 4'h2, link_en, cond, seq};
    wire        tbusy;
    nb64_telemetry tele (
        .clk(clk), .rst_n(rst_n), .send(wend), .adv(adv_en && (seq[2:0] == 3'd7)), .organ(4'd2),
        .payload(payload), .uart_tx(uart_tx), .bb_data(bb_data), .bb_en(bb_en), .pll_en(pll_en),
        .rf_ch(rf_ch), .busy(tbusy)
    );

    // ---------------------------------------------------------------- registers
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            b <= 3'd0; ci <= 10'd0; t <= 16'd0; x32 <= 32'h1234_5678;
            vm <= {N{23'd0, 12'hC40}};                                    // every cell at rest, v = Vr
            gacc <= 11'd0; g <= 5'd0; pm1 <= 6'd0; cn <= 192'd0; gup <= 6'd0;
            valid <= 1'b0; sdo <= 1'b0; sck <= 1'b0; sync <= 1'b0; gl_v <= 1'b0; gl_x <= 9'd0;
            nsb <= 10'd0; nsa <= 10'd0; nsd <= 10'd0; vacc <= 23'sd0;
            glu <= 12'd0; i1 <= 12'd0; i2 <= 12'd0; rb <= 12'd0; ra <= 12'd0;
            seq <= 8'd0; wb <= 16'd0; wa <= 16'd0; wd <= 16'd0;
        end else begin
            b   <= b + 3'd1;
            sck <= valid && (b >= 3'd3) && (b <= 3'd6);
            if (last) begin
                sdo   <= fire;
                sync  <= (ci == 10'd0);
                valid <= 1'b1;
                x32   <= x3;
                vm    <= {ne_nx, u_nx, v_nx, vm[N*SW-1:SW]};
                ci    <= (ci == NM1) ? 10'd0 : ci + 10'd1;
                if (gend) begin
                    gacc <= gsum - N;
                    g    <= g + 5'd1;
                    pm1  <= t_b ? cn[5:0] : 6'd0;
                    cn   <= {gupc, cn[191:6]};
                    gup  <= 6'd0;
                end else begin
                    gacc <= gsum; gup <= gupc;
                end
                if (ci == NM1) begin
                    pm1 <= 6'd0;
                    t   <= t + 16'd1;
                    gl_v <= gx_v; gl_x <= gx;
                    nsb <= 10'd0; nsa <= 10'd0; nsd <= 10'd0; vacc <= 23'sd0;
                    glu <= glu_n; i1 <= i1_n; i2 <= i2_n; rb <= rb_n; ra <= ra_n;
                    if (t[3:0] == 4'd15) begin seq <= seq + 8'd1; wb <= 16'd0; wa <= 16'd0; wd <= 16'd0; end
                    else begin wb <= wb_n; wa <= wa_n; wd <= wd_n; end
                end else begin
                    nsb <= nsb_t; nsa <= nsa_t; nsd <= nsd_t; vacc <= vacc_t;
                end
            end
        end
    end

    wire _unused = &{tbusy, sym[3:0], par[3:0], sym_now[3:0], 1'b0};
endmodule
