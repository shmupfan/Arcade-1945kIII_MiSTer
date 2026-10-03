// 1945k III board (PLAN M4): everything below the MiSTer framework.
// k3_sys (68000, RAMs, video, two M6295) + k3_sdram, plus the ioctl download
// handling, so the board simulation runs exactly what the RBF contains.
//
// ioctl indices (MRA, tools/make_mra.py):
//   0    ROM stream = the SDRAM image of PLAN 4.3 from byte 0 (each MRA is
//        proven to reproduce sim/build/regions/<set>/sdram.bin). While the
//        sprite region (0x100000-0x4FFFFF) streams past, the board builds
//        k3_video's "tile has pixels" table: bit (t & 15) of word (t >> 4)
//        is 1 when any of sprite tile t's 256 bytes is non-zero.
//   1    machine byte: bit 0 = '96 Flag Rally (flagrall machine config),
//        0 = the k3 sets. Sampled while the core is held in reset.
//   254  DIP switches: byte 0 = DSW bits 0-7 (SW1), byte 1 = bits 8-15 (SW2)
// The core is held in reset during any download and until the SDRAM is
// initialised.
//
// Program ROM: 1 MB region, 436-470 KB of live code per set, too large for
// block RAM; k3_sdram serves it from its own bank (see k3_sdram.sv and
// docs/m4_findings.md for the zero-wait-state requirement on k3_sys).

