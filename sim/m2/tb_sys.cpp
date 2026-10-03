// M2 full-system harness for k3_sys (Verilator, C++).
//
// Loads the set's sdram.bin (PLAN 4.3 layout: maincpu 0x000000, sprites
// 0x100000, tiles 0x500000, oki1 0x700000, oki2 0x800000), fills the sprite
// tile flags, resets and runs the system from power-on.
//
// Frame numbering: vblank N = the N-th o_vbl_irq (start of line 224, or 240
// on flagrall), the same instant as MAME's N-th frame notifier (the IRQ4
// assert follows it, k3_oracle.lua). Displayed frame N = the pixels scanned
// out between vblank N and N+1 (MAME's frame N+1).
//
// Outputs in +out=DIR for every frame number in +cap=FILE:
//   NNNNNN.rgbp   displayed frame N: 320 x lines x 5 (R, G, B, pen lo, pen hi)
//   NNNNNN.wlog   every CPU write to 0x200000-0x3fffff during displayed frame
//                 N: "line hpos addr data mask" (byte address of the word,
//                 data and lane mask as MAME's taps show them)
//   at vblank N, the oracle's byte order (16-bit words high byte first):
//   NNNNNN.pal (1 KB), .bgl / .bgb (tilemap live / buffer, 2 KB each),
//   .s0l .s1l / .s0b .s1b (sprite RAM live / buffers, 4 KB each),
//   .ram (work RAM 64 KB), .r8c (0x8c0000-0x8c0fff, k3 sets)
// Whole run: +io=FILE logs every write to scroll, control and the OKIs as
// "vblank line hpos addr data mask" (compared with MAME's writes.csv).
//
// Plusargs: +sdram=FILE +flagrall=0|1 +frames=N +cap=FILE +out=DIR
//   +dsw=HEX (16-bit DSW, active low; MAME default per set, spec 11)
//   +inputs=FILE: the oracle's inputs.csv (frame,port,field,value), each
//   event applied at vblank frame + inlag (value 1 = pressed). +inlag=N,
//   default 1: an event the oracle sets from its frame notifier N reaches the
//   game's port reads one frame later (MAME latches input field values at
//   its next input frame update; m2_findings 3, the gameplay coin response
//   lands on frame 607 for an event logged at 606)
//   graphics ROM model as m1/tb_video.cpp: +intv=N (default 8) +lat=N (9)
//   +okilat=N: clocks of latency after each OKI ROM address change (8)
//   +promlat=N: program ROM latency, clocks from request to ok (default 9)
//   +pause=F:N: hold i_pause high for N frames from vblank F (pause test)

#include "Vk3_sys.h"
#include "Vk3_sys___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <fstream>
#include <map>
#include <memory>
#include <set>
#include <sstream>
#include <string>
#include <unistd.h>
#include <vector>

static std::unique_ptr<Vk3_sys> top;
static std::vector<uint8_t> sdram;
static int lat = 9, intv = 8, okilat = 8;
static uint64_t cycles = 0, last_acc = 0;
struct Resp { uint64_t t; uint32_t d; };
static std::deque<Resp> rq;
static uint32_t prom_last = 0xFFFFFFFF;
static int prom_cnt = 0;
static uint32_t o1_last = 0xFFFFFFFF, o2_last = 0xFFFFFFFF;
static int o1_cnt = 0, o2_cnt = 0;

static uint8_t sd(size_t a) { return a < sdram.size() ? sdram[a] : 0; }
static uint32_t rd32(uint32_t a) {
    uint32_t v = 0;
    for (int i = 0; i < 4; i++) v = (v << 8) | sd(a + i);
    return v;
}

