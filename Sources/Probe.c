#include "APFHID.h"
#include <stdio.h>
int main(void) {
    char error[512]={0};
    APFDevice *dev=apf_open(error,sizeof(error));
    if(!dev) { fprintf(stderr,"%s\n",error); return 1; }
    unsigned char identity[63]={0}, boot[512]={0};
    if(!apf_identity(dev,identity,sizeof(identity),error,sizeof(error))) goto failed;
    printf("APF USB HID 16c0:1771, report buffer %zu bytes\n",apf_report_size(dev));
    printf("Identity:"); for(unsigned i=0;i<16;i++) printf(" %02x",identity[i]); puts("");
    if(!apf_read_sector(dev,0,0,boot,error,sizeof(error))) goto failed;
    unsigned bps=boot[11]|(boot[12]<<8), total=boot[19]|(boot[20]<<8);
    printf("Boot header:"); for(unsigned i=0;i<36;i++) printf(" %02x",boot[i]); puts("");
    printf("Bytes per sector: %u; sectors: %u; bytes per cluster: %u\n",bps,total,bps*boot[13]);
    unsigned char second[512]={0};
    if(!apf_read_sector(dev,0,bps,second,error,sizeof(error))) goto failed;
    for(unsigned i=0;i<bps;i++) if(second[i]!=boot[i]) { snprintf(error,sizeof(error),"Repeated sector-zero read differs at byte %u",i); goto failed; }
    puts("Repeated boot-sector read matches. No card writes performed.");
    apf_close(dev); return 0;
failed:
    fprintf(stderr,"%s\n",error); apf_close(dev); return 1;
}
