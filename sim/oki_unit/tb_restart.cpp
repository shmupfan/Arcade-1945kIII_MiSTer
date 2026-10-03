#include "Vjt6295.h"
#include "verilated.h"
#include <cstdio>
#include <fstream>
#include <vector>
std::vector<uint8_t> rom; Vjt6295 *t; uint64_t clk=0, cen_n=0; int bank=1;
void tick(){ t->cen=(clk%96)==0; t->rom_data=rom[(size_t)bank*0x40000+t->rom_addr]; t->rom_ok=1; t->clk=0;t->eval();t->clk=1;t->eval(); if(t->cen)cen_n++; clk++; }
void run(int n){ for(int i=0;i<n;i++) tick(); }
void wr(int v){ t->din=v; t->wrn=0; tick(); t->wrn=1; for(int i=0;i<1150;i++) tick(); } // ~12 us between writes, as Ginkun
long nominal(int ph){ const uint8_t*e=&rom[(size_t)bank*0x40000+ph*8]; long s=((e[0]&3)<<16)|(e[1]<<8)|e[2], en=((e[3]&3)<<16)|(e[4]<<8)|e[5]; return 2*(en-s+1)*132; }
int main(int argc,char**argv){
  std::ifstream f(argv[1],std::ios::binary); rom.assign(std::istreambuf_iterator<char>(f),{});
  t=new Vjt6295; t->rst=1;t->ss=1;t->wrn=1; run(1000); t->rst=0; run(100000);
  for(int delay=0; delay<264; delay+=37){
    wr(0x80|25); wr(0x10); run(96*3000+delay*96);       // long phrase 25 on ch0
    wr(0x08); wr(0x80|1); wr(0x11); wr(0x80|1); wr(0x11);  // Ginkun: stop, start ph1 att1, start again
    uint64_t c0=cen_n; {uint64_t w=cen_n; while(!(t->dout&1) && cen_n-w<1000) tick();} while(t->dout&1) tick();
    long d=(long)(cen_n-c0)-nominal(1);
    printf("delay %3d: ch0 played %llu enables after the restart, phrase 1 nominal %ld, diff %ld (%s)\n",delay,(unsigned long long)(cen_n-c0),nominal(1),d, (d>-2000&&d<2000)?"new phrase":"WRONG");
    run(96*500);
  }
}
