// SPR800E video for 1945k III / Solite Spirits / '96 Flag Rally (PLAN M1).
//
// Reference model: sim/oracle/k3_render.py, pixel-exact against MAME 0.288
// on every M0 capture. Spec sections cited as "spec N" are
// docs/k3_system_spec.md; driver lines "Lnnn" are reference/mame/1945kiii.cpp.
//
// Contents:
//   - raster counters, 432 pixels per line at the pixel enable; 262 lines
//     with 224 visible (k3) or 315 with 240 visible (flagrall) (spec 5)
//   - CPU-side RAMs: palette 0x200 words (spec 6), tile RAM 0x800 words
//     (0x2c0000-0x2c0fff; the low 0x400 words are the tilemap, the rest is
//     plain RAM, L382-383), sprite RAMs 1 and 2, 0x800 words each (L380-381)
//   - the buffers the renderer reads and a copy engine that fills them from
//     the CPU-side RAMs when i_copy pulses (the "VRAM access flip-flop",
//     spec 9; the system decodes the edge per game)
//   - a line renderer: during line L-1 the tile pass and the sprite pass
//     build line L in one half of a double line buffer; scan-out reads the
//     other half and the palette at the pixel enable
//
// The renderer reads the buffers and the scroll registers live, as the
// line is drawn: a copy or scroll write during the active lines takes effect
// from the next line drawn. MAME draws the whole frame at vblank (line
// 224/240), so it shows such a change on every line of that frame (spec 9,
// m0_findings 5; research item R3). Everything written in vblank, which is
// all but a handful of frames per game, gives MAME's frame exactly.
//
// Per line (all on the graphics ROM port, which is pipelined and returns
// accepted requests in order, [31:24] = byte at the address):
//   1. tile pass: 21 tiles of the 32 x 32 map (spec 7), four 32-bit reads
//      each, written opaque into the line buffer (pens 0x000-0x0FF)
//   2. sprite pass, overlapped with 1: a walker tests list entries
//      0 .. budget-1 (857 k3, 1,030 flagrall: MAME's cycle budget, spec
//      8.4) against the line, one entry per clock, and queues hits whose
//      tile has a non-zero pixel (games park unused entries on the blank
//      tile 0, up to 827 of them on one line; a blank tile draws nothing,
//      so skipping it changes no pixel, m1_findings); a
//      fetcher reads the hit's tile row (four 32-bit reads) once the tile
//      pass has issued all its requests. Pixels are written in request
//      order, so sprites land over the tilemap and later entries over
//      earlier ones; pen 0 is transparent, the flicker bit draws 0x1FF
//      (spec 8.3).
// One writer drains the returned words at one pixel per clock.

