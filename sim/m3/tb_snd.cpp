// M3 sound harness for k3_sys (Verilator, C++). Same system, ROM models and
// input replay as m2/tb_sys.cpp, without the video captures; records both
// M6295 outputs at their own sample rate.
//
//   +oki=FILE  one record per OKI 1 sample (cen_sr, 1 MHz / 132): two
//              little-endian int16, OKI 1 then OKI 2 (jt6295 "sound": the sum
//              of the four channels in 12-bit units, MAME's 1/2048 of full
//              scale). OKI 2 samples on the same enable (both chips share
//              the OKI enable and leave reset together; checked every sample)
//   +okich=FILE per channel: at each 4x-rate enable of each chip, the
//              attenuated channel value the accumulator adds (12-bit units),
//              grouped per sample: int16 OKI 1 slots 0-3, OKI 2 slots 0-3
//              (slot = position in the chip's channel sequence; a group
//              starts at the enable where the accumulator reloads)
//   +okibusy=FILE every change of a chip's four busy bits: "sample chip busy"
//              (sample = index in the +oki stream, chip 1 or 2, busy hex)
//   +io=FILE   writes to scroll, control and the OKIs, as m2/tb_sys.cpp
//   +sdram +flagrall +frames +dsw +inputs +inlag +okilat +promlat as m2/tb_sys.cpp
// Build parameter OKI_HZ (simulation diagnostics only): 999900 gives MAME
// 0.288's effective M6295 rate (7,575 Hz, m2_findings 5.3), so samples can
// be compared one for one with MAME's WAV at -samplerate 7575.
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
#include <sstream>
#include <string>
#include <tuple>
#include <unistd.h>
#include <vector>

static std::unique_ptr<Vk3_sys> top;
static std::vector<uint8_t> sdram;
static int lat = 9, intv = 8, okilat = 8, promlat = 9;
static uint64_t cycles = 0, last_acc = 0;
struct Resp { uint64_t t; uint32_t d; };
static std::deque<Resp> rq;
static uint32_t prom_last = 0xFFFFFFFF, o1_last = 0xFFFFFFFF, o2_last = 0xFFFFFFFF;
static int prom_cnt = 0, o1_cnt = 0, o2_cnt = 0;

static uint8_t sd(size_t a) { return a < sdram.size() ? sdram[a] : 0; }
static uint32_t rd32(uint32_t a) { uint32_t v = 0; for (int i = 0; i < 4; i++) v = (v << 8) | sd(a + i); return v; }

static void tick() {
    if (top->o_prom_req) {
        uint32_t a = top->o_prom_addr;
        if (a != prom_last) { prom_last = a; prom_cnt = 0; } else if (prom_cnt < promlat) prom_cnt++;
        bool ok = prom_cnt >= promlat;
        top->i_prom_data = ok ? (sd(2 * (size_t)a) << 8) | sd(2 * (size_t)a + 1) : 0xDEAD;
        top->i_prom_ok = ok;
    } else { prom_last = 0xFFFFFFFF; top->i_prom_ok = 0; }
    uint32_t a1 = top->o_oki1_addr, a2 = top->o_oki2_addr;
    if (a1 != o1_last) { o1_last = a1; o1_cnt = 0; } else if (o1_cnt < okilat) o1_cnt++;
    if (a2 != o2_last) { o2_last = a2; o2_cnt = 0; } else if (o2_cnt < okilat) o2_cnt++;
    top->i_oki1_data = sd(0x700000 + a1); top->i_oki1_ok = o1_cnt >= okilat;
    top->i_oki2_data = sd(0x800000 + a2); top->i_oki2_ok = o2_cnt >= okilat;
    bool rv = !rq.empty() && rq.front().t <= cycles;
    top->i_rom_rv = rv;
    if (rv) { top->i_rom_data = rq.front().d; rq.pop_front(); }
    bool gnt = cycles - last_acc >= (uint64_t)intv;
    top->i_rom_gnt = gnt;
    top->clk = 0; top->eval();
    if (gnt && top->o_rom_req) { rq.push_back({cycles + (uint64_t)lat, rd32(top->o_rom_addr)}); last_acc = cycles; }
    top->clk = 1; top->eval();
    cycles++;
}

