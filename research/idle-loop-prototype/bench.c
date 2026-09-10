// Throwaway timing prototype: no OnePage production code.
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <unistd.h>
#include <poll.h>
#include <time.h>
#include <sys/wait.h>
#include <sys/resource.h>
#include <string.h>
typedef struct { volatile uint64_t state; char padding[248]; } Slot;
static uint64_t ns(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return (uint64_t)t.tv_sec*1000000000+t.tv_nsec; }
static double cpu(void) { struct rusage r; getrusage(RUSAGE_SELF,&r); return r.ru_utime.tv_sec+r.ru_utime.tv_usec/1e6+r.ru_stime.tv_sec+r.ru_stime.tv_usec/1e6; }
static int cmp(const void*a,const void*b){double x=*(double*)a,y=*(double*)b;return (x>y)-(x<y);}
int main(int argc,char**argv){
 if(argc!=4)return 2;
 int n=atoi(argv[1]),busy=!strcmp(argv[2],"busy"),events=!strcmp(argv[3],"events");
 Slot *slots=calloc(n,sizeof(Slot)); int fd[2]; if(!slots||pipe(fd))return 3;
 if(!strcmp(argv[2],"scan")){uint64_t start=ns(),scans=0,sum=0;double c=cpu();do{for(int k=0;k<1024;k++){for(int i=0;i<n;i++)sum+=slots[i].state;scans++;}}while(ns()-start<2000000000ULL);double wall=(ns()-start)/1e9,used=cpu()-c;printf("%d,scan,idle,%.6f,%.6f,%.4f,%llu,0,0,0,%llu\n",n,wall,used,100*used/wall,(unsigned long long)scans,(unsigned long long)sum);return 0;}
 pid_t child=fork(); if(child<0)return 4;
 if(!child){close(fd[0]);if(events){for(int i=0;i<200;i++){usleep(5000+(i*7919)%5000);uint64_t t=ns();if(write(fd[1],&t,sizeof t)!=sizeof t)_exit(5);}}else usleep(2000000);uint64_t end=0;write(fd[1],&end,sizeof end);_exit(0);}
 close(fd[1]);struct pollfd p={fd[0],POLLIN,0};uint64_t start=ns(),scans=0,sum=0;double c=cpu(),lat[200];int count=0;
 for(;;){for(int i=0;i<n;i++)sum+=slots[i].state;scans++;int r=poll(&p,1,busy?0:-1);if(r<0)return 6;if(r){uint64_t t;if(read(fd[0],&t,sizeof t)!=sizeof t)return 7;if(!t)break;lat[count++]=(ns()-t)/1000.0;}}
 double used=cpu()-c,wall=(ns()-start)/1e9;int status;waitpid(child,&status,0);qsort(lat,count,sizeof(double),cmp);
 printf("%d,%s,%s,%.6f,%.6f,%.4f,%llu,%d,%.3f,%.3f,%llu\n",n,argv[2],argv[3],wall,used,100*used/wall,(unsigned long long)scans,count,count?lat[count/2]:0,count?lat[(count*99)/100]:0,(unsigned long long)sum);
 free(slots);return status?8:0;
}
