// M4 board harness for k3_board + SDRAM model (sim/m4/tb_board.sv).
//
// Everything arrives as on the MiSTer: the machine byte (ioctl index 1), the
// DIP switches (index 254) and the ROM stream (index 0 = the set's sdram.bin,
// which every MRA is proven to reproduce, m4_findings) go through k3_board's
// ioctl port, honouring ioctl_wait, into k3_sdram and the SDRAM model; the
// sprite tile flags are built by the board from the stream. Then the system
// runs from power-on: program ROM, graphics and both OKIs all come from the
// SDRAM controller and the cycle-checked SDRAM model, not from a C++ model.
//
// Outputs are the M2 harness's (m2/tb_sys.cpp), same names and formats, so
// m2/compare.py checks a board run against MAME exactly as an M2 run:
//   NNNNNN.rgbp, .wlog for every frame in +cap=FILE; at vblank N .pal .bgl
//   .bgb .s0l .s1l .s0b .s1b .ram .r8c; +io=FILE (scroll, control, OKI
//   writes). Frame numbering as M2: vblank N = the N-th o_vbl_irq,
//   displayed frame N = the pixels between vblank N and N+1.
// Audio: every clock, o_audio must equal the two M6295 outputs of the
// previous clock summed, x48 (k3 sets) or x12 (flagrall) at the default
// volume, saturated to 16 bits (k3_board); mismatches,
// saturated clocks and the peak are printed with the counters.
// Gate counters printed every 500 vblanks and at the end: renderer overruns
// and worst line, k3_sys's ROM-area writes, unmapped accesses, 0x8c0000
// accesses above 4 KB, writes stalled by a copy, late program reads; the
// SDRAM controller's worst CPU latency and forced refreshes; the copy
// snapshot self-check (as M2).
//
// Plusargs: +sdram=FILE +machine=0|1 (also +flagrall=) +dsw=HEX +frames=N
//   +cap=FILE +out=DIR +io=FILE +inputs=FILE +inlag=N (default 1) +pause=F:N
//   +dlen=N (bytes of the stream to send, default all)
//   +first=SDRAM:MACHINE:DSW:FRAMES run another game first (download it,
//   run it for FRAMES vblanks), then load the game under test with a new
//   download, as the MiSTer does when a second MRA for the same core is
//   loaded without reconfiguring the FPGA (RAMs and registers keep whatever
//   the first game left). Frame numbering restarts with the second game.

#include "Vtb_board.h"
#include "Vtb_board___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <map>
#include <memory>
#include <set>
#include <sstream>
#include <string>
#include <tuple>
#include <unistd.h>
#include <vector>

#define S(x) r->tb_board__DOT__u_board__DOT__u_sys__DOT__##x

static std::unique_ptr<Vtb_board> top;
static uint64_t cyc = 0;

// Video-during-reset statistics (boot black-screen fix): vsync rising
// edges and lit active pixels while the core is not running (o_vbl_irq not
// seen since the last download/reset) vs running.
static int vphase = 0;                 // 0 = core not yet running, 1 = running
static long vs_edges[2], lit_px[2], de_px[2];
static bool vs_prev = false;
static void tick() {
    top->clk = 0; top->eval();
    top->clk = 1; top->eval();
    cyc++;
    bool vs = top->rootp->tb_board__DOT__vs;
    if (vs && !vs_prev) vs_edges[vphase]++;
    vs_prev = vs;
    if (top->o_de && top->o_ce_pix) {
        de_px[vphase]++;
        if (top->o_r | top->o_g | top->o_b) lit_px[vphase]++;
    }
    if (top->o_vbl_irq && vphase == 0) {
        printf("PRE-RUN vs_edges %ld de_px %ld lit_px %ld (clock %llu)\n",
               vs_edges[0], de_px[0], lit_px[0], (unsigned long long)cyc);
        vs_edges[0] = de_px[0] = lit_px[0] = 0;
        vphase = 1;
    }
}

static std::string plus(const char *name, const char *def) {
    const char *v = Verilated::commandArgsPlusMatch(name);
    if (!v || !*v) return def;
    const char *eq = strchr(v, '=');
    return eq ? std::string(eq + 1) : std::string(def);
}

static void send(int index, uint32_t addr, uint8_t data) {
    while (top->o_ioctl_wait) tick();
    top->i_ioctl_index = index; top->i_ioctl_addr = addr; top->i_ioctl_dout = data;
    top->i_ioctl_wr = 1;
    tick();
    top->i_ioctl_wr = 0;
    tick();
}

