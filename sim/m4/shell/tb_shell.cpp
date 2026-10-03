// M4: emu shell simulation (tb_shell.sv). Downloads a set as Main_MiSTer
// sends an MRA (index 1 machine byte, index 0 stream, index 254 DIPs), runs
// from power-on and reports, per output frame of the framework's video path
// (VGA_* after arcade_video, sampled on CE_PIXEL in the 48 MHz domain):
// active pixels, active lines, mean RGB, sync pulse counts; and writes
// frames listed in +cap= as raw RGB (width x lines x 3).
// Plusargs: +sdram=FILE +machine=N +dsw=HEX +frames=N +cap=FILE +out=DIR +osd=0|1
#include "Vtb_shell.h"
#include "Vtb_shell___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <memory>
#include <set>
#include <string>
#include <unistd.h>
#include <vector>

static std::unique_ptr<Vtb_shell> top;
static uint64_t cyc = 0;
static void tick() { top->clk = 0; top->eval(); top->clk = 1; top->eval(); cyc++; }
static std::string plus(const char *n, const char *d) {
    const char *v = Verilated::commandArgsPlusMatch(n);
    if (!v || !*v) return d;
    const char *e = strchr(v, '=');
    return e ? std::string(e + 1) : std::string(d);
}
static void send(int index, uint32_t addr, uint8_t data) {
    while (top->dl_wait) tick();
    top->dl_index = index; top->dl_addr = addr; top->dl_data = data; top->dl_wr = 1; tick();
    top->dl_wr = 0; tick();
}
int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    top = std::make_unique<Vtb_shell>();
    int machine = atoi(plus("machine", "0").c_str());
    unsigned dsw = strtoul(plus("dsw", "FFEF").c_str(), nullptr, 16);
    long nframes = atol(plus("frames", "300").c_str());
    std::string out = plus("out", "."), capf = plus("cap", "");
    std::set<long> cap;
    if (!capf.empty()) { std::ifstream c(capf); long n; while (c >> n) cap.insert(n); }
    std::vector<uint8_t> img;
    { std::ifstream f(plus("sdram", ""), std::ios::binary); img.assign(std::istreambuf_iterator<char>(f), {}); }
    if (img.empty()) { fprintf(stderr, "no +sdram\n"); return 2; }
    top->status[0] = top->status[1] = top->status[2] = top->status[3] = 0;
    top->osd = atoi(plus("osd", "0").c_str());
    for (int i = 0; i < 300; i++) tick();
    top->dl = 1; send(1, 0, machine); top->dl = 0; for (int i = 0; i < 64; i++) tick();
    top->dl = 1; for (size_t a = 0; a < img.size(); a++) send(0, a, img[a]); top->dl = 0; for (int i = 0; i < 64; i++) tick();
    top->dl = 1; send(254, 0, dsw & 0xFF); send(254, 1, dsw >> 8); top->dl = 0;
    printf("download done at clock %llu, machine %d, fb_en %d, arx %d ary %d\n", (unsigned long long)cyc, machine, top->fb_en, top->arx, top->ary);
    fflush(stdout);
    auto *r = top->rootp;
    bool vid_prev = false, vs_prev = false, de_prev = false, hs_prev = false;
    long frame = 0, px = 0, lines = 0, hsn = 0;
    double sr = 0, sg = 0, sb = 0, cr = 0, cg = 0, cb = 0;
    long cpx = 0;
    std::vector<uint8_t> fb;
    while (frame < nframes) {
        tick();
        if (r->tb_shell__DOT__u_emu__DOT__board__DOT__u_sys__DOT__ce_pix && !r->tb_shell__DOT__u_emu__DOT__hbl && !r->tb_shell__DOT__u_emu__DOT__vbl) {
            cpx++; cr += r->tb_shell__DOT__u_emu__DOT__r; cg += r->tb_shell__DOT__u_emu__DOT__g; cb += r->tb_shell__DOT__u_emu__DOT__b;
        }
        bool vid = r->tb_shell__DOT__u_emu__DOT__pll__DOT__div2;
        if (vid && !vid_prev) {     // a 48 MHz rising edge happened on this tick
            if (top->ce_pixel) {
                if (top->vga_de) {
                    if (!de_prev) lines++;
                    px++; sr += top->vga_r; sg += top->vga_g; sb += top->vga_b;
                    if (cap.count(frame)) { fb.push_back(top->vga_r); fb.push_back(top->vga_g); fb.push_back(top->vga_b); }
                }
                de_prev = top->vga_de;
                if (top->vga_hs && !hs_prev) hsn++;
                hs_prev = top->vga_hs;
                if (top->vga_vs && !vs_prev) {
                    if (frame % 25 == 0 || cap.count(frame))
                        printf("frame %ld: %ld active px, %ld lines, mean RGB %.1f %.1f %.1f, hsyncs %ld\n", frame, px, lines,
                               px ? sr / px : 0, px ? sg / px : 0, px ? sb / px : 0, hsn);
                    if (frame % 25 == 0 || cap.count(frame))
                        printf("   mixer: gamma in %06x out %06x, VGA %02x%02x%02x de %d\n",
                               (unsigned)r->tb_shell__DOT__u_emu__DOT__arcade_video__DOT__video_mixer__DOT____Vcellinp__genblk2__DOT__gamma__RGB_in,
                               (unsigned)r->tb_shell__DOT__u_emu__DOT__arcade_video__DOT__video_mixer__DOT____Vcellout__genblk2__DOT__gamma__RGB_out,
                               top->vga_r, top->vga_g, top->vga_b, top->vga_de);
                    if (frame % 25 == 0 || cap.count(frame))
                        printf("   core side: %ld px, mean RGB %.1f %.1f %.1f; pause %d\n", cpx, cpx ? cr / cpx : 0,
                               cpx ? cg / cpx : 0, cpx ? cb / cpx : 0, (int)r->tb_shell__DOT__u_emu__DOT__pause);
                    if (cap.count(frame)) {
                        char fn[128]; snprintf(fn, sizeof fn, "%s/%06ld.rgb", out.c_str(), frame);
                        std::ofstream o(fn, std::ios::binary); o.write((char *)fb.data(), fb.size());
                    }
                    fflush(stdout);
                    fb.clear(); frame++; px = lines = hsn = 0; sr = sg = sb = 0; cr = cg = cb = 0; cpx = 0;
                }
                vs_prev = top->vga_vs;
            }
        }
        vid_prev = vid;
    }
    top->final(); fflush(stdout); _exit(0);
}
