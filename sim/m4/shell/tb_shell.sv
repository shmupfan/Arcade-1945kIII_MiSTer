// M4: the whole emu shell (Arcade-1945kIII.sv) with the SDRAM model, so the
// video reaching the framework (VGA_*, CE_PIXEL from arcade_video) can be
// checked for every machine, including Flag Rally's 315-line raster.
// Driven from tb_shell.cpp; hps_io and the PLL are shell_stubs.sv.
`define MISTER_FB 1
module tb_shell (
    input  logic        clk,
    input  logic [127:0] status,
    input  logic        dl,
    input  logic        dl_wr,
    input  logic [26:0] dl_addr,
    input  logic [7:0]  dl_data,
    input  logic [15:0] dl_index,
    output logic        dl_wait,
    input  logic        osd,
    output logic        ce_pixel,
    output logic        vga_de,
    output logic        vga_hs,
    output logic        vga_vs,
    output logic [7:0]  vga_r,
    output logic [7:0]  vga_g,
    output logic [7:0]  vga_b,
    output logic        fb_en,
    output logic [12:0] arx,
    output logic [12:0] ary
);
  wire [45:0] HPS_BUS;
  wire [12:0] A;
  wire [1:0]  BA;
  wire [15:0] DQ;
  wire DQML, DQMH, nCS, nRAS, nCAS, nWE, CKE;
  wire [3:0] ADC_BUS;
  emu u_emu (
    .CLK_50M(clk), .RESET(1'b0), .HPS_BUS(HPS_BUS),
    .CLK_VIDEO(), .CE_PIXEL(ce_pixel), .VIDEO_ARX(arx), .VIDEO_ARY(ary),
    .VGA_R(vga_r), .VGA_G(vga_g), .VGA_B(vga_b), .VGA_HS(vga_hs), .VGA_VS(vga_vs), .VGA_DE(vga_de),
    .VGA_F1(), .VGA_SL(), .VGA_SCALER(), .VGA_DISABLE(),
    .HDMI_WIDTH(12'd1920), .HDMI_HEIGHT(12'd1080), .HDMI_FREEZE(), .HDMI_BLACKOUT(), .HDMI_BOB_DEINT(),
    .FB_EN(fb_en), .FB_FORMAT(), .FB_WIDTH(), .FB_HEIGHT(), .FB_BASE(), .FB_STRIDE(),
    .FB_VBL(1'b0), .FB_LL(1'b0), .FB_FORCE_BLANK(),
    .LED_USER(), .LED_POWER(), .LED_DISK(), .BUTTONS(),
    .CLK_AUDIO(1'b0), .AUDIO_L(), .AUDIO_R(), .AUDIO_S(), .AUDIO_MIX(), .ADC_BUS(ADC_BUS),
    .SD_SCK(), .SD_MOSI(), .SD_MISO(1'b0), .SD_CS(), .SD_CD(1'b0),
    .DDRAM_CLK(), .DDRAM_BUSY(1'b0), .DDRAM_BURSTCNT(), .DDRAM_ADDR(), .DDRAM_DOUT(64'd0),
    .DDRAM_DOUT_READY(1'b0), .DDRAM_RD(), .DDRAM_DIN(), .DDRAM_BE(), .DDRAM_WE(),
    .SDRAM_CLK(), .SDRAM_CKE(CKE), .SDRAM_A(A), .SDRAM_BA(BA), .SDRAM_DQ(DQ),
    .SDRAM_DQML(DQML), .SDRAM_DQMH(DQMH), .SDRAM_nCS(nCS), .SDRAM_nCAS(nCAS),
    .SDRAM_nRAS(nRAS), .SDRAM_nWE(nWE),
    .UART_CTS(1'b0), .UART_RTS(), .UART_RXD(1'b0), .UART_TXD(), .UART_DTR(), .UART_DSR(1'b0),
    .USER_IN(7'd0), .USER_OUT(), .OSD_STATUS(osd));
  sdram_model u_mem (
    .clk(clk), .A(A), .BA(BA), .DQ(DQ), .DQML(DQML), .DQMH(DQMH),
    .nCS(nCS), .nRAS(nRAS), .nCAS(nCAS), .nWE(nWE), .CKE(CKE));
endmodule