module k3_board #(
    parameter int  CLK_HZ     = 96000000,
    parameter int  PIX_NUM    = 9,
    parameter int  PIX_DEN    = 128,
    parameter bit  SHORT_INIT = 1'b0
) (
    input  logic        clk,
    input  logic        i_sdram_rst_n,  // PLL locked
    input  logic        i_reset,

    input  logic        i_ioctl_download,
    input  logic        i_ioctl_wr,
    input  logic [26:0] i_ioctl_addr,
    input  logic [7:0]  i_ioctl_dout,
    input  logic [15:0] i_ioctl_index,
    output logic        o_ioctl_wait,

    // inputs, active low, in the driver's port layout (spec 11)
    input  logic [15:0] i_inputs,
    input  logic [15:0] i_system,
    input  logic        i_pause,        // OSD / key pause (k3_sys holds CPU and OKI enables)
    input  logic [1:0]  i_volume,       // OSD volume: 0 normal, 1 +6 dB, 2 -6 dB, 3 -12 dB

    output logic [7:0]  o_r,
    output logic [7:0]  o_g,
    output logic [7:0]  o_b,
    output logic        o_hblank,
    output logic        o_vblank,
    output logic        o_hs,
    output logic        o_vs,
    output logic        o_de,
    output logic        o_ce_pix,
    output logic signed [15:0] o_audio,
    output logic        o_flagrall,
    output logic [8:0]  o_pen,          // sim/debug: palette index of the pixel
    output logic        o_vbl_irq,      // sim/debug

    // gate counters
    output logic [15:0] o_dbg_overruns,
    output logic [15:0] o_dbg_maxcyc,
    output logic [15:0] o_dbg_ref_forced,
    output logic [7:0]  o_dbg_cpu_maxlat,
    // k3_sys gate counters (m2_findings 1): ROM-area writes, unmapped
    // accesses, 0x8c0000 accesses above 4 KB, tile/sprite writes during a
    // copy, late program reads (must stay 0 with this SDRAM controller)
    output logic [15:0] o_dbg_rom_writes,
    output logic [15:0] o_dbg_unmapped,
    output logic [15:0] o_dbg_ram8c_hi,
    output logic [15:0] o_dbg_wstall,
    output logic [15:0] o_dbg_prom_late,

    output logic [12:0] SDRAM_A,
    output logic [1:0]  SDRAM_BA,
    inout  wire  [15:0] SDRAM_DQ,
    output logic        SDRAM_DQML,
    output logic        SDRAM_DQMH,
    output logic        SDRAM_nCS,
    output logic        SDRAM_nRAS,
    output logic        SDRAM_nCAS,
    output logic        SDRAM_nWE,
    output logic        SDRAM_CKE
);

  // ------------------------------------------------------------------ ioctl
  wire rom_wr = i_ioctl_download && i_ioctl_wr && i_ioctl_index[7:0] == 8'd0;

  /* verilator lint_off PROCASSINIT */
  logic       machine = 1'b0;           // power-on values, as Dooyong
  logic [7:0] dsw0 = 8'hFF, dsw1 = 8'hFF;
  /* verilator lint_on PROCASSINIT */
  always_ff @(posedge clk) begin
    if (i_ioctl_wr && i_ioctl_index[7:0] == 8'd1 && i_ioctl_addr == 27'd0)
      machine <= i_ioctl_dout[0];
    if (i_ioctl_wr && i_ioctl_index[7:0] == 8'd254) begin
      if (i_ioctl_addr == 27'd0) dsw0 <= i_ioctl_dout;
      if (i_ioctl_addr == 27'd1) dsw1 <= i_ioctl_dout;
    end
  end
  assign o_flagrall = machine;

  // sprite tile flags from the stream (addresses arrive in order)
  wire        in_spr = rom_wr && i_ioctl_addr >= 27'h100000 && i_ioctl_addr < 27'h500000;
  wire [21:0] spr_off = 22'(i_ioctl_addr - 27'h100000);
  /* verilator lint_off PROCASSINIT */
  logic       tf_nz = 1'b0;
  /* verilator lint_on PROCASSINIT */
  logic [15:0] tf_acc;
  logic       tf_we;
  logic [9:0] tf_addr;
  logic [15:0] tf_din;
  always_ff @(posedge clk) begin
    tf_we <= 1'b0;
    if (in_spr) begin
      logic nz;
      nz = tf_nz || (i_ioctl_dout != 8'd0);
      if (spr_off[7:0] == 8'hFF) begin
        tf_nz <= 1'b0;
        tf_acc[spr_off[11:8]] <= nz;
        if (spr_off[11:8] == 4'hF) begin
          tf_we   <= 1'b1;
          tf_addr <= spr_off[21:12];
          tf_din  <= {nz, tf_acc[14:0]};
        end
      end else
        tf_nz <= nz;
    end
  end

  // ------------------------------------------------------------------ SDRAM
  logic        core_rst_n;
  logic        sd_ready;
  logic        prom_req, prom_ok;
  logic [19:1] prom_addr;
  logic [15:0] prom_data;
  logic        rom_req, rom_gnt, rom_rv;
  logic [22:0] rom_addr;
  logic [31:0] rom_data;
  logic [19:0] oki1_addr;
  logic [18:0] oki2_addr;
  logic [7:0]  oki1_data, oki2_data;
  logic        oki1_ok, oki2_ok;

  k3_sdram #(.P_SHORT_INIT(SHORT_INIT), .REFRESH_PERIOD(CLK_HZ / 128000),
             .INIT_CYCLES(CLK_HZ / 10000)) u_sdram (
    .clk(clk), .rst_n(i_sdram_rst_n), .o_ready(sd_ready),
    .i_dl_wr(rom_wr), .i_dl_addr(i_ioctl_addr[23:0]), .i_dl_data(i_ioctl_dout),
    .o_dl_busy(o_ioctl_wait),
    .i_cpu_run(core_rst_n), .i_cpu_req(prom_req), .i_cpu_addr(prom_addr), .o_cpu_data(prom_data), .o_cpu_ok(prom_ok),
    .i_gfx_req(rom_req), .i_gfx_addr(rom_addr), .o_gfx_gnt(rom_gnt),
    .o_gfx_rv(rom_rv), .o_gfx_data(rom_data),
    .i_oki1_addr(oki1_addr), .o_oki1_data(oki1_data), .o_oki1_ok(oki1_ok),
    .i_oki2_addr(oki2_addr), .o_oki2_data(oki2_data), .o_oki2_ok(oki2_ok),
    .o_dbg_refreshes(), .o_dbg_ref_forced(o_dbg_ref_forced),
    .o_dbg_cpu_maxlat(o_dbg_cpu_maxlat), .o_dbg_dl_words(),
    .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA), .SDRAM_DQ(SDRAM_DQ),
    .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
    .SDRAM_nCS(SDRAM_nCS), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
    .SDRAM_nWE(SDRAM_nWE), .SDRAM_CKE(SDRAM_CKE));

  // ------------------------------------------------------------------ core
  always_ff @(posedge clk) core_rst_n <= !i_reset && !i_ioctl_download && sd_ready;

  logic signed [13:0] oki1_snd, oki2_snd;

  k3_sys #(.CLK_HZ(CLK_HZ), .PIX_NUM(PIX_NUM), .PIX_DEN(PIX_DEN)) u_sys (
    .clk(clk), .rst_n(core_rst_n), .i_flagrall(machine), .i_pause(i_pause),
    .o_prom_req(prom_req), .o_prom_addr(prom_addr), .i_prom_data(prom_data), .i_prom_ok(prom_ok),
    .o_oki1_addr(oki1_addr), .i_oki1_data(oki1_data), .i_oki1_ok(oki1_ok),
    .o_oki2_addr(oki2_addr), .i_oki2_data(oki2_data), .i_oki2_ok(oki2_ok),
    .o_oki1(oki1_snd), .o_oki2(oki2_snd), .o_oki_sample(),
    .i_inputs(i_inputs), .i_system(i_system), .i_dsw({dsw1, dsw0}),
    .i_tflag_we(tf_we), .i_tflag_addr(tf_addr), .i_tflag_din(tf_din),
    .o_rom_req(rom_req), .o_rom_addr(rom_addr),
    .i_rom_gnt(rom_gnt), .i_rom_rv(rom_rv), .i_rom_data(rom_data),
    .o_r(o_r), .o_g(o_g), .o_b(o_b), .o_de(o_de),
    .o_hblank(o_hblank), .o_vblank(o_vblank), .o_hs(o_hs), .o_vs(o_vs),
    .o_pen(o_pen), .o_vbl_irq(o_vbl_irq), .o_ce_pix(o_ce_pix),
    .o_dbg_overruns(o_dbg_overruns), .o_dbg_maxcyc(o_dbg_maxcyc),
    .o_dbg_rom_writes(o_dbg_rom_writes), .o_dbg_unmapped(o_dbg_unmapped), .o_dbg_ram8c_hi(o_dbg_ram8c_hi),
    .o_dbg_wstall(o_dbg_wstall), .o_dbg_prom_late(o_dbg_prom_late),
    .o_cpu_pc_dbg());

  // ------------------------------------------------------------------ audio
  // Both M6295 at gain 1.0 into one mono output (L676, L687); flagrall has
  // only OKI 1 (OKI 2 stays silent). Each jt6295 output is the sum of its
  // four channels in 12-bit units (MAME: 1/2048 of full scale per unit).
  // Output gain with saturation (m3_findings 6). The PCB sets level with a
  // volume pot after the OKIs (VR1, L72/L94), so absolute level is ours to
  // choose. Reference: Final Star Force on the Tecmo 16 core, gameplay
  // 1 s RMS median -16.4 dBFS, p95 -13.0 dBFS. Gains (measured on every M3
  // run, unclipped M6295 sum in 12-bit units):
  //   k3 sets: x48. k3_play median -17.4, p95 -12.5, peak 681 units ->
  //            32,688 (-0.0 dBFS); 0 samples clip in any k3 run (x64 would
  //            clip 0.013-0.016%). The old x8 left them about 15 dB quieter.
  //   flagrall: x12. Median -18.7, p95 -15.1, peak 2,415 units -> 28,980
  //            (-1.1 dBFS), 0 clipped (x16 would clip about 0.001%).
  // i_volume (OSD): 0 normal, 1 +6 dB, 2 -6 dB, 3 -12 dB; saturation keeps
  // +6 dB safe on loud passages. Both operands signed (Dooyong landmine:
  // one unsigned operand makes the whole sum unsigned).
  logic signed [14:0] mix;
  logic signed [21:0] base, amp;
  assign mix  = 15'(oki1_snd) + 15'(oki2_snd);
  assign base = machine ? (22'(mix) <<< 3) + (22'(mix) <<< 2)    // x12
                        : (22'(mix) <<< 5) + (22'(mix) <<< 4);   // x48
  always_comb begin
    case (i_volume)
      2'd1:    amp = base <<< 1;
      2'd2:    amp = base >>> 1;
      2'd3:    amp = base >>> 2;
      default: amp = base;
    endcase
  end
  always_ff @(posedge clk)
    o_audio <= (amp > 22'sd32767)  ? 16'sh7FFF :
               (amp < -22'sd32768) ? 16'sh8000 : amp[15:0];

endmodule