static std::string plus(const char *name, const char *def) {
    const char *v = Verilated::commandArgsPlusMatch(name);
    if (!v || !*v) return def;
    const char *eq = strchr(v, '=');
    return eq ? std::string(eq + 1) : std::string(def);
}

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
    std::string sdf = plus("sdram", "");
    long nframes = atol(plus("frames", "600").c_str());
    okilat = atoi(plus("okilat", "8").c_str());
    promlat = atoi(plus("promlat", "9").c_str());
    const int flag = atoi(plus("flagrall", "0").c_str());
    std::string okf = plus("oki", ""), iof = plus("io", "");
    FILE *fok = okf.empty() ? nullptr : fopen(okf.c_str(), "wb");
    FILE *fio = iof.empty() ? nullptr : fopen(iof.c_str(), "w");
    std::string bsf = plus("okibusy", "");
    FILE *fbs = bsf.empty() ? nullptr : fopen(bsf.c_str(), "w");
    int bprev1 = -1, bprev2 = -1;
    std::string chf = plus("okich", "");
    FILE *fch = chf.empty() ? nullptr : fopen(chf.c_str(), "wb");
    int16_t grp[8] = {0};
    int slot1 = -1, slot2 = -1;
    std::vector<int16_t> cbuf;
    {
        std::ifstream f(sdf, std::ios::binary);
        if (!f) { fprintf(stderr, "cannot open sdram %s\n", sdf.c_str()); return 2; }
        sdram.assign(std::istreambuf_iterator<char>(f), {});
    }
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
    uint16_t in_ports[2] = {0xFFFF, 0xFFFF};
    top->i_pause = 0;
    top->i_flagrall = flag;
    top->i_inputs = in_ports[0];
    top->i_system = in_ports[1];
    top->i_dsw = strtol(plus("dsw", "FFEF").c_str(), nullptr, 16);
    top->rst_n = 0;
    top->i_tflag_we = 0;
    for (int i = 0; i < 16; i++) tick();
    {
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
    long frame = 0, samples = 0, phase_bad = 0;
    bool pend = false;
    std::vector<int16_t> buf;
    buf.reserve(1 << 16);
    while (frame < nframes) {
        if (fio && r->k3_sys__DOT__m_wstb) {
            uint32_t ba = (uint32_t)r->k3_sys__DOT__m_a << 1;
            if (ba == 0x340000 || ba == 0x380000 || ba == 0x3c0000 || ba == 0x4c0000 || ba == 0x500000) {
                unsigned mask = (!r->k3_sys__DOT__m_udsn ? 0xFF00 : 0) | (!r->k3_sys__DOT__m_ldsn ? 0x00FF : 0);
                fprintf(fio, "%ld %d %d %06x %04x %04x\n", frame, r->k3_sys__DOT__u_video__DOT__vcnt,
                        r->k3_sys__DOT__u_video__DOT__hcnt, ba, (unsigned)r->k3_sys__DOT__m_dout, mask);
            }
        }
        tick();
        if (pend) {   // the accumulator's "sum" loaded on the enable; take it a clock later
            if (fok) {
                buf.push_back((int16_t)(((top->o_oki1 + 8192) & 16383) - 8192));   // 14-bit signed
                buf.push_back((int16_t)(((top->o_oki2 + 8192) & 16383) - 8192));
                if (buf.size() >= (1 << 16)) { fwrite(buf.data(), 2, buf.size(), fok); buf.clear(); }
            }
            samples++;
            pend = false;
        }
        bool c1 = r->k3_sys__DOT__u_oki1__DOT__cen_sr, c2 = r->k3_sys__DOT__u_oki2__DOT__cen_sr;
        if (fbs) {
            int b1 = r->k3_sys__DOT__u_oki1__DOT__busy, b2 = r->k3_sys__DOT__u_oki2__DOT__busy;
            if (b1 != bprev1) { fprintf(fbs, "%ld 1 %x\n", samples, b1); bprev1 = b1; }
            if (b2 != bprev2) { fprintf(fbs, "%ld 2 %x\n", samples, b2); bprev2 = b2; }
        }
        if (fch) {   // values the accumulators take on the next edge
            auto sx = [](int v) { return (int16_t)(((v + 2048) & 4095) - 2048); };
            if (r->k3_sys__DOT__u_oki1__DOT__cen_sr4) {
                if (c1) {
                    if (slot1 >= 0) { cbuf.insert(cbuf.end(), grp, grp + 8); if (cbuf.size() >= (1 << 16)) { fwrite(cbuf.data(), 2, cbuf.size(), fch); cbuf.clear(); } }
                    slot1 = 0;
                }
                if (slot1 >= 0 && slot1 < 4) grp[slot1++] = sx(r->k3_sys__DOT__u_oki1__DOT__pipe_snd);
            }
            if (r->k3_sys__DOT__u_oki2__DOT__cen_sr4) {
                if (c2) slot2 = 0;
                if (slot2 >= 0 && slot2 < 4) grp[4 + slot2++] = sx(r->k3_sys__DOT__u_oki2__DOT__pipe_snd);
            }
        }
        if (c1 != c2) phase_bad++;
        if (c1) pend = true;
        if (top->o_vbl_irq) {
            frame++;
            for (auto it = events.lower_bound(frame); it != events.upper_bound(frame); ++it) {
                auto [p, bit, v] = it->second;
                if (v) in_ports[p] &= ~(1u << bit); else in_ports[p] |= 1u << bit;
            }
            top->i_inputs = in_ports[0];
            top->i_system = in_ports[1];
            if (frame % 500 == 0) { printf("vblank %ld samples %ld\n", frame, samples); fflush(stdout); }
        }
    }
    if (fok) { fwrite(buf.data(), 2, buf.size(), fok); fclose(fok); }
    if (fch) { fwrite(cbuf.data(), 2, cbuf.size(), fch); fclose(fch); }
    if (fbs) fclose(fbs);
    if (fio) fclose(fio);
    printf("DONE vblanks %ld cycles %llu samples %ld oki_phase_mismatch %ld\n", frame,
           (unsigned long long)cycles, samples, phase_bad);
    top->final();
    fflush(stdout);
    _exit(0);
}
