// 1945k III / Solite Spirits / '96 Flag Rally main system (PLAN M2):
// 68000 (fx68k), work RAM, memory map, control register, inputs, the two
// M6295 (jt6295) and the SPR800E video (k3_video).
//
// Spec sections are docs/k3_system_spec.md; driver lines "Lnnn" are
// reference/mame/1945kiii.cpp.
//
// Clocks: one system clock (96 MHz on hardware; the simulation may run it
// lower, see sim/Makefile M2). Every enable is fractional, so the ratios
// match MAME exactly at any system clock that the pixel ratio divides:
//   - pixel enable PIX_NUM / PIX_DEN of the clock: 6.75 MHz = 27 MHz / 4
//     (L667, L689); 9/128 at 96 MHz, 27/256 at 64 MHz
//   - 68000 two-phase enables at 2 x 16 MHz (MASTER_CLOCK, L655, L660)
//   - M6295 enables at 1 MHz (MASTER_CLOCK / 16, L675, L686)
// 268,288 CPU clocks per k3 frame, as MAME.
//
// Bus: no wait states, as MAME's memory model and the board's EPROM decode.
// The program ROM is external (1 MB; SDRAM in M4): a program read asserts
// DTACK at once like any other read and keeps loading i_prom_data into the
// read latch until i_prom_ok. fx68k captures read data on every phi2 from T3
// until the cycle ends (rtl/vendor/fx68k/fx68k.sv busControl), last at AS +
// 15 clocks at 96 MHz (2.5 CPU clocks), so a ROM that answers within that
// gives the right word with no wait state. o_dbg_prom_late counts program
// reads whose ok came after AS + PROM_LIMIT clocks (the last capture) or not
// at all before AS rose: must stay 0 (m2_findings 2; M4 controller 8-9 clocks).
//
// Pause (i_pause): the 68000 phase enables and the OKI enables stop (their
// accumulators hold, so the clocks resume in phase); the video keeps
// scanning the buffers, IRQ4 stays pending until the CPU runs again.
//
// Memory map (spec 4; L371-409), byte addresses, 68000 24-bit bus. Exact
// decodes, no mirrors (MAME maps none); unmapped reads return 0 and
// unmapped writes are ignored (MAME's unmap value), counted in o_dbg_unmapped:
//   0x000000-0x0fffff  program ROM (writes ignored, counted: the games write
//                      0x00098a-0x0009d3, L373-375)
//   0x100000-0x10ffff  work RAM 64 KB
//   0x200000-0x2003ff  palette (k3_video)
//   0x240000-0x240fff  sprite RAM 1, 0x280000-0x280fff sprite RAM 2
//   0x2c0000-0x2c0fff  tilemap RAM (0x2c0000-0x2c07ff buffered, the rest plain)
//   0x340000 / 0x380000  scroll X / Y (write only)
//   0x3c0000           control (write only): buffer flip-flop and OKI banks
//   0x400000 INPUTS, 0x440000 SYSTEM, 0x480000 DSW (16-bit, active low)
//   k3: 0x4c0000 OKI 1 and 0x500000 OKI 2 (byte handler at the odd address
//       with cswidth(16), L397-398: any write to the word reaches the chip;
//       the games write the even byte, m0 data), 0x8c0000-0x8cffff RAM (L399)
//   flagrall: 0x4c0000 OKI 1 on the low byte only (L408)
//
// 0x8c0000 RAM: MAME maps 64 KB; the games only touch 0x8c0000-0x8c0fff (a
// boot RAM test, m0_findings 7), so the core has 4 KB there, mirrored over
// the 64 KB, and counts any access above 0x8c0fff (o_dbg_ram8c_hi; zero in
// every run, research item R4).
//
// Control register 0x3c0000 (spec 9; L335-368):
//   k3: copy on the rising edge of data bit 0 (the handler ignores the byte
//       mask, so a byte write sees the byte on both lanes, as on the bus);
//       bit 1 OKI 1 bank, bit 2 OKI 2 bank (ROM address bit 18)
//   flagrall: data & mask; copy on the falling edge of bit 5; bits 2:1 the
//       OKI bank (256 KB banks)
// The flip-flop starts at 0 (m_refresh = false).
//
// The copy takes 2,048 clocks (k3_video); MAME's is instant. k3_video makes
// it a snapshot with copy-before-write, so the CPU never waits; writes to
// tile or sprite RAM that land during a copy are counted in o_dbg_wstall
// (m2_findings 4).
//
// IRQ4 at the start of vblank (line 224 / 240), held until the CPU
// acknowledges level 4 (irq4_line_hold, L662), autovectored (VPA).

