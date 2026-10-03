// jt6295 busy-duration probe (m2_findings 5.3): start one phrase on one
// channel and count 1 MHz enables until its busy bit clears; the nominal
// MSM6295 length is 2 * (end - start + 1) samples of 132 enables (pin 7 high).
// Usage: tb_oki <oki rom .bin> <bank> <phrase> <channel 0-3>
#include "Vjt6295.h"
#include "Vjt6295___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <vector>
int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    std::ifstream f(argv[1], std::ios::binary);
    std::vector<uint8_t> rom((std::istreambuf_iterator<char>(f)), {});
    int bank = atoi(argv[2]), ph = atoi(argv[3]), ch = atoi(argv[4]);
    Vjt6295 t;
    const int DIV = 96;                      // 96 MHz clock, 1 MHz cen
    uint64_t clk = 0, cen_n = 0;
    auto tick = [&]() {
        t.cen = (clk % DIV) == 0;
        t.rom_data = rom[(size_t)bank * 0x40000 + t.rom_addr];
        t.rom_ok = 1;
        t.clk = 0; t.eval(); t.clk = 1; t.eval();
        if (t.cen) cen_n++;
        clk++;
    };
    t.rst = 1; t.ss = 1; t.wrn = 1; t.din = 0;
    for (int i = 0; i < 1000; i++) tick();
    t.rst = 0;
    for (int i = 0; i < 100000; i++) tick();
    auto wr = [&](int v) { t.din = v; t.wrn = 0; tick(); t.wrn = 1; for (int i = 0; i < 2000; i++) tick(); };
    wr(0x80 | ph);
    uint64_t c0 = cen_n;
    wr((0x10 << ch) | 0);
    uint64_t c_wr = cen_n;
    int bit = 1 << ch;
    uint64_t c_busy = 0;
    while ((t.dout & bit) == 0 && cen_n - c_wr < 100000) tick();
    c_busy = cen_n;
    while ((t.dout & bit) != 0) tick();
    uint64_t c_end = cen_n;
    const uint8_t *e = &rom[(size_t)bank * 0x40000 + ph * 8];
    long st = ((e[0] & 3) << 16) | (e[1] << 8) | e[2], en = ((e[3] & 3) << 16) | (e[4] << 8) | e[5];
    long nominal = 2 * (en - st + 1) * 132;
    printf("phrase %d: start %#lx end %#lx; status busy %llu enables after the start write; busy for %llu enables (end - write %llu); nominal %ld (2 x %ld bytes x 132); difference %lld enables = %.2f samples\n",
           ph, st, en, (unsigned long long)(c_busy - c_wr), (unsigned long long)(c_end - c_busy),
           (unsigned long long)(c_end - c_wr), nominal, en - st + 1,
           (long long)(c_end - c_wr) - nominal, ((double)((long long)(c_end - c_wr) - nominal)) / 132.0);
    (void)c0;
    return 0;
}
