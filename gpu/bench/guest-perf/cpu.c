// cpu.c [threads]: two CPU tests, seconds each (lower is better).
//   compute: integer work that stays in cache (sieve + xorshift sort keys)
//   memory:  random reads over a 1 GiB table (every read is a cache and TLB miss)
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
static double now(void){ struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return t.tv_sec+t.tv_nsec/1e9; }
static void *compute(void *arg){ (void)arg; enum{N=1<<16}; static __thread unsigned char s[N]; uint64_t x=88172645463325252ULL, acc=0;
  for(int r=0;r<3000;r++){ memset(s,1,N); for(int i=2;i*i<N;i++) if(s[i]) for(int j=i*i;j<N;j+=i) s[j]=0;
    for(int i=0;i<N;i++){ x^=x<<13; x^=x>>7; x^=x<<17; acc+=s[x&(N-1)]+(x%1000003); } }
  return (void*)(uintptr_t)acc; }
static uint64_t *table; static size_t tn;
static void *memory(void *arg){ uint64_t x=(uintptr_t)arg*2654435761u+12345, acc=0;
  for(long i=0;i<30000000;i++){ x^=x<<13; x^=x>>7; x^=x<<17; acc+=table[x%tn]; } return (void*)(uintptr_t)acc; }
static double run(void *(*f)(void*), int n){ pthread_t t[64]; double a=now(); for(int i=0;i<n;i++) pthread_create(&t[i],0,f,(void*)(uintptr_t)(i+1)); for(int i=0;i<n;i++) pthread_join(t[i],0); return now()-a; }
int main(int c,char**v){ int n=c>1?atoi(v[1]):1; tn=(1u<<30)/8; table=malloc(tn*8); for(size_t i=0;i<tn;i++) table[i]=i;
  printf("threads %d  compute %.2fs  memory %.2fs\n", n, run(compute,n), run(memory,n)); return 0; }