module k3_sys #(
    parameter int CLK_HZ  = 96000000,
    parameter int PIX_NUM = 9,
    parameter int PIX_DEN = 128,
    // simulation only (m2_findings 5): hold the video (pixel enable, raster
    // counters) this many clocks after the CPU leaves reset, to study the
    // CPU-to-video power-on phase. 0 on hardware.
    parameter int VID_DELAY = 0,
    // M6295 enable rate. 1,000,000 = MASTER_CLOCK / 16 (L675, L686). Override
    // only for diagnostics (m2_findings 5.3: 999,900 reproduces MAME 0.288's
    // integer-truncated 7,575 Hz OKI sample rate).
    parameter int OKI_HZ = 1000000
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        i_flagrall,
    input  logic        i_pause,        // holds the 68000 and the OKIs; video keeps scanning

    // program ROM (1 MB, 16-bit words, high byte = even address)
    output logic        o_prom_req,
    output logic [19:1] o_prom_addr,
    input  logic [15:0] i_prom_data,
    input  logic        i_prom_ok,

    // M6295 sample ROMs: OKI 1 (k3 512 KB; flagrall 1 MB in 256 KB banks),
    // OKI 2 (512 KB). Data valid when ok.
    output logic [19:0] o_oki1_addr,
    input  logic [7:0]  i_oki1_data,
    input  logic        i_oki1_ok,
    output logic [18:0] o_oki2_addr,
    input  logic [7:0]  i_oki2_data,
    input  logic        i_oki2_ok,
    output logic signed [13:0] o_oki1,
    output logic signed [13:0] o_oki2,
    output logic        o_oki_sample,

    // inputs, active low (spec 11)
    input  logic [15:0] i_inputs,
    input  logic [15:0] i_system,
    input  logic [15:0] i_dsw,

    // sprite tile flags (see k3_video)
    input  logic        i_tflag_we,
    input  logic [9:0]  i_tflag_addr,
    input  logic [15:0] i_tflag_din,

    // graphics ROM port (see k3_video)
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
    output logic [8:0]  o_pen,
    output logic        o_vbl_irq,
    output logic        o_ce_pix,

    // debug / gate counters
    output logic [15:0] o_dbg_overruns,
    output logic [15:0] o_dbg_maxcyc,
    output logic [15:0] o_dbg_rom_writes,
    output logic [15:0] o_dbg_unmapped,
    output logic [15:0] o_dbg_ram8c_hi,
    output logic [15:0] o_dbg_wstall,      // tile/sprite RAM writes during a copy
    output logic [15:0] o_dbg_prom_late,   // program reads whose data came too late (must stay 0)
    output logic [23:0] o_cpu_pc_dbg
);

  // ================================================================ enables
  logic        vrst_n;
  generate
    if (VID_DELAY == 0) begin : g_vrst
      assign vrst_n = rst_n;
    end else begin : g_vrst_dly
      logic [15:0] vd_cnt;
      always_ff @(posedge clk)
        if (!rst_n) vd_cnt <= '0;
        else if (vd_cnt != 16'(VID_DELAY)) vd_cnt <= vd_cnt + 16'd1;
      assign vrst_n = rst_n && vd_cnt == 16'(VID_DELAY);
    end
  endgenerate
  logic        ce_pix /* verilator public_flat_rd */;
  logic [15:0] pix_acc;
  logic [27:0] m_acc, o_acc;
  logic        m_ph, en_phi1, en_phi2, oki_cen;
  localparam int F68  = 16000000;   // MASTER_CLOCK (L655, L660)
  localparam int FOKI = OKI_HZ;     // MASTER_CLOCK / 16 (L675, L686)
  always_ff @(posedge clk) begin
    if (!vrst_n) begin
      pix_acc <= '0;
      ce_pix  <= 1'b0;
    end else if (pix_acc + 16'(PIX_NUM) >= 16'(PIX_DEN)) begin
      pix_acc <= pix_acc + 16'(PIX_NUM) - 16'(PIX_DEN);
      ce_pix  <= 1'b1;
    end else begin
      pix_acc <= pix_acc + 16'(PIX_NUM);
      ce_pix  <= 1'b0;
    end
  end
  always_ff @(posedge clk) begin
    en_phi1 <= 1'b0;
    en_phi2 <= 1'b0;
    oki_cen <= 1'b0;
    if (!rst_n) begin
      m_acc   <= '0;
      m_ph    <= 1'b0;
      o_acc   <= '0;
    end else if (!i_pause) begin
      if (m_acc + 28'(2 * F68) >= 28'(CLK_HZ)) begin
        m_acc <= m_acc + 28'(2 * F68) - 28'(CLK_HZ);
        m_ph  <= !m_ph;
        if (m_ph) en_phi2 <= 1'b1;
        else      en_phi1 <= 1'b1;
      end else
        m_acc <= m_acc + 28'(2 * F68);
      if (o_acc + 28'(FOKI) >= 28'(CLK_HZ)) begin
        o_acc   <= o_acc + 28'(FOKI) - 28'(CLK_HZ);
        oki_cen <= 1'b1;
      end else
        o_acc <= o_acc + 28'(FOKI);
    end
  end
  assign o_ce_pix = ce_pix;

  // ================================================================ 68000
  logic        m_rw /* verilator public_flat_rd */, m_asn;
  logic        m_ldsn /* verilator public_flat_rd */, m_udsn /* verilator public_flat_rd */;
  logic        m_fc0, m_fc1, m_fc2;
  logic        m_dtackn, m_vpan;
  logic [2:0]  m_ipl;
  logic [15:0] m_din;
  logic [15:0] m_dout /* verilator public_flat_rd */;
  logic [23:1] m_a /* verilator public_flat_rd */;

  fx68k u_m68k (
    .clk(clk), .HALTn(1'b1),
    .extReset(!rst_n), .pwrUp(!rst_n),
    .enPhi1(en_phi1), .enPhi2(en_phi2),
    .eRWn(m_rw), .ASn(m_asn), .LDSn(m_ldsn), .UDSn(m_udsn),
    .E(), .VMAn(),
    .FC0(m_fc0), .FC1(m_fc1), .FC2(m_fc2),
    .BGn(), .oRESETn(), .oHALTEDn(),
    .DTACKn(m_dtackn), .VPAn(m_vpan),
    .BERRn(1'b1), .BRn(1'b1), .BGACKn(1'b1),
    .IPL0n(~m_ipl[0]), .IPL1n(~m_ipl[1]), .IPL2n(~m_ipl[2]),
    .iEdb(m_din), .oEdb(m_dout), .eab(m_a));

  wire [23:0] m_ba = {m_a, 1'b0};
  wire        m_asn_pub /* verilator public_flat_rd */ = m_asn;            // harness traces
  wire        m_fc_prog /* verilator public_flat_rd */ = m_fc1 && !m_fc0;  // program space
  wire        m_iack /* verilator public_flat_rd */ = m_fc2 && m_fc1 && m_fc0 && !m_asn;

  // IRQ4: set at vblank, cleared by the level 4 acknowledge (L662)
  logic vbl_irq, irq4_p;
  always_ff @(posedge clk) begin
    if (!rst_n) irq4_p <= 1'b0;
    else begin
      if (vbl_irq) irq4_p <= 1'b1;
      if (m_iack && m_a[3:1] == 3'd4) irq4_p <= 1'b0;
    end
  end
  assign m_ipl  = irq4_p ? 3'd4 : 3'd0;
  assign m_vpan = !m_iack;

  // ================================================================ decode
  wire s_rom   = m_ba[23:20] == 4'h0;
  wire s_ram   = m_ba[23:16] == 8'h10;
  wire s_pal   = m_ba[23:10] == 14'(24'h200000 >> 10);
  wire s_spr0  = m_ba[23:12] == 12'h240;
  wire s_spr1  = m_ba[23:12] == 12'h280;
  wire s_bg    = m_ba[23:12] == 12'h2c0;
  wire s_scx   = m_ba[23:1] == 23'(24'h340000 >> 1);
  wire s_scy   = m_ba[23:1] == 23'(24'h380000 >> 1);
  wire s_ctrl  = m_ba[23:1] == 23'(24'h3c0000 >> 1);
  wire s_in    = m_ba[23:1] == 23'(24'h400000 >> 1);
  wire s_sys   = m_ba[23:1] == 23'(24'h440000 >> 1);
  wire s_dsw   = m_ba[23:1] == 23'(24'h480000 >> 1);
  wire s_oki1  = m_ba[23:1] == 23'(24'h4c0000 >> 1);
  wire s_oki2  = !i_flagrall && m_ba[23:1] == 23'(24'h500000 >> 1);
  wire s_ram8c = !i_flagrall && m_ba[23:16] == 8'h8c;
  wire s_vbuf  = s_spr0 || s_spr1 || s_bg;        // buffered by the copy
  wire s_any   = s_rom || s_ram || s_pal || s_vbuf || s_scx || s_scy || s_ctrl
              || s_in || s_sys || s_dsw || s_oki1 || s_oki2 || s_ram8c;

  // ================================================================ bus
  // Writes: DTACK at once and the write performed when a data strobe
  // appears.
  // Reads: one clock for the memory outputs; the program ROM waits for
  // i_prom_ok.
  typedef enum logic [2:0] {MB_IDLE, MB_RD, MB_ROM, MB_ACK} mbst_t;
  // last fx68k data capture of a read: AS + 15 clocks at 96 MHz (2.5 CPU
  // clocks). prom_cnt counts from the first MB_ROM clock (AS + 1); data that
  // arrives with ok at count k is in the latch from AS + k + 2, so k must be
  // at most 12 at 96 MHz (7 at 64 MHz). One clock of the 15 is kept spare
  // for the exact capture edge.
  localparam int PROM_LIMIT = (CLK_HZ / 16000000) * 5 / 2 - 3;
  logic [7:0]  prom_cnt;
  logic        prom_got;
  mbst_t       mbst;
  wire         m_rd_oki /* verilator public_flat_rd */ = (mbst == MB_RD) && (s_oki1 || s_oki2);
  logic        m_wdone;
  logic [15:0] m_rdata /* verilator public_flat_rd */;
  logic        copy_busy;
  wire         m_ds = !(m_udsn && m_ldsn);
  wire         m_wstb /* verilator public_flat_rd */ = (mbst == MB_ACK) && !m_rw && m_ds && !m_wdone;
  assign m_dtackn    = !(mbst == MB_ACK || mbst == MB_ROM);
  assign m_din       = m_rdata;
  assign o_prom_req  = (mbst == MB_ROM);
  assign o_prom_addr = m_a[19:1];
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      mbst    <= MB_IDLE;
      m_wdone <= 1'b0;
      o_dbg_wstall <= '0;
      o_dbg_prom_late <= '0;
      prom_cnt <= '0;
      prom_got <= 1'b0;
    end else begin
      case (mbst)
        MB_IDLE: if (!m_asn && !m_iack) begin
          if (!m_rw) begin
            m_wdone <= 1'b0;
            mbst <= MB_ACK;
            if (s_vbuf && copy_busy) o_dbg_wstall <= o_dbg_wstall + 16'd1;
          end else if (m_ds) begin
            mbst     <= s_rom ? MB_ROM : MB_RD;
            prom_cnt <= '0;
            prom_got <= 1'b0;
          end
        end
        MB_RD: mbst <= MB_ACK;
        MB_ROM: begin   // DTACK asserted; data latched until ok, cycle ends on AS
          if (prom_cnt != 8'hFF) prom_cnt <= prom_cnt + 8'd1;
          if (i_prom_ok) begin
            prom_got <= 1'b1;
            if (!prom_got && prom_cnt > 8'(PROM_LIMIT)) o_dbg_prom_late <= o_dbg_prom_late + 16'd1;
          end
          if (m_asn) begin
            mbst <= MB_IDLE;
            if (!prom_got && !i_prom_ok) o_dbg_prom_late <= o_dbg_prom_late + 16'd1;
          end
        end
        MB_ACK: begin
          if (m_wstb) m_wdone <= 1'b1;
          if (m_asn) mbst <= MB_IDLE;
        end
        default: mbst <= MB_IDLE;
      endcase
    end
  end

  // ================================================================ memories
  logic [15:0] ram_q, r8c_q;
  wire  [1:0]  m_be = {~m_udsn, ~m_ldsn};
  k3_dpram #(.AW(15), .DW(16)) u_ram (
    .clk, .addr_a(m_a[15:1]), .d_a(m_dout), .we_a(m_wstb && s_ram), .be_a(m_be),
    .q_a(ram_q), .addr_b(15'd0), .q_b());
  k3_dpram #(.AW(11), .DW(16)) u_ram8c (
    .clk, .addr_a(m_a[11:1]), .d_a(m_dout), .we_a(m_wstb && s_ram8c), .be_a(m_be),
    .q_a(r8c_q), .addr_b(11'd0), .q_b());

  // ================================================================ control
  // byte writes carry the byte on both lanes (as the 68000 bus and MAME)
  wire [15:0] wdata  = m_udsn ? {m_dout[7:0], m_dout[7:0]}
                     : (m_ldsn ? {m_dout[15:8], m_dout[15:8]} : m_dout);
  wire [15:0] wmask  = {{8{~m_udsn}}, {8{~m_ldsn}}};
  wire        ctrl_w = m_wstb && s_ctrl;
  logic       refresh;
  logic       copy /* verilator public_flat_rd */;
  logic       bank1;
  logic [1:0] bank0;
  wire  [15:0] fr_data = wdata & wmask;
  wire        k3_new = wdata[0];          // k3: data unmasked (L343)
  wire        fr_new = !fr_data[5];       // flagrall: BIT(~(data & mask), 5) (L363)
  wire        newval = i_flagrall ? fr_new : k3_new;
  always_ff @(posedge clk) begin
    copy <= 1'b0;
    if (!rst_n) begin
      refresh <= 1'b0;
      bank0   <= '0;
      bank1   <= 1'b0;
    end else if (ctrl_w) begin
      if (!refresh && newval) copy <= 1'b1;
      refresh <= newval;
      if (i_flagrall) bank0 <= fr_data[2:1];               // L367
      else begin
        bank0 <= {1'b0, wdata[1]};                         // L345
        bank1 <= wdata[2];                                 // L344
      end
    end
  end

  // ================================================================ OKI
  // k3: any write to the OKI word (cswidth(16)); flagrall: low byte only
  wire       oki1_w = m_wstb && s_oki1 && (!i_flagrall || !m_ldsn);
  wire       oki2_w = m_wstb && s_oki2;
  wire [7:0] oki_wd = m_ldsn ? m_dout[15:8] : m_dout[7:0];
  logic [7:0]  oki1_dout, oki2_dout;
  logic [17:0] oki1_ra, oki2_ra;
  logic        oki1_smp;
  jt6295 #(.INTERPOL(0)) u_oki1 (
    .rst(!rst_n), .clk(clk), .cen(oki_cen), .ss(1'b1),     // PIN7_HIGH (L675)
    .wrn(!oki1_w), .din(oki_wd), .dout(oki1_dout),
    .rom_addr(oki1_ra), .rom_data(i_oki1_data), .rom_ok(i_oki1_ok),
    .sound(o_oki1), .sample(oki1_smp));
  jt6295 #(.INTERPOL(0)) u_oki2 (
    .rst(!rst_n || i_flagrall), .clk(clk), .cen(oki_cen), .ss(1'b1),
    .wrn(!oki2_w), .din(oki_wd), .dout(oki2_dout),
    .rom_addr(oki2_ra), .rom_data(i_oki2_data), .rom_ok(i_oki2_ok),
    .sound(o_oki2), .sample());
  assign o_oki1_addr  = {bank0, oki1_ra};
  assign o_oki2_addr  = {bank1, oki2_ra};
  assign o_oki_sample = oki1_smp;

  // ================================================================ video
  logic [15:0] pal_q, bg_q, s0_q, s1_q;
  k3_video u_video (
    .clk, .rst_n(vrst_n), .ce_pix, .i_flagrall,
    .i_cpu_addr(m_a[11:1]), .i_cpu_din(m_dout), .i_cpu_be(m_be),
    .i_pal_we(m_wstb && s_pal), .i_bg_we(m_wstb && s_bg),
    .i_spr0_we(m_wstb && s_spr0), .i_spr1_we(m_wstb && s_spr1),
    .o_pal_dout(pal_q), .o_bg_dout(bg_q), .o_spr0_dout(s0_q), .o_spr1_dout(s1_q),
    .i_scrollx_we(m_wstb && s_scx), .i_scrolly_we(m_wstb && s_scy),
    .i_copy(copy), .o_copy_busy(copy_busy),
    .i_tflag_we, .i_tflag_addr, .i_tflag_din,
    .o_rom_req, .o_rom_addr, .i_rom_gnt, .i_rom_rv, .i_rom_data,
    .o_r, .o_g, .o_b, .o_de, .o_hblank, .o_vblank, .o_hs, .o_vs, .o_pen,
    .o_vbl_irq(vbl_irq),
    .o_dbg_overruns, .o_dbg_maxcyc);
  assign o_vbl_irq = vbl_irq;

  // ================================================================ read mux
  always_ff @(posedge clk) begin
    if (mbst == MB_ROM && i_prom_ok && !prom_got) m_rdata <= i_prom_data;
    else if (mbst == MB_RD) begin
      if (s_ram)        m_rdata <= ram_q;
      else if (s_pal)   m_rdata <= pal_q;
      else if (s_spr0)  m_rdata <= s0_q;
      else if (s_spr1)  m_rdata <= s1_q;
      else if (s_bg)    m_rdata <= bg_q;
      else if (s_in)    m_rdata <= i_inputs;
      else if (s_sys)   m_rdata <= i_system;
      else if (s_dsw)   m_rdata <= i_dsw;
      else if (s_oki1)  m_rdata <= {8'h00, oki1_dout};   // m2_findings: MAME reads 0x00Fx
      else if (s_oki2)  m_rdata <= {8'h00, oki2_dout};
      else if (s_ram8c) m_rdata <= r8c_q;
      else              m_rdata <= 16'h0000;            // write-only and unmapped
    end
  end

  // ================================================================ counters
  logic m_asn_q;
  always_ff @(posedge clk) begin
    m_asn_q <= m_asn;
    if (!rst_n) begin
      o_dbg_rom_writes <= '0;
      o_dbg_unmapped   <= '0;
      o_dbg_ram8c_hi   <= '0;
      o_cpu_pc_dbg     <= '0;
    end else begin
      if (m_wstb && s_rom) o_dbg_rom_writes <= o_dbg_rom_writes + 16'd1;
      if (m_asn_q && !m_asn && !m_iack) begin
        if (!s_any) o_dbg_unmapped <= o_dbg_unmapped + 16'd1;
        if (s_ram8c && m_ba[15:12] != 4'h0) o_dbg_ram8c_hi <= o_dbg_ram8c_hi + 16'd1;
        if (m_fc1 && !m_fc0 && m_rw) o_cpu_pc_dbg <= m_ba;   // program space read (opcode/ext)
      end
    end
  end

endmodule
