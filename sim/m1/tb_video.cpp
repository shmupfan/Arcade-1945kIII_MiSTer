// M1 frame-replay harness for k3_video (Verilator, C++).
//
// For each frame file in the list: with the pixel enable stopped at the
// start of the first vblank line, write the palette, the tilemap RAM and
// both sprite RAMs through the CPU ports, set the scroll registers, pulse
// the buffer copy and wait for it, then run one whole frame (v_total lines
// of 432 pixels) and capture every o_de pixel.
//
// Frame file (.k3f, written by sim/m1/replay.py):
//   "K3F1", game u8 (0 k3, 1 flagrall), nsw u8 (number of mid-frame
//   switches, 0 or 1), scrollx u16 LE, scrolly u16 LE,
//   palette 1024 bytes, tilemap RAM 2048 bytes, sprite RAM 1 4096 bytes,
//   sprite RAM 2 4096 bytes (16-bit words, high byte first);
//   then per switch: line u16 LE, hpos u16 LE, scrollx u16 LE,
//   scrolly u16 LE, tilemap 2048, sprite 1 4096, sprite 2 4096 bytes.
// A switch stops the pixel enable when the beam reaches (line, hpos) of the
// frame, rewrites the CPU-side RAMs and scroll, pulses the copy, waits for
// it, and resumes: the frame then shows what a line renderer does when the
// game copies mid-scan (R3).
// Output (.rgbp): 320 x lines x 5 bytes: R, G, B, pen low, pen high.
//
// Plusargs: +sdram=FILE +list=FILE (lines "in out"); pixel enable
// +num=N +den=N (default 9/128: 6.75 MHz from 96 MHz, 6,144 clocks a line);
// ROM model: pipelined, in order, one request accepted every +intv=N
// clocks (default 8), data +lat=N clocks after acceptance (default 9),
// the Dooyong M1 pessimistic port.

#include "Vk3_video.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <fstream>
#include <memory>
#include <string>
#include <vector>
#include <unistd.h>

static std::unique_ptr<Vk3_video> top;
static std::vector<uint8_t> sdram;
static int lat = 9, intv = 8, pnum = 9, pden = 128;
static uint64_t cycles = 0, last_acc = 0;
static int acc = 0;
struct Resp { uint64_t t; uint32_t d; };
static std::deque<Resp> rq;

static uint32_t rd32(uint32_t a) {
    uint32_t v = 0;
    for (int i = 0; i < 4; i++) v = (v << 8) | (a + i < sdram.size() ? sdram[a + i] : 0);
    return v;
}

static void tick(bool ce) {
    top->ce_pix = ce;
    bool rv = !rq.empty() && rq.front().t <= cycles;
    top->i_rom_rv = rv;
    if (rv) { top->i_rom_data = rq.front().d; rq.pop_front(); }
    bool gnt = cycles - last_acc >= (uint64_t)intv;
    top->i_rom_gnt = gnt;
    top->clk = 0; top->eval();
    if (gnt && top->o_rom_req) {
        rq.push_back({cycles + (uint64_t)lat, rd32(top->o_rom_addr)});
        last_acc = cycles;
    }
    top->clk = 1; top->eval();
    cycles++;
}

// clocks up to and including the next pixel enable
static void run_pixel() {
    for (;;) {
        acc += pnum;
        bool ce = acc >= pden;
        if (ce) acc -= pden;
        tick(ce);
        if (ce) return;
    }
}

static std::string plus(const char *name, const char *def) {
    const char *v = Verilated::commandArgsPlusMatch(name);
    if (!v || !*v) return def;
    const char *eq = strchr(v, '=');
    return eq ? std::string(eq + 1) : std::string(def);
}

static void wr1(int which, int a, uint16_t d) {
    top->i_cpu_addr = a; top->i_cpu_din = d; top->i_cpu_be = 3;
    top->i_pal_we = which == 0; top->i_bg_we = which == 1;
    top->i_spr0_we = which == 2; top->i_spr1_we = which == 3;
    top->i_scrollx_we = which == 4; top->i_scrolly_we = which == 5;
    tick(false);
    top->i_pal_we = top->i_bg_we = top->i_spr0_we = top->i_spr1_we = 0;
    top->i_scrollx_we = top->i_scrolly_we = 0;
}

static void wrblk(int which, const uint8_t *p, int nbytes) {
    for (int a = 0; a < nbytes; a += 2) wr1(which, a / 2, (p[a] << 8) | p[a + 1]);
}

static void copy_now() {
    top->i_copy = 1; tick(false); top->i_copy = 0;
    while (top->o_copy_busy) tick(false);
}

