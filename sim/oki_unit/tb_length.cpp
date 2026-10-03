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
  int phs[]={1,5,9,12}; long mn=1e9,mx=-1e9;
  for(int k=0;k<4;k++) for(int d=0; d<132; d+=11){
    int ph=phs[k]; run(96*d); wr(0x80|ph); run(200); wr(0x10<<2); uint64_t c0=cen_n;
    {uint64_t w=cen_n; while(!(t->dout&4) && cen_n-w<1000) tick();}
    while(t->dout&4) tick();
    const uint8_t*e=&rom[(size_t)bank*0x40000+ph*8]; long s=((e[0]&3)<<16)|(e[1]<<8)|e[2], en=((e[3]&3)<<16)|(e[4]<<8)|e[5];
    long diff=(long)(cen_n-c0)-2*(en-s+1)*132; if(diff<mn)mn=diff; if(diff>mx)mx=diff; run(96*300);
  }
  printf("status duration minus nominal over 48 phases/phrases: min %ld max %ld enables (datasheet: busy ends within one sample of the last one)\n",mn,mx);
}