static void dump(const std::string &path, const void *p, size_t n) {
    std::ofstream o(path, std::ios::binary);
    o.write((const char *)p, n);
}

template <typename A> static void dumpw(const std::string &path, const A &mem, int nwords) {
    std::vector<uint8_t> b(2 * nwords);
    for (int i = 0; i < nwords; i++) { uint16_t w = mem[i]; b[2 * i] = w >> 8; b[2 * i + 1] = w & 0xFF; }
    dump(path, b.data(), b.size());
}

static bool field_bit(const std::string &port, const std::string &field, int &p, int &bit) {
    static const char *dir[4] = {"Up", "Down", "Left", "Right"};
    if (port == "INPUTS") {
        p = 0;
        for (int pl = 1; pl <= 2; pl++) {
            std::string pre = "P" + std::to_string(pl) + " ";
            if (field.compare(0, pre.size(), pre) != 0) continue;
            std::string rr = field.substr(pre.size());
            for (int d = 0; d < 4; d++) if (rr == dir[d]) { bit = (pl - 1) * 8 + d; return true; }
            if (rr.compare(0, 7, "Button ") == 0) { bit = (pl - 1) * 8 + 4 + (rr[7] - '1'); return true; }
        }
        return false;
    }
    if (port == "SYSTEM") {
        p = 1;
        if (field == "Coin 1") { bit = 0; return true; }
        if (field == "Coin 2") { bit = 1; return true; }
        if (field == "1 Player Start") { bit = 2; return true; }
        if (field == "2 Players Start") { bit = 3; return true; }
    }
    return false;
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    top = std::make_unique<Vtb_board>();
    std::string sd = plus("sdram", ""), out = plus("out", "."), capf = plus("cap", ""), iof = plus("io", "");
    int machine = atoi(plus("machine", plus("flagrall", "0").c_str()).c_str());
    unsigned dsw = (unsigned)strtoul(plus("dsw", machine ? "FFEF" : "FEEF").c_str(), nullptr, 16);
    long nframes = atol(plus("frames", "120").c_str());
    const int lines = machine ? 240 : 224;
    const size_t frame_px = 320 * (size_t)lines;
    long pause_f = -1, pause_n = 0;
    {
        std::string ps = plus("pause", "");
        if (!ps.empty()) sscanf(ps.c_str(), "%ld:%ld", &pause_f, &pause_n);
    }

    std::vector<uint8_t> img;
    {
        std::ifstream f(sd, std::ios::binary);
        if (!f) { fprintf(stderr, "cannot open +sdram=%s\n", sd.c_str()); return 2; }
        img.assign(std::istreambuf_iterator<char>(f), {});
    }
    size_t dlen = strtoull(plus("dlen", "0").c_str(), nullptr, 0);
    if (dlen == 0 || dlen > img.size()) dlen = img.size();
    std::set<long> cap;
    if (!capf.empty()) { std::ifstream c(capf); long n; while (c >> n) cap.insert(n); }
    std::multimap<long, std::tuple<int, int, int>> events;
    const int inlag = atoi(plus("inlag", "1").c_str());
    {
        std::string inf = plus("inputs", "");
        if (!inf.empty()) {
            std::ifstream f(inf);
            std::string ln;
            std::getline(f, ln);
            while (std::getline(f, ln)) {
                std::stringstream ss(ln);
                std::string fr, port, field, val;
                std::getline(ss, fr, ','); std::getline(ss, port, ',');
                std::getline(ss, field, ','); std::getline(ss, val, ',');
                int p, bit;
                if (!field_bit(port, field, p, bit)) { fprintf(stderr, "unknown input %s %s\n", port.c_str(), field.c_str()); return 2; }
                events.insert({atol(fr.c_str()) + inlag, {p, bit, atoi(val.c_str())}});
            }
        }
    }
    FILE *fio = iof.empty() ? nullptr : fopen(iof.c_str(), "w");

    uint16_t in_ports[2] = {0xFFFF, 0xFFFF};
    top->i_inputs = in_ports[0]; top->i_system = in_ports[1];
    top->i_pause = 0;
    top->i_volume = 0;
    top->i_reset = 1; top->i_sdram_rst_n = 0;
    for (int i = 0; i < 16; i++) tick();
    top->i_sdram_rst_n = 1;
    for (int i = 0; i < 256; i++) tick();

    auto download = [&](const std::vector<uint8_t> &im, size_t len, int mach, unsigned dw) {
        // as Main_MiSTer sends an MRA: index 1 (machine byte), the ROM
        // stream (index 0), then the DIP switches (index 254)
        uint64_t t = cyc;
        top->i_reset = 1;
        vphase = 0;
        top->i_ioctl_download = 1;
        send(1, 0, (uint8_t)mach);
        top->i_ioctl_download = 0;
        for (int i = 0; i < 64; i++) tick();
        top->i_ioctl_download = 1;
        for (size_t a = 0; a < len; a++) send(0, (uint32_t)a, im[a]);
        top->i_ioctl_download = 0;
        for (int i = 0; i < 64; i++) tick();
        top->i_ioctl_download = 1;
        send(254, 0, dw & 0xFF);
        send(254, 1, dw >> 8);
        top->i_ioctl_download = 0;
        for (int i = 0; i < 64; i++) tick();
        printf("download: machine %d, %zu bytes in %llu clocks\n", mach, len, (unsigned long long)(cyc - t));
        fflush(stdout);
        top->i_reset = 0;
    };
    {
        std::string fs = plus("first", "");
        if (!fs.empty()) {
            char path[512]; int fm = 0; unsigned fd = 0; long ff = 0;
            if (sscanf(fs.c_str(), "%511[^:]:%d:%x:%ld", path, &fm, &fd, &ff) != 4) { fprintf(stderr, "bad +first\n"); return 2; }
            std::ifstream f(path, std::ios::binary);
            std::vector<uint8_t> im((std::istreambuf_iterator<char>(f)), {});
            download(im, im.size(), fm, fd);
            long v = 0;
            while (v < ff) { tick(); if (top->o_vbl_irq) v++; }
            printf("first game ran %ld vblanks\n", v);
        }
    }
    download(img, dlen, machine, dsw);

    auto *r = top->rootp;
    std::vector<uint16_t> snap_bg(1024), snap_s0(2048), snap_s1(2048);
    bool snap_pending = false, seen_busy = false;
    long copies = 0, snap_bad = 0, snap_words_bad = 0;
    long frame = 0;
    std::vector<uint8_t> px;
    px.reserve(frame_px * 5);
    std::string wlog;
    long aud_bad = 0, aud_sat = 0;
    int aud_peak = 0, exp_audio = 0;
    bool have_exp = false;
    auto counters = [&](const char *tag) {
        printf("%s %ld overruns %u maxcyc %u romwr %u unmapped %u r8chi %u wcopy %u promlate %u "
               "cpu_maxlat %u ref_forced %u copies %ld snapbad %ld (%ld words)\n", tag, frame,
               (unsigned)top->o_dbg_overruns, (unsigned)top->o_dbg_maxcyc, (unsigned)top->o_dbg_rom_writes,
               (unsigned)top->o_dbg_unmapped, (unsigned)top->o_dbg_ram8c_hi, (unsigned)top->o_dbg_wstall,
               (unsigned)top->o_dbg_prom_late, (unsigned)top->o_dbg_cpu_maxlat, (unsigned)top->o_dbg_ref_forced,
               copies, snap_bad, snap_words_bad);
        printf("  audio: mismatches %ld, saturated clocks %ld, peak |o_audio| %d\n", aud_bad, aud_sat, aud_peak);
        fflush(stdout);
    };
    while (frame < nframes && !Verilated::gotFinish()) {
        bool ce = S(ce_pix);
        if (S(m_wstb)) {
            uint32_t ba = (uint32_t)S(m_a) << 1;
            bool uds = !S(m_udsn), lds = !S(m_ldsn);
            unsigned mask = (uds ? 0xFF00 : 0) | (lds ? 0x00FF : 0);
            unsigned d = S(m_dout);
            int line = S(u_video__DOT__vcnt), hp = S(u_video__DOT__hcnt);
            if (cap.count(frame) && ba >= 0x200000 && ba < 0x400000) {
                char b[64];
                snprintf(b, sizeof b, "%d %d %06x %04x %04x\n", line, hp, ba, d, mask);
                wlog += b;
            }
            if (fio && (ba == 0x340000 || ba == 0x380000 || ba == 0x3c0000 || ba == 0x4c0000 || ba == 0x500000))
                fprintf(fio, "%ld %d %d %06x %04x %04x\n", frame, line, hp, ba, d, mask);
        }
        tick();
        {
            int a = (int16_t)top->o_audio;
            if (have_exp && a != exp_audio) aud_bad++;
            if (a < 0 ? -a > aud_peak : a > aud_peak) aud_peak = a < 0 ? -a : a;
            auto sx14 = [](int v) { return ((v + 8192) & 16383) - 8192; };
            int gain = top->o_flagrall ? 12 : 48;
            int sum = gain * (sx14(S(u_oki1__DOT__u_acc__DOT__sum)) + sx14(S(u_oki2__DOT__u_acc__DOT__sum)));
            exp_audio = sum > 32767 ? 32767 : sum < -32768 ? -32768 : sum;
            if (exp_audio != sum) aud_sat++;
            have_exp = true;
        }
        if (S(copy)) {
            for (int i = 0; i < 1024; i++) snap_bg[i] = S(u_video__DOT__u_bg_live__DOT__mem)[i];
            for (int i = 0; i < 2048; i++) snap_s0[i] = S(u_video__DOT__u_s0_live__DOT__mem)[i];
            for (int i = 0; i < 2048; i++) snap_s1[i] = S(u_video__DOT__u_s1_live__DOT__mem)[i];
            snap_pending = true; seen_busy = false; copies++;
        } else if (snap_pending) {
            bool busy = S(u_video__DOT__cp_run) || S(u_video__DOT__cp_v1);
            if (busy) seen_busy = true;
            else if (seen_busy) {
                long bad = 0;
                for (int i = 0; i < 1024; i++) bad += snap_bg[i] != S(u_video__DOT__u_bg_buf__DOT__mem)[i];
                for (int i = 0; i < 2048; i++) bad += snap_s0[i] != S(u_video__DOT__u_s0_buf__DOT__mem)[i];
                for (int i = 0; i < 2048; i++) bad += snap_s1[i] != S(u_video__DOT__u_s1_buf__DOT__mem)[i];
                if (bad) { snap_bad++; snap_words_bad += bad; fprintf(stderr, "copy snapshot mismatch frame %ld: %ld words\n", frame, bad); }
                snap_pending = false;
            }
        }
        if (ce && top->o_de) {
            px.push_back(top->o_r); px.push_back(top->o_g); px.push_back(top->o_b);
            px.push_back(top->o_pen & 0xFF); px.push_back(top->o_pen >> 8);
        }
        if (top->o_vbl_irq) {
            if (frame > 0 && cap.count(frame)) {
                char fn[512];
                snprintf(fn, sizeof fn, "%s/%06ld.rgbp", out.c_str(), frame);
                if (px.size() != frame_px * 5) fprintf(stderr, "frame %ld: %zu pixels\n", frame, px.size() / 5);
                dump(fn, px.data(), px.size());
                snprintf(fn, sizeof fn, "%s/%06ld.wlog", out.c_str(), frame);
                dump(fn, wlog.data(), wlog.size());
            }
            wlog.clear();
            px.clear();
            frame++;
            for (auto it = events.lower_bound(frame); it != events.upper_bound(frame); ++it) {
                auto [p, bit, v] = it->second;
                if (v) in_ports[p] &= ~(1u << bit); else in_ports[p] |= 1u << bit;
            }
            top->i_inputs = in_ports[0];
            top->i_system = in_ports[1];
            top->i_pause = pause_f >= 0 && frame >= pause_f && frame < pause_f + pause_n;
            if (cap.count(frame)) {
                std::string base = out + "/" + std::to_string(1000000 + frame).substr(1);
                dumpw(base + ".pal", S(u_video__DOT__u_pal__DOT__mem), 512);
                dumpw(base + ".bgl", S(u_video__DOT__u_bg_live__DOT__mem), 1024);
                dumpw(base + ".bgb", S(u_video__DOT__u_bg_buf__DOT__mem), 1024);
                dumpw(base + ".s0l", S(u_video__DOT__u_s0_live__DOT__mem), 2048);
                dumpw(base + ".s1l", S(u_video__DOT__u_s1_live__DOT__mem), 2048);
                dumpw(base + ".s0b", S(u_video__DOT__u_s0_buf__DOT__mem), 2048);
                dumpw(base + ".s1b", S(u_video__DOT__u_s1_buf__DOT__mem), 2048);
                dumpw(base + ".ram", S(u_ram__DOT__mem), 32768);
                if (!machine) dumpw(base + ".r8c", S(u_ram8c__DOT__mem), 2048);
            }
            if (frame % 500 == 0) counters("vblank");
        }
    }
    counters("DONE vblanks");
    printf("cycles %llu\n", (unsigned long long)cyc);
    if (fio) fclose(fio);
    top->final();
    fflush(stdout);
    _exit(0);
}