static uint16_t le16(const uint8_t *p) { return p[0] | (p[1] << 8); }

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    top = std::make_unique<Vk3_video>();
    std::string sd = plus("sdram", ""), list = plus("list", "");
    lat = atoi(plus("lat", "9").c_str());
    intv = atoi(plus("intv", "8").c_str());
    pnum = atoi(plus("num", "9").c_str());
    pden = atoi(plus("den", "128").c_str());
    last_acc = (uint64_t)-1000;
    {
        std::ifstream f(sd, std::ios::binary);
        if (!f) { fprintf(stderr, "cannot open sdram %s\n", sd.c_str()); return 2; }
        sdram.assign(std::istreambuf_iterator<char>(f), {});
    }
    std::vector<std::pair<std::string, std::string>> frames;
    {
        std::ifstream f(list);
        std::string a, b;
        while (f >> a >> b) frames.push_back({a, b});
    }
    if (frames.empty()) { fprintf(stderr, "empty list\n"); return 2; }

    std::vector<uint8_t> fb;
    auto load = [&](const std::string &p) {
        std::ifstream f(p, std::ios::binary);
        fb.assign(std::istreambuf_iterator<char>(f), {});
        return fb.size() >= 10 + 1024 + 2048 + 8192 && memcmp(fb.data(), "K3F1", 4) == 0;
    };
    if (!load(frames[0].first)) { fprintf(stderr, "bad frame %s\n", frames[0].first.c_str()); return 2; }
    const bool flag = fb[4] == 1;
    const int vact = flag ? 240 : 224, vtot = flag ? 315 : 262;
    top->i_flagrall = flag;
    top->rst_n = 0;
    top->i_copy = 0;
    top->i_tflag_we = 0;
    for (int i = 0; i < 16; i++) tick(false);
    top->rst_n = 1;
    tick(false);
    // sprite tile flags (what the M4 loader computes from the download
    // stream): bit set when the 16 x 16 tile has any non-zero pixel
    {
        const int ntiles = flag ? 12288 : 16384;
        int nz = 0;
        for (int w = 0; w < 1024; w++) {
            uint16_t v = 0;
            for (int b = 0; b < 16; b++) {
                int t = w * 16 + b;
                if (t >= ntiles) continue;
                size_t base = 0x100000 + (size_t)t * 256;
                bool any = false;
                for (int k = 0; k < 256 && !any; k++) any = base + k < sdram.size() && sdram[base + k];
                if (any) { v |= 1u << b; nz++; }
            }
            top->i_tflag_addr = w; top->i_tflag_din = v; top->i_tflag_we = 1;
            tick(false);
        }
        top->i_tflag_we = 0;
        tick(false);
        fprintf(stderr, "sprite tiles with pixels: %d of %d\n", nz, ntiles);
    }
    // counters are at the start of line vact (the first vblank line)

    int bad = 0;
    for (auto &fr : frames) {
        if (!load(fr.first)) { fprintf(stderr, "bad frame %s\n", fr.first.c_str()); return 2; }
        const int nsw = fb[5];
        const uint8_t *pal = &fb[10], *bg = pal + 1024, *s0 = bg + 2048, *s1 = s0 + 4096;
        uint16_t over0 = top->o_dbg_overruns;
        wrblk(0, pal, 1024);
        wrblk(1, bg, 2048);
        wrblk(2, s0, 4096);
        wrblk(3, s1, 4096);
        wr1(4, 0, le16(&fb[6]));
        wr1(5, 0, le16(&fb[8]));
        copy_now();

        int swl = -1, swh = -1;
        const uint8_t *sw = s1 + 4096;
        if (nsw) { swl = le16(sw); swh = le16(sw + 2); }
        std::vector<uint8_t> out;
        out.reserve(320 * vact * 5);
        for (long i = 0; i < (long)vtot * 432; i++) {
            // the frame starts at line vact; line numbers of the switch are
            // those of the displayed frame (0 = first visible line)
            if (nsw) {
                long line = (vact + i / 432) % vtot, h = i % 432;
                if (line == swl && h == swh) {
                    wr1(4, 0, le16(sw + 4));
                    wr1(5, 0, le16(sw + 6));
                    wrblk(1, sw + 8, 2048);
                    wrblk(2, sw + 8 + 2048, 4096);
                    wrblk(3, sw + 8 + 6144, 4096);
                    copy_now();
                }
            }
            run_pixel();
            if (top->o_de) {
                out.push_back(top->o_r);
                out.push_back(top->o_g);
                out.push_back(top->o_b);
                out.push_back(top->o_pen & 0xFF);
                out.push_back(top->o_pen >> 8);
            }
        }
        if (out.size() != 320u * vact * 5) {
            fprintf(stderr, "%s: captured %zu pixels\n", fr.first.c_str(), out.size() / 5);
            bad++;
        }
        std::ofstream o(fr.second, std::ios::binary);
        o.write((const char *)out.data(), out.size());
        printf("FRAME %s overruns %d maxcyc %d\n", fr.first.c_str(),
               (int)(uint16_t)(top->o_dbg_overruns - over0), (int)top->o_dbg_maxcyc);
    }
    printf("DONE frames %zu bad %d cycles %llu\n", frames.size(), bad, (unsigned long long)cycles);
    top->final();
    top.reset();
    fflush(stdout);
    _exit(bad ? 1 : 0);
}
