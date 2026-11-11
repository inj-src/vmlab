// stall SECONDS [THREADS]: spin on the clock, print every gap over 4 ms as "epoch_ms gap_ms thread"
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/time.h>
#include <time.h>
static double secs;
static double now(void){ struct timespec t; clock_gettime(CLOCK_REALTIME,&t); return t.tv_sec*1e3+t.tv_nsec/1e6; }
static void *spin(void *a){ double start=now(), last=start, t;
  while((t=now())-start<secs*1e3){ if(t-last>4) printf("%.0f %.1f %ld\n",t,t-last,(long)a); last=t; } return 0; }
int main(int c,char**v){ secs=atof(v[1]); int n=c>2?atoi(v[2]):1; pthread_t th[16]; setvbuf(stdout,0,_IOLBF,0);
  for(long i=0;i<n;i++) pthread_create(&th[i],0,spin,(void*)i); for(int i=0;i<n;i++) pthread_join(th[i],0); return 0; }
