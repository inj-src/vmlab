// tick SECONDS [PERIOD_MS]: sleep to absolute deadlines every PERIOD_MS; print each wake-up that
// is 3 ms or more late as "epoch_ms late_ms"
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <pthread.h>
static double epoch(void){ struct timespec t; clock_gettime(CLOCK_REALTIME,&t); return t.tv_sec*1e3+t.tv_nsec/1e6; }
int main(int c,char**v){ double secs=atof(v[1]), period=c>2?atof(v[2]):1; mach_timebase_info_data_t tb; mach_timebase_info(&tb);
  double ns=(double)tb.numer/tb.denom; uint64_t step=(uint64_t)(period*1e6/ns), next=mach_absolute_time()+step, end=next+(uint64_t)(secs*1e9/ns);
  pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE,0); setvbuf(stdout,0,_IOLBF,0); long n=0,late=0; double worst=0;
  while(next<end){ mach_wait_until(next); uint64_t now=mach_absolute_time(); double l=(now-next)*ns/1e6; n++;
    if(l>worst) worst=l; if(l>=3){ late++; printf("%.0f %.1f\n",epoch(),l); } next+=step; if(now>next) next=now+step; }
  printf("wakeups %ld late %ld worst %.1f ms\n",n,late,worst); return 0; }
