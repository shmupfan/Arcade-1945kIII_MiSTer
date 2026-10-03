// M4 SDRAM controller testbench top: k3_sdram + the SDRAM model on one DQ
// bus, every client port brought out to sim/m4/tb_sdram.cpp.
module tb_sdram (
    input  logic        clk,
    input  logic        rst_n,
    output logic        o_ready,
    input  logic        i_dl_wr,
    input  logic [23:0] i_dl_addr,
    input  logic [7:0]  i_dl_data,
    output logic        o_dl_busy,
    input  logic        i_cpu_run,
    input  logic        i_cpu_req,
    input  logic [19:1] i_cpu_addr,
    output logic [15:0] o_cpu_data,
    output logic        o_cpu_ok,
    input  logic        i_gfx_req,
    input  logic [22:0] i_gfx_addr,
    output logic        o_gfx_gnt,
    output logic        o_gfx_rv,
    output logic [31:0] o_gfx_data,
    input  logic [19:0] i_oki1_addr,
    output logic [7:0]  o_oki1_data,
    output logic        o_oki1_ok,
    input  logic [18:0] i_oki2_addr,
    output logic [7:0]  o_oki2_data,
    output logic        o_oki2_ok,
    output logic [15:0] o_dbg_refreshes,
    output logic [15:0] o_dbg_ref_forced,
    output logic [7:0]  o_dbg_cpu_maxlat,
    output logic [15:0] o_dbg_dl_words
);
  wire [12:0] A;
  wire [1:0]  BA;
  wire [15:0] DQ;
  wire        DQML, DQMH, nCS, nRAS, nCAS, nWE, CKE;

  k3_sdram #(.P_SHORT_INIT(1'b1)) u_sdram (
    .clk, .rst_n, .o_ready,
    .i_dl_wr, .i_dl_addr, .i_dl_data, .o_dl_busy,
    .i_cpu_run, .i_cpu_req, .i_cpu_addr, .o_cpu_data, .o_cpu_ok,
    .i_gfx_req, .i_gfx_addr, .o_gfx_gnt, .o_gfx_rv, .o_gfx_data,
    .i_oki1_addr, .o_oki1_data, .o_oki1_ok,
    .i_oki2_addr, .o_oki2_data, .o_oki2_ok,
    .o_dbg_refreshes, .o_dbg_ref_forced, .o_dbg_cpu_maxlat, .o_dbg_dl_words,
    .SDRAM_A(A), .SDRAM_BA(BA), .SDRAM_DQ(DQ), .SDRAM_DQML(DQML),
    .SDRAM_DQMH(DQMH), .SDRAM_nCS(nCS), .SDRAM_nRAS(nRAS), .SDRAM_nCAS(nCAS),
    .SDRAM_nWE(nWE), .SDRAM_CKE(CKE));

  sdram_model u_mem (
    .clk, .A, .BA, .DQ, .DQML, .DQMH, .nCS, .nRAS, .nCAS, .nWE, .CKE);
endmodule
