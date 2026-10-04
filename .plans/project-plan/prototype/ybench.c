#include <yajl/yajl_parse.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
static int ok_arr(void*c){return 1;}
static yajl_callbacks cbs = {0};
int main(int argc,char**argv){
  FILE*f=fopen(argv[1],"rb"); fseek(f,0,SEEK_END); long n=ftell(f); rewind(f);
  unsigned char*b=malloc(n); fread(b,1,n,f); int reps=atoi(argv[2]);
  struct timespec t0,t1; clock_gettime(CLOCK_MONOTONIC,&t0);
  for(int i=0;i<reps;i++){ yajl_handle h=yajl_alloc(&cbs,NULL,NULL);
    if(yajl_parse(h,b,n)!=yajl_status_ok||yajl_complete_parse(h)!=yajl_status_ok){puts("fail");return 1;}
    yajl_free(h);}
  clock_gettime(CLOCK_MONOTONIC,&t1);
  double s=((t1.tv_sec-t0.tv_sec)+(t1.tv_nsec-t0.tv_nsec)/1e9)/reps;
  printf("%-22s %8.3f ms %8.1f MB/s\n",argv[1],s*1e3,n/s/1e6); return 0;}