module k3_video (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        ce_pix,
    input  logic        i_flagrall,     // 0: k3 sets, 1: '96 Flag Rally

    // CPU side, decoded by the system (M2): word address within each RAM,
    // 68000 byte enables {UDS, LDS}
    input  logic [10:0] i_cpu_addr,
    input  logic [15:0] i_cpu_din,
    input  logic [1:0]  i_cpu_be,
    input  logic        i_pal_we,       // 0x200000-0x2003ff (addr[8:0])
    input  logic        i_bg_we,        // 0x2c0000-0x2c0fff (addr[10:0])
    input  logic        i_spr0_we,      // 0x240000-0x240fff
    input  logic        i_spr1_we,      // 0x280000-0x280fff
    output logic [15:0] o_pal_dout,
    output logic [15:0] o_bg_dout,
    output logic [15:0] o_spr0_dout,
    output logic [15:0] o_spr1_dout,
    input  logic        i_scrollx_we,   // 0x340000
    input  logic        i_scrolly_we,   // 0x380000
    input  logic        i_copy,         // one clk: copy CPU-side tile/sprite RAM to the buffers
    output logic        o_copy_busy,

    // sprite tile flags, written while the sprite ROM loads (M4: from the
    // download stream; sim: by the harness): bit (code & 15) of word
    // (code >> 4) is 1 when sprite tile `code` has any non-zero pixel
    input  logic        i_tflag_we,
    input  logic [9:0]  i_tflag_addr,
    input  logic [15:0] i_tflag_din,

    // graphics ROM port (byte address in the PLAN 4.3 SDRAM layout)
    output logic        o_rom_req,
    output logic [22:0] o_rom_addr,
    input  logic        i_rom_gnt,
    input  logic        i_rom_rv,
    input  logic [31:0] i_rom_data,

    // video
    output logic [7:0]  o_r,
    output logic [7:0]  o_g,
    output logic [7:0]  o_b,
    output logic        o_de,
    output logic        o_hblank,
    output logic        o_vblank,
    output logic        o_hs,
    output logic        o_vs,
    output logic [8:0]  o_pen,          // palette index of the pixel (sim/debug)
    output logic        o_vbl_irq,      // one clk at the start of the first vblank line

    // gate counters
    output logic [15:0] o_dbg_overruns,
    output logic [15:0] o_dbg_maxcyc
);

  localparam logic [22:0] SPR_BASE  = 23'h100000;   // PLAN 4.3
  localparam logic [22:0] TILE_BASE = 23'h500000;
  localparam int H_ACT = 320;
  localparam int H_TOTAL = 432;
  // sync positions are not in the driver (spec 5, research item R5)
  localparam int HS_START = 352, HS_END = 384;

  wire [8:0]  v_act   = i_flagrall ? 9'd240 : 9'd224;
  wire [8:0]  v_total = i_flagrall ? 9'd315 : 9'd262;
  wire [10:0] budget  = i_flagrall ? 11'd1030 : 11'd857;
  wire [8:0]  vs_start = v_act + 9'd8;

  // ================================================================ timing
  logic [8:0] hcnt /* verilator public_flat_rd */;
  logic [8:0] vcnt /* verilator public_flat_rd */;
  logic       irq_armed;
  // Power-on phase as in MAME: the screen starts at the first vblank line
  // and the first vblank interrupt comes one frame later (the Dooyong
  // oracle measured this, dooyong m3/ym2203 findings).
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      hcnt <= '0;
      vcnt <= v_act;
      irq_armed <= 1'b0;
    end else if (ce_pix) begin
      if (hcnt == 9'(H_TOTAL - 1)) begin
        hcnt <= '0;
        if (vcnt == v_total - 9'd1) begin
          vcnt <= '0;
          irq_armed <= 1'b1;
        end else vcnt <= vcnt + 9'd1;
      end else hcnt <= hcnt + 9'd1;
    end
  end
  wire line_start = ce_pix && hcnt == 9'd0;
  always_ff @(posedge clk)
    o_vbl_irq <= rst_n && line_start && vcnt == v_act && irq_armed;

  // ================================================================ registers
  logic [15:0] scrollx, scrolly;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      scrollx <= '0;
      scrolly <= '0;
    end else begin
      if (i_scrollx_we) begin
        if (i_cpu_be[1]) scrollx[15:8] <= i_cpu_din[15:8];
        if (i_cpu_be[0]) scrollx[7:0]  <= i_cpu_din[7:0];
      end
      if (i_scrolly_we) begin
        if (i_cpu_be[1]) scrolly[15:8] <= i_cpu_din[15:8];
        if (i_cpu_be[0]) scrolly[7:0]  <= i_cpu_din[7:0];
      end
    end
  end

  // ================================================================ RAMs
  logic [8:0]  pal_rd_addr;
  logic [15:0] pal_q;
  k3_dpram #(.AW(9), .DW(16)) u_pal (
    .clk, .addr_a(i_cpu_addr[8:0]), .d_a(i_cpu_din), .we_a(i_pal_we), .be_a(i_cpu_be),
    .q_a(o_pal_dout), .addr_b(pal_rd_addr), .q_b(pal_q));

  // ---------------------------------------------------------------- copy
  // The copy is a snapshot: the buffers must equal the CPU-side RAMs as
  // they were at the copy edge, as MAME's instant copy (L305-323). The
  // engine walks the 2,048 words (one of each RAM per clock, about 21 us
  // at 96 MHz) while the CPU keeps running, and the games do write tile
  // and sprite RAM inside that window (Flag Rally about once a frame,
  // m2_findings 4). Copy-before-write: every CPU write to these RAMs is
  // registered (stage R); if the engine has not read that word yet and it
  // has not been saved in this copy, the engine pauses for one clock, the
  // word's old value is read through port B and written into the buffer
  // (stage S) together with the delayed CPU write, and the word is marked
  // so the engine skips it later. Marks clear at each copy start. The CPU
  // never waits; o_copy_busy only reports a copy in progress.
  logic [11:0] cp_idx;          // next word the engine reads, bit 11 = finished
  logic        cp_run /* verilator public_flat_rd */;
  logic        cp_v1 /* verilator public_flat_rd */;
  logic [10:0] cp_a1;
  logic [15:0] bg_live_q, s0_live_q, s1_live_q;

  // stage R: registered CPU write to tile/sprite RAM
  logic        wq_v;
  logic [2:0]  wq_ram;          // {spr1, spr0, bg}
  logic [10:0] wq_idx;
  logic [15:0] wq_din;
  logic [1:0]  wq_be;
  // stage S: save the old word, then perform the write
  logic        sv_go;
  logic [2:0]  sv_ram;
  logic [10:0] sv_idx;
  logic [15:0] sv_din;
  logic [1:0]  sv_be;
  // words saved during the current copy
  logic [1023:0] mk_bg;
  logic [2047:0] mk_s0, mk_s1;

  // Timing: the 2,048-way mark lookup for the queued write is done one
  // clock early, from the CPU address as it enters stage R, so it does not
  // sit in front of the RAM write enables and port B address. wq_mk_* equal
  // mk_*[wq_idx] exactly: they include the mark a save sets on that same
  // edge (sv_go) and the clear at a copy start (i_copy).
  logic wq_mk_bg, wq_mk_s0, wq_mk_s1;
  wire wq_marked = (wq_ram[0] && wq_mk_bg) || (wq_ram[1] && wq_mk_s0)
                || (wq_ram[2] && wq_mk_s1);
  wire wq_copied = wq_ram[0] && wq_idx[10];        // tile words 1024+ are not buffered
  wire save_now  = wq_v && cp_run && ({1'b0, wq_idx} >= cp_idx) && !wq_marked && !wq_copied;
  wire [10:0] live_b_addr = save_now ? wq_idx : cp_idx[10:0];

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      wq_v  <= 1'b0;
      sv_go <= 1'b0;
    end else begin
      wq_v   <= i_bg_we || i_spr0_we || i_spr1_we;
      wq_ram <= {i_spr1_we, i_spr0_we, i_bg_we};
      wq_idx <= i_cpu_addr[10:0];
      wq_mk_bg <= !i_copy && (mk_bg[i_cpu_addr[9:0]]
                  || (sv_go && sv_ram[0] && sv_idx[9:0] == i_cpu_addr[9:0]));
      wq_mk_s0 <= !i_copy && (mk_s0[i_cpu_addr[10:0]]
                  || (sv_go && sv_ram[1] && sv_idx == i_cpu_addr[10:0]));
      wq_mk_s1 <= !i_copy && (mk_s1[i_cpu_addr[10:0]]
                  || (sv_go && sv_ram[2] && sv_idx == i_cpu_addr[10:0]));
      wq_din <= i_cpu_din;
      wq_be  <= i_cpu_be;
      sv_go  <= save_now;
      sv_ram <= wq_ram;
      sv_idx <= wq_idx;
      sv_din <= wq_din;
      sv_be  <= wq_be;
    end
  end

  // CPU-side RAM port A: the delayed write (stage R, or S after a save),
  // otherwise the CPU address for reads
  wire        wr_r   = wq_v && !save_now;
  wire [10:0] live_a = sv_go ? sv_idx : (wq_v ? wq_idx : i_cpu_addr[10:0]);
  wire [15:0] live_d = sv_go ? sv_din : wq_din;
  wire [1:0]  live_be = sv_go ? sv_be : wq_be;
  wire [2:0]  live_we = sv_go ? sv_ram : (wr_r ? wq_ram : 3'b000);

  k3_dpram #(.AW(11), .DW(16)) u_bg_live (
    .clk, .addr_a(live_a), .d_a(live_d), .we_a(live_we[0]), .be_a(live_be),
    .q_a(o_bg_dout), .addr_b(live_b_addr), .q_b(bg_live_q));
  k3_dpram #(.AW(11), .DW(16)) u_s0_live (
    .clk, .addr_a(live_a), .d_a(live_d), .we_a(live_we[1]), .be_a(live_be),
    .q_a(o_spr0_dout), .addr_b(live_b_addr), .q_b(s0_live_q));
  k3_dpram #(.AW(11), .DW(16)) u_s1_live (
    .clk, .addr_a(live_a), .d_a(live_d), .we_a(live_we[2]), .be_a(live_be),
    .q_a(o_spr1_dout), .addr_b(live_b_addr), .q_b(s1_live_q));

  // buffers: port A written by the copy engine (or a save), port B read by
  // the renderer
  logic [9:0]  bg_rd_addr;
  logic [10:0] spr_rd_addr;
  logic [15:0] bg_q, s0_q, s1_q;
  wire  [10:0] buf_a  = sv_go ? sv_idx : cp_a1;
  wire         we_bgb = sv_go ? sv_ram[0] : (cp_v1 && !cp_a1[10] && !mk_bg[cp_a1[9:0]]);
  wire         we_s0b = sv_go ? sv_ram[1] : (cp_v1 && !mk_s0[cp_a1]);
  wire         we_s1b = sv_go ? sv_ram[2] : (cp_v1 && !mk_s1[cp_a1]);
  /* verilator lint_off PINCONNECTEMPTY */
  k3_dpram #(.AW(10), .DW(16)) u_bg_buf (
    .clk, .addr_a(buf_a[9:0]), .d_a(bg_live_q), .we_a(we_bgb), .be_a(2'b11),
    .q_a(), .addr_b(bg_rd_addr), .q_b(bg_q));
  k3_dpram #(.AW(11), .DW(16)) u_s0_buf (
    .clk, .addr_a(buf_a), .d_a(s0_live_q), .we_a(we_s0b), .be_a(2'b11),
    .q_a(), .addr_b(spr_rd_addr), .q_b(s0_q));
  k3_dpram #(.AW(11), .DW(16)) u_s1_buf (
    .clk, .addr_a(buf_a), .d_a(s1_live_q), .we_a(we_s1b), .be_a(2'b11),
    .q_a(), .addr_b(spr_rd_addr), .q_b(s1_q));
  /* verilator lint_on PINCONNECTEMPTY */

  // Engine: one word of each RAM per clock, paused for the clock a save
  // uses port B. A new request during a copy restarts it.
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      cp_run <= 1'b0;
      cp_idx <= 12'd2048;
      cp_v1  <= 1'b0;
      mk_bg  <= '0;
      mk_s0  <= '0;
      mk_s1  <= '0;
    end else begin
      cp_v1 <= cp_run && !save_now;
      cp_a1 <= cp_idx[10:0];
      if (i_copy) begin
        cp_run <= 1'b1;
        cp_idx <= '0;
        mk_bg  <= '0;
        mk_s0  <= '0;
        mk_s1  <= '0;
      end else begin
        if (cp_run && !save_now) begin
          if (cp_idx == 12'd2047) cp_run <= 1'b0;
          cp_idx <= cp_idx + 12'd1;
        end
        if (sv_go) begin
          if (sv_ram[0]) mk_bg[sv_idx[9:0]] <= 1'b1;
          if (sv_ram[1]) mk_s0[sv_idx] <= 1'b1;
          if (sv_ram[2]) mk_s1[sv_idx] <= 1'b1;
        end
      end
    end
  end
  assign o_copy_busy = cp_run || cp_v1;

  // ================================================================ renderer
  // line buffer: 2 halves x 512, pen in [8:0]
  logic        lb_we;
  logic [9:0]  lb_wa;
  logic [8:0]  lb_wd;
  logic [15:0] lb_q;
  /* verilator lint_off PINCONNECTEMPTY */
  k3_dpram #(.AW(10), .DW(16)) u_lb (
    .clk, .addr_a(lb_wa), .d_a({7'd0, lb_wd}), .we_a(lb_we), .be_a(2'b11),
    .q_a(), .addr_b({vcnt[0], hcnt}), .q_b(lb_q));
  /* verilator lint_on PINCONNECTEMPTY */

  // ---- line start
  wire [8:0] next_line = (vcnt == v_total - 9'd1) ? 9'd0 : vcnt + 9'd1;
  wire       want_line = line_start && next_line < v_act;

  logic        busy, pend;
  logic [8:0]  pend_line;
  logic [8:0]  r_line;
  logic [8:0]  r_sx;
  logic [8:0]  r_ty;            // map row pixel (line + scrolly) mod 512
  logic [15:0] cyc, maxcyc, overruns;
  wire         go = !busy && (want_line || pend);
  wire [8:0]   go_line = want_line ? next_line : pend_line;

  // ---- tile issuer
  logic [4:0]  t_k;             // tile 0..20 of the line
  logic [1:0]  t_j;             // word 0..3 of the tile row
  logic [1:0]  t_st;            // 0 idle, 1 address set, 2 code valid, 3 issuing
  logic        t_done;
  logic [15:0] t_code;
  localparam logic [1:0] T_IDLE = 2'd0, T_ADDR = 2'd1, T_WAIT = 2'd2, T_ISS = 2'd3;

  // ---- sprite walker
  logic [10:0] w_idx;
  logic        w_run, w_v1, w_v2;
  logic        w2_hit;
  logic [8:0]  w2_x;
  logic [3:0]  w2_row;
  logic [13:0] w2_code;
  logic        w2_flk;
  logic        w_done;

  // ---- hit queue: {flick, code[13:0], row[3:0], x[8:0]}
  logic        h_push, h_pop, h_empty, h_full;
  logic [27:0] h_d, h_q;
  logic [4:0]  h_count;
  k3_fifo #(.W(28), .DEPTH(16)) u_hits (
    .clk, .clr(!rst_n), .push(h_push), .d(h_d), .pop(h_pop), .q(h_q),
    .empty(h_empty), .full(h_full), .count(h_count));

  // ---- request tags (one per accepted ROM request): {spr, flick, x0[9:0]}
  logic        m_push, m_pop, m_empty, m_full;
  logic [11:0] m_d, m_q;
  logic [3:0]  m_count;
  k3_fifo #(.W(12), .DEPTH(8)) u_tags (
    .clk, .clr(!rst_n), .push(m_push), .d(m_d), .pop(m_pop), .q(m_q),
    .empty(m_empty), .full(m_full), .count(m_count));

  // ---- returned words
  logic        d_pop, d_empty;
  logic [31:0] d_q;
  /* verilator lint_off PINCONNECTEMPTY */
  k3_fifo #(.W(32), .DEPTH(8)) u_ret (
    .clk, .clr(!rst_n), .push(i_rom_rv), .d(i_rom_data), .pop(d_pop), .q(d_q),
    .empty(d_empty), .full(), .count());
  /* verilator lint_on PINCONNECTEMPTY */

  // ---- sprite fetcher
  logic [1:0]  f_j;

  // tile request
  wire [4:0]  t_col  = r_sx[8:4] + t_k;
  wire [15:0] t_cmask = t_code & (i_flagrall ? 16'h0FFF : 16'h1FFF);   // modulo the tile count (spec 7)
  wire [22:0] t_addr = TILE_BASE + {t_cmask[12:0], r_ty[3:0], t_j, 2'b00};
  // x of the word's first pixel: k * 16 - fine x + 4 j (10-bit two's complement)
  wire [9:0]  t_x0   = {1'b0, t_k, 4'd0} - {6'd0, r_sx[3:0]} + {6'd0, t_j, 2'b00};
  wire        t_req  = t_st == T_ISS;

  // sprite request from the hit queue head
  wire [8:0]  h_x    = h_q[8:0];
  wire [3:0]  h_row  = h_q[12:9];
  wire [13:0] h_code = h_q[26:13];
  wire        h_flk  = h_q[27];
  wire [22:0] f_addr = SPR_BASE + {1'b0, h_code, h_row, f_j, 2'b00};   // code already modulo (walker)
  wire [8:0]  f_x0   = h_x + {5'd0, f_j, 2'b00};
  wire        f_req  = t_done && !h_empty && busy;

  assign o_rom_req  = (t_req || f_req) && !m_full;
  assign o_rom_addr = t_req ? t_addr : f_addr;
  wire   accept     = o_rom_req && i_rom_gnt;
  assign m_push     = accept;
  assign m_d        = t_req ? {1'b0, 1'b0, t_x0} : {1'b1, h_flk, 1'b0, f_x0};
  assign h_pop      = accept && !t_req && f_j == 2'd3;

  // walker stage 1 (w_v1): the entry is on the sprite buffer outputs; test
  // the line (spec 8.1) and look up the tile's flag. Stage 2 (w_v2): queue
  // the hit if the tile has a non-zero pixel.
  wire [7:0]  w_dy   = r_line[7:0] - s0_q[7:0];
  wire [13:0] w_code = s1_q[14:1];
  wire [13:0] w_cmod = (i_flagrall && w_code >= 14'd12288) ? w_code - 14'd12288 : w_code;   // spec 8.2
  logic [15:0] tflag_q;
  /* verilator lint_off PINCONNECTEMPTY */
  k3_dpram #(.AW(10), .DW(16)) u_tflag (
    .clk, .addr_a(i_tflag_addr), .d_a(i_tflag_din), .we_a(i_tflag_we), .be_a(2'b11),
    .q_a(), .addr_b(w_cmod[13:4]), .q_b(tflag_q));
  /* verilator lint_on PINCONNECTEMPTY */
  assign h_push = w_v2 && w2_hit && tflag_q[w2_code[3:0]];
  assign h_d    = {w2_flk, w2_code, w2_row, w2_x};
  wire   w_room = h_count <= 5'd12;
  always_ff @(posedge clk) begin
    w_v2    <= w_v1 && rst_n;
    w2_hit  <= w_dy[7:4] == 4'd0;
    w2_x    <= {s1_q[0], s0_q[15:8]};
    w2_row  <= w_dy[3:0];
    w2_code <= w_cmod;
    w2_flk  <= s1_q[15];
  end
  assign spr_rd_addr = w_idx;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      busy <= 1'b0;
      pend <= 1'b0;
      t_st <= T_IDLE;
      t_done <= 1'b1;
      w_run <= 1'b0;
      w_v1 <= 1'b0;
      w_done <= 1'b1;
      f_j <= '0;
      cyc <= '0;
      maxcyc <= '0;
      overruns <= '0;
    end else begin
      // ---- line start / overrun bookkeeping
      if (want_line && busy) begin
        overruns <= overruns + 16'd1;
        pend <= 1'b1;
        pend_line <= next_line;
      end else if (go) pend <= 1'b0;

      if (go) begin
        busy <= 1'b1;
        r_line <= go_line;
        r_sx <= scrollx[8:0];
        r_ty <= go_line + scrolly[8:0];
        t_st <= T_ADDR;
        t_k <= '0;
        t_j <= '0;
        t_done <= 1'b0;
        w_run <= 1'b1;
        w_idx <= '0;
        w_done <= 1'b0;
        f_j <= '0;
        cyc <= '0;
      end else if (busy) begin
        cyc <= cyc + 16'd1;
        if (t_done && w_done && h_empty && m_empty && d_empty) begin
          busy <= 1'b0;
          if (cyc > maxcyc) maxcyc <= cyc;
        end
      end

      // ---- tile issuer: bg buffer read then four requests per tile
      case (t_st)
        T_ADDR: t_st <= T_WAIT;
        T_WAIT: begin
          t_code <= bg_q;
          t_st <= T_ISS;
        end
        T_ISS: if (accept) begin
          t_j <= t_j + 2'd1;
          if (t_j == 2'd3) begin
            if (t_k == 5'd20) begin
              t_st <= T_IDLE;
              t_done <= 1'b1;
            end else begin
              t_k <= t_k + 5'd1;
              t_st <= T_ADDR;
            end
          end
        end
        default: ;
      endcase

      // ---- walker: the RAM samples w_idx at the clock that sets w_v1, so the
      // entry is on the RAM output while w_v1 is high (one entry in flight)
      w_v1 <= 1'b0;
      if (!go && w_run && w_room) begin
        w_v1 <= 1'b1;
        if (w_idx == budget - 11'd1) w_run <= 1'b0;
        else w_idx <= w_idx + 11'd1;
      end
      if (!go && !w_run && !w_v1 && !w_v2) w_done <= 1'b1;

      // ---- fetcher word counter
      if (accept && !t_req) f_j <= f_j + 2'd1;
    end
  end
  assign bg_rd_addr = {r_ty[8:4], t_col};

  // ---- writer: one pixel per clock from the returned words
  logic [1:0] wb;
  wire [7:0]  pix   = d_q[31 - 8 * wb -: 8];
  wire        is_sp = m_q[11];
  wire [9:0]  wx_t  = m_q[9:0] + {8'd0, wb};
  wire [8:0]  wx_s  = m_q[8:0] + {7'd0, wb};
  wire        wvis  = is_sp ? (wx_s < 9'(H_ACT) && pix != 8'd0)
                            : (!wx_t[9] && wx_t[8:0] < 9'(H_ACT));
  wire        wact  = !d_empty && !m_empty;
  assign lb_we = wact && wvis;
  assign lb_wa = {r_line[0], is_sp ? wx_s : wx_t[8:0]};
  assign lb_wd = !is_sp ? {1'b0, pix} : (m_q[10] ? 9'h1FF : {1'b1, pix});
  assign d_pop = wact && wb == 2'd3;
  assign m_pop = d_pop;
  always_ff @(posedge clk) begin
    if (!rst_n) wb <= '0;
    else if (wact) wb <= wb + 2'd1;
  end

  assign o_dbg_overruns = overruns;
  assign o_dbg_maxcyc   = maxcyc;

  // ================================================================ scan-out
  // The line buffer is addressed by the counters; its pen addresses the
  // palette on the next clock, and the colour is registered at the next
  // pixel enable (one pixel of pipeline delay on every output).
  assign pal_rd_addr = lb_q[8:0];
  logic [8:0] pen_d;
  always_ff @(posedge clk) pen_d <= lb_q[8:0];

  function automatic [7:0] x5(input [4:0] v);
    x5 = {v, v[4:2]};
  endfunction

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      o_de <= 1'b0;
      o_hblank <= 1'b1;
      o_vblank <= 1'b1;
      o_hs <= 1'b0;
      o_vs <= 1'b0;
    end else if (ce_pix) begin
      o_de     <= hcnt < 9'(H_ACT) && vcnt < v_act;
      o_hblank <= hcnt >= 9'(H_ACT);
      o_vblank <= vcnt >= v_act;
      o_hs     <= hcnt >= 9'(HS_START) && hcnt < 9'(HS_END);
      o_vs     <= vcnt >= vs_start && vcnt < vs_start + 9'd3;
      o_r      <= x5(pal_q[4:0]);
      o_g      <= x5(pal_q[9:5]);
      o_b      <= x5(pal_q[14:10]);
      o_pen    <= pen_d;
    end
  end

endmodule
