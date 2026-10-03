#include "Vjt6295.h"
#include "verilated.h"
#include <cstdio>
#include <fstream>
#include <vector>
std::vector<uint8_t> rom; Vjt6295 *t; uint64_t clk=0, cen_n=0; int bank=1;
void tick(){ t->cen=(clk%96)==0; t->rom_data=rom[(size_t)bank*0x40000+t->rom_addr]; t->rom_ok=1; t->clk=0;t->eval();t->clk=1;t->eval(); if(t->cen)cen_n++; clk++; }
void run(int n){ for(int i=0;i<n;i++) tick(); }
void wr(int v){ t->din=v; t->wrn=0; tick(); t->wrn=1; tick(); }
int main(int argc,char**argv){
  std::ifstream f(argv[1],std::ios::binary); rom.assign(std::istreambuf_iterator<char>(f),{});
  t=new Vjt6295; t->rst=1;t->ss=1;t->wrn=1; run(1000); t->rst=0; run(100000);
  long mn=1e9,mx=0, smn=1e9,smx=0;
  for(int d=0; d<132; d+=7){
    run(96*d); wr(0x80|25); run(96*30); wr(0x10); uint64_t c0=cen_n; while(!(t->dout&1)) tick(); long up=cen_n-c0; if(up<mn)mn=up; if(up>mx)mx=up;
    run(96*3000); wr(0x08); c0=cen_n; while(t->dout&1) tick(); long dn=cen_n-c0; if(dn<smn)smn=dn; if(dn>smx)smx=dn; run(96*300);
  }
  printf("BUSY rise after start 2nd byte: %ld..%ld clocks (datasheet 15 x n = 60)\n",mn,mx);
  printf("BUSY fall after stop: %ld..%ld clocks (datasheet: next sample, 0..132)\n",smn,smx);
}