static int promlat = 9;
static void tick() {
    // program ROM: ok (and the word) +promlat clocks after the request
    // rises (the M4 SDRAM controller answers in 8-9 clocks at 96 MHz); the
    // data bus carries garbage before ok, so a word captured too early shows
    if (top->o_prom_req) {
        uint32_t a = top->o_prom_addr;
        if (a != prom_last) { prom_last = a; prom_cnt = 0; }
        else if (prom_cnt < promlat) prom_cnt++;
        bool ok = prom_cnt >= promlat;
        top->i_prom_data = ok ? (sd(2 * (size_t)a) << 8) | sd(2 * (size_t)a + 1) : 0xDEAD;
        top->i_prom_ok = ok;
    } else {
        prom_last = 0xFFFFFFFF;
        top->i_prom_ok = 0;
    }
    uint32_t a1 = top->o_oki1_addr, a2 = top->o_oki2_addr;
    if (a1 != o1_last) { o1_last = a1; o1_cnt = 0; } else if (o1_cnt < okilat) o1_cnt++;
    if (a2 != o2_last) { o2_last = a2; o2_cnt = 0; } else if (o2_cnt < okilat) o2_cnt++;
    top->i_oki1_data = sd(0x700000 + a1);
    top->i_oki1_ok = o1_cnt >= okilat;
    top->i_oki2_data = sd(0x800000 + a2);
    top->i_oki2_ok = o2_cnt >= okilat;
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

static std::string plus(const char *name, const char *def) {
    const char *v = Verilated::commandArgsPlusMatch(name);
    if (!v || !*v) return def;
    const char *eq = strchr(v, '=');
    return eq ? std::string(eq + 1) : std::string(def);
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

// inputs.csv field names -> (port 0 INPUTS / 1 SYSTEM, bit)
static bool field_bit(const std::string &port, const std::string &field, int &p, int &bit) {
    static const char *dir[4] = {"Up", "Down", "Left", "Right"};
    if (port == "INPUTS") {
        p = 0;
        for (int pl = 1; pl <= 2; pl++) {
            std::string pre = "P" + std::to_string(pl) + " ";
            if (field.compare(0, pre.size(), pre) != 0) continue;
            std::string r = field.substr(pre.size());
            for (int d = 0; d < 4; d++) if (r == dir[d]) { bit = (pl - 1) * 8 + d; return true; }
            if (r.compare(0, 7, "Button ") == 0) { bit = (pl - 1) * 8 + 4 + (r[7] - '1'); return true; }
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
    top = std::make_unique<Vk3_sys>();
    std::string sdf = plus("sdram", ""), out = plus("out", "."), capf = plus("cap", "");
    long nframes = atol(plus("frames", "600").c_str());
    lat = atoi(plus("lat", "9").c_str());
    intv = atoi(plus("intv", "8").c_str());
    okilat = atoi(plus("okilat", "8").c_str());
    promlat = atoi(plus("promlat", "9").c_str());
    long pause_f = -1, pause_n = 0;
    {
        std::string ps = plus("pause", "");
        if (!ps.empty()) sscanf(ps.c_str(), "%ld:%ld", &pause_f, &pause_n);
    }
    top->i_pause = 0;
    const int flag = atoi(plus("flagrall", "0").c_str());
    const int lines = flag ? 240 : 224;
    const size_t frame_px = 320 * (size_t)lines;
    std::string iof = plus("io", "");
    // +pctrace=F0:F1:FILE: every program-space read (opcode and extension
    // fetches) from vblank F0 to F1 as "frame line hpos addr"
    long tr_f0 = -1, tr_f1 = -1;
    char tr_file[512] = {0};
    {
        std::string ts = plus("pctrace", "");
        if (!ts.empty()) sscanf(ts.c_str(), "%ld:%ld:%511s", &tr_f0, &tr_f1, tr_file);
    }
    FILE *ftr = tr_f0 >= 0 ? fopen(tr_file, "w") : nullptr;
    bool tr_as_prev = true;
    unsigned wt_lo = 0, wt_hi = 0;
    char wt_file[512] = {0};
    {
        std::string ws = plus("wtap", "");
        if (!ws.empty()) sscanf(ws.c_str(), "%x:%x:%511s", &wt_lo, &wt_hi, wt_file);
    }
    FILE *fwt = wt_file[0] ? fopen(wt_file, "w") : nullptr;
    std::string okf = plus("okird", "");         // +okird=FILE: "vblank line hpos addr data" per OKI status read
    FILE *fok = okf.empty() ? nullptr : fopen(okf.c_str(), "w");
    bool okrd_prev = false;
    std::string iaf = plus("iack", "");          // +iack=FILE: "vblank line hpos clocks" per IRQ acknowledge
    FILE *fia = iaf.empty() ? nullptr : fopen(iaf.c_str(), "w");
    bool iack_prev = false;
    uint64_t iack_t0 = 0;
    int iack_line = 0, iack_h = 0;
    FILE *fio = iof.empty() ? nullptr : fopen(iof.c_str(), "w");
    {
        std::ifstream f(sdf, std::ios::binary);
        if (!f) { fprintf(stderr, "cannot open sdram %s\n", sdf.c_str()); return 2; }
        sdram.assign(std::istreambuf_iterator<char>(f), {});
    }
    std::set<long> cap;
    if (!capf.empty()) {
        std::ifstream f(capf);
        long n;
        while (f >> n) cap.insert(n);
    }
    // input events: frame -> list of (port, bit, pressed)
    std::multimap<long, std::tuple<int, int, int>> events;
    const int inlag = atoi(plus("inlag", "1").c_str());
    {
        std::string inf = plus("inputs", "");
        if (!inf.empty()) {
            std::ifstream f(inf);
            std::string ln;
            std::getline(f, ln);                       // header
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
    uint16_t in_ports[2] = {0xFFFF, 0xFFFF};
    top->i_flagrall = flag;
    top->i_inputs = in_ports[0];
    top->i_system = in_ports[1];
    top->i_dsw = strtol(plus("dsw", "FFEF").c_str(), nullptr, 16);
    top->rst_n = 0;
    top->i_tflag_we = 0;
    for (int i = 0; i < 16; i++) tick();
    {   // sprite tile flags, as m1/tb_video.cpp (the M4 loader computes them)
        const int ntiles = flag ? 12288 : 16384;
        for (int w = 0; w < 1024; w++) {
            uint16_t v = 0;
            for (int b = 0; b < 16; b++) {
                int t = w * 16 + b;
                if (t >= ntiles) continue;
                size_t base = 0x100000 + (size_t)t * 256;
                bool any = false;
                for (int k = 0; k < 256 && !any; k++) any = sd(base + k);
                if (any) v |= 1u << b;
            }
            top->i_tflag_addr = w; top->i_tflag_din = v; top->i_tflag_we = 1;
            tick();
        }
        top->i_tflag_we = 0;
    }
    for (int i = 0; i < 16; i++) tick();
    top->rst_n = 1;

    auto *r = top->rootp;
    // copy snapshot self-check: the CPU-side tile/sprite RAMs at the copy
    // pulse must equal the buffers when the copy completes (MAME's instant
    // copy; k3_video copy-before-write)
    std::vector<uint16_t> snap_bg(1024), snap_s0(2048), snap_s1(2048);
    bool snap_pending = false, seen_busy = false;
    long copies = 0, snap_bad = 0, snap_words_bad = 0;
    long frame = 0;                                // vblanks seen
    std::vector<uint8_t> px;
    px.reserve(frame_px * 5);
    std::string wlog;
    while (frame < nframes) {
        bool ce = r->k3_sys__DOT__ce_pix;          // enable going into this edge
        if (r->k3_sys__DOT__m_wstb) {
            uint32_t ba = (uint32_t)r->k3_sys__DOT__m_a << 1;
            bool uds = !r->k3_sys__DOT__m_udsn, lds = !r->k3_sys__DOT__m_ldsn;
            unsigned mask = (uds ? 0xFF00 : 0) | (lds ? 0x00FF : 0);
            unsigned d = r->k3_sys__DOT__m_dout;
            int line = r->k3_sys__DOT__u_video__DOT__vcnt, hp = r->k3_sys__DOT__u_video__DOT__hcnt;
            if (cap.count(frame) && ba >= 0x200000 && ba < 0x400000) {
                char b[64];
                snprintf(b, sizeof b, "%d %d %06x %04x %04x\n", line, hp, ba, d, mask);
                wlog += b;
            }
            if (fio && (ba == 0x340000 || ba == 0x380000 || ba == 0x3c0000 || ba == 0x4c0000 || ba == 0x500000))
                fprintf(fio, "%ld %d %d %06x %04x %04x\n", frame, line, hp, ba, d, mask);
        }
        if (fia) {
            bool ia = r->k3_sys__DOT__m_iack;
            if (ia && !iack_prev) { iack_t0 = cycles; iack_line = r->k3_sys__DOT__u_video__DOT__vcnt; iack_h = r->k3_sys__DOT__u_video__DOT__hcnt; }
            if (!ia && iack_prev) fprintf(fia, "%ld %d %d %llu\n", frame, iack_line, iack_h, (unsigned long long)(cycles - iack_t0));
            iack_prev = ia;
        }
        if (fok) {   // OKI 1 busy-bit changes, same file
            static int bprev = -1;
            int b = r->k3_sys__DOT__u_oki1__DOT__busy;
            if (b != bprev) fprintf(fok, "B %ld %d %d %x\n", frame, r->k3_sys__DOT__u_video__DOT__vcnt,
                                    r->k3_sys__DOT__u_video__DOT__hcnt, b);
            bprev = b;
        }
        if (fwt && r->k3_sys__DOT__m_wstb) {   // +wtap=LO:HI:FILE
            uint32_t ba = (uint32_t)r->k3_sys__DOT__m_a << 1;
            if (ba >= wt_lo && ba <= wt_hi) {
                unsigned mask = (!r->k3_sys__DOT__m_udsn ? 0xFF00 : 0) | (!r->k3_sys__DOT__m_ldsn ? 0x00FF : 0);
                fprintf(fwt, "%ld %d %d %06x %04x %04x %06x\n", frame, r->k3_sys__DOT__u_video__DOT__vcnt,
                        r->k3_sys__DOT__u_video__DOT__hcnt, ba, (unsigned)r->k3_sys__DOT__m_dout, mask, top->o_cpu_pc_dbg);
            }
        }
        if (ftr && frame >= tr_f0 && frame < tr_f1) {
            bool as = r->k3_sys__DOT__m_asn_pub;
            if (!as && tr_as_prev && r->k3_sys__DOT__m_fc_prog && r->k3_sys__DOT__m_rw)
                fprintf(ftr, "%ld %d %d %06x\n", frame, r->k3_sys__DOT__u_video__DOT__vcnt,
                        r->k3_sys__DOT__u_video__DOT__hcnt, (unsigned)r->k3_sys__DOT__m_a << 1);
            tr_as_prev = as;
        }
        bool okrd_now = fok && r->k3_sys__DOT__m_rd_oki;
        int ok_line = r->k3_sys__DOT__u_video__DOT__vcnt, ok_h = r->k3_sys__DOT__u_video__DOT__hcnt;
        uint32_t ok_a = (uint32_t)r->k3_sys__DOT__m_a << 1;
        tick();
        if (fok && okrd_prev) {}
        if (okrd_now) fprintf(fok, "%ld %d %d %06x %04x\n", frame, ok_line, ok_h, ok_a, r->k3_sys__DOT__m_rdata);
        okrd_prev = okrd_now;
        if (r->k3_sys__DOT__copy) {
            // the copy engine starts next clock; the live RAMs now hold every
            // write before the copy edge
            for (int i = 0; i < 1024; i++) snap_bg[i] = r->k3_sys__DOT__u_video__DOT__u_bg_live__DOT__mem[i];
            for (int i = 0; i < 2048; i++) snap_s0[i] = r->k3_sys__DOT__u_video__DOT__u_s0_live__DOT__mem[i];
            for (int i = 0; i < 2048; i++) snap_s1[i] = r->k3_sys__DOT__u_video__DOT__u_s1_live__DOT__mem[i];
            snap_pending = true;
            seen_busy = false;
            copies++;
        } else if (snap_pending) {
            bool busy = r->k3_sys__DOT__u_video__DOT__cp_run || r->k3_sys__DOT__u_video__DOT__cp_v1;
            if (busy) seen_busy = true;
            else if (seen_busy) {
                long bad = 0;
                for (int i = 0; i < 1024; i++) bad += snap_bg[i] != r->k3_sys__DOT__u_video__DOT__u_bg_buf__DOT__mem[i];
                for (int i = 0; i < 2048; i++) bad += snap_s0[i] != r->k3_sys__DOT__u_video__DOT__u_s0_buf__DOT__mem[i];
                for (int i = 0; i < 2048; i++) bad += snap_s1[i] != r->k3_sys__DOT__u_video__DOT__u_s1_buf__DOT__mem[i];
                if (bad) { snap_bad++; snap_words_bad += bad; fprintf(stderr, "copy snapshot mismatch frame %ld: %ld words\n", frame, bad); }
                snap_pending = false;
            }
        }
        if (ce && top->o_de) {
            px.push_back(top->o_r);
            px.push_back(top->o_g);
            px.push_back(top->o_b);
            px.push_back(top->o_pen & 0xFF);
            px.push_back(top->o_pen >> 8);
        }
        if (top->o_vbl_irq) {
            if (frame > 0 && cap.count(frame)) {
                char fn[96];
                snprintf(fn, sizeof fn, "%s/%06ld.rgbp", out.c_str(), frame);
                if (px.size() != frame_px * 5)
                    fprintf(stderr, "frame %ld: %zu pixels\n", frame, px.size() / 5);
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
                char fn[96];
                std::string base = out + "/" + std::to_string(1000000 + frame).substr(1);
                dumpw(base + ".pal", r->k3_sys__DOT__u_video__DOT__u_pal__DOT__mem, 512);
                dumpw(base + ".bgl", r->k3_sys__DOT__u_video__DOT__u_bg_live__DOT__mem, 1024);
                dumpw(base + ".bgb", r->k3_sys__DOT__u_video__DOT__u_bg_buf__DOT__mem, 1024);
                dumpw(base + ".s0l", r->k3_sys__DOT__u_video__DOT__u_s0_live__DOT__mem, 2048);
                dumpw(base + ".s1l", r->k3_sys__DOT__u_video__DOT__u_s1_live__DOT__mem, 2048);
                dumpw(base + ".s0b", r->k3_sys__DOT__u_video__DOT__u_s0_buf__DOT__mem, 2048);
                dumpw(base + ".s1b", r->k3_sys__DOT__u_video__DOT__u_s1_buf__DOT__mem, 2048);
                dumpw(base + ".ram", r->k3_sys__DOT__u_ram__DOT__mem, 32768);
                if (!flag) dumpw(base + ".r8c", r->k3_sys__DOT__u_ram8c__DOT__mem, 2048);
                (void)fn;
            }
            if (frame % 500 == 0) {
                printf("vblank %ld pc %06x overruns %d maxcyc %d romwr %d unmapped %d r8chi %d wcopy %d copies %ld snapbad %ld promlate %d\n", frame,
                       top->o_cpu_pc_dbg, top->o_dbg_overruns, top->o_dbg_maxcyc, top->o_dbg_rom_writes,
                       top->o_dbg_unmapped, top->o_dbg_ram8c_hi, top->o_dbg_wstall, copies, snap_bad,
                       top->o_dbg_prom_late);
                fflush(stdout);
            }
        }
    }
    printf("DONE vblanks %ld cycles %llu overruns %d maxcyc %d romwr %d unmapped %d r8chi %d wcopy %d copies %ld snapbad %ld (%ld words) promlate %d\n", frame,
           (unsigned long long)cycles, top->o_dbg_overruns, top->o_dbg_maxcyc, top->o_dbg_rom_writes,
           top->o_dbg_unmapped, top->o_dbg_ram8c_hi, top->o_dbg_wstall, copies, snap_bad, snap_words_bad,
           top->o_dbg_prom_late);
    if (fio) fclose(fio);
    if (fia) fclose(fia);
    if (fok) fclose(fok);
    if (ftr) fclose(ftr);
    if (fwt) fclose(fwt);
    top->final();
    top.reset();
    fflush(stdout);
    _exit(0);
}
