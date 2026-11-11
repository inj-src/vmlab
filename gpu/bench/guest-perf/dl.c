// dl SECONDS: a CVDisplayLink on the main display; print "epoch_ms gap_ms" for each callback
// interval over 25 ms, then a summary. No drawing.
#include <CoreVideo/CoreVideo.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
static double ns_per_tick, last; static long n, late; static double worst;
static double epoch(void){ struct timespec t; clock_gettime(CLOCK_REALTIME,&t); return t.tv_sec*1e3+t.tv_nsec/1e6; }
static CVReturn cb(CVDisplayLinkRef l,const CVTimeStamp*now,const CVTimeStamp*out,CVOptionFlags f,CVOptionFlags*fo,void*c){
  double t=mach_absolute_time()*ns_per_tick/1e6; if(last){ double g=t-last; n++; if(g>worst) worst=g; if(g>25){ late++; printf("%.0f %.1f\n",epoch(),g);} } last=t; return 0; }
int main(int c,char**v){ mach_timebase_info_data_t tb; mach_timebase_info(&tb); ns_per_tick=(double)tb.numer/tb.denom; setvbuf(stdout,0,_IOLBF,0);
  CVDisplayLinkRef l; if(CVDisplayLinkCreateWithActiveCGDisplays(&l)){ puts("no display link"); return 1; }
  CVDisplayLinkSetOutputCallback(l,cb,0); CVDisplayLinkStart(l); CFRunLoopRunInMode(kCFRunLoopDefaultMode,atof(v[1]),0); CVDisplayLinkStop(l);
  printf("callbacks %ld (%.1f/s) late %ld worst %.1f ms\n",n,n/atof(v[1]),late,worst); return 0; }
