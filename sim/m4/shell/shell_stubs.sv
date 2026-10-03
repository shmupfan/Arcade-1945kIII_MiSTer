// Simulation stand-ins for the two framework blocks the emu shell needs that
// have no simulation model: the PLL (96 MHz system and SDRAM clocks, 48 MHz
// video clock phase aligned with it) and hps_io (driven from tb_shell's
// signals). Everything else in the shell's video path is the real sys/ code
// (arcade_video, screen_rotate, video_mixer, scandoubler, hq2x, gamma_corr).
module pll (
    input  refclk,
    input  rst,
    output outclk_0,
    output outclk_1,
    output outclk_2,
    output locked
);
  reg div2 = 1'b0;
  always @(posedge refclk) div2 <= ~div2;
  assign outclk_0 = refclk;
  assign outclk_1 = refclk;
  assign outclk_2 = div2;
  assign locked   = 1'b1;
endmodule

module hps_io #(parameter CONF_STR = "", CONF_STR_BRAM = 0, PS2DIV = 0,
                WIDE = 0, VDNUM = 1, BLKSZ = 2, PS2WE = 0, STRLEN = 0) (
    input         clk_sys,
    inout  [45:0] HPS_BUS,
    inout  [35:0] EXT_BUS,
    inout  [21:0] gamma_bus,
    output [1:0]  buttons,
    output [127:0] status,
    input  [15:0] status_menumask,
    output        forced_scandoubler,
    output        direct_video,
    input         video_rotated,
    output        ioctl_download,
    output        ioctl_wr,
    output [26:0] ioctl_addr,
    output [7:0]  ioctl_dout,
    output [15:0] ioctl_index,
    input         ioctl_wait,
    output        ioctl_upload,
    input         ioctl_upload_req,
    input  [7:0]  ioctl_upload_index,
    input  [7:0]  ioctl_din,
    output [31:0] joystick_0,
    output [31:0] joystick_1,
    output [10:0] ps2_key
);
  assign buttons            = 2'b00;
  assign status             = tb_shell.status;
  assign forced_scandoubler = 1'b0;
  assign direct_video       = 1'b0;
  assign ioctl_download     = tb_shell.dl;
  assign ioctl_wr           = tb_shell.dl_wr;
  assign ioctl_addr         = tb_shell.dl_addr;
  assign ioctl_dout         = tb_shell.dl_data;
  assign ioctl_index        = tb_shell.dl_index;
  assign ioctl_upload       = 1'b0;
  assign joystick_0         = 32'd0;
  assign joystick_1         = 32'd0;
  assign ps2_key            = 11'd0;
  assign gamma_bus[20:0]     = 21'd0;      // gamma off; bit 21 is driven by video_mixer (as hps_io)
  always @(posedge clk_sys) tb_shell.dl_wait <= ioctl_wait;
endmodule
