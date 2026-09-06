/* THROWAWAY: exact single replacement on an already sealed snapshot.
 * Not live-file authorization, mutation or crash recovery. */
#include <CommonCrypto/CommonDigest.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>
#define W 16384
static void die(const char *s){perror(s);exit(2);}
static void put(int fd,const void *p,size_t n){const char *s=p;while(n){ssize_t k=write(fd,s,n);if(k<0){if(errno==EINTR)continue;die("write");}if(!k)exit(2);s+=k;n-=k;}}
static int openin(const char*p){int fd=open(p,O_RDONLY);if(fd<0)die("open");return fd;}
static void copy(int in,int out,uint64_t n,CC_SHA256_CTX *sha){unsigned char b[W];while(n){size_t wanted=n<W?n:W;ssize_t r=read(in,b,wanted);if(r<=0)die("copy read");put(out,b,r);CC_SHA256_Update(sha,b,(CC_LONG)r);n-=r;}}
static uint64_t size(int fd){struct stat s;if(fstat(fd,&s)||s.st_size<0)die("stat");return s.st_size;}
int main(int argc,char**argv){if(argc!=5)return 2;
 int in=openin(argv[1]),pat=openin(argv[2]),rep=openin(argv[3]);uint64_t source=size(in),pn=size(pat),rn=size(rep);
 if(!pn||pn>SIZE_MAX/3){fprintf(stderr,"unsupported needle size\n");return 3;}
 size_t block=pn>W?pn:W;if(pn>SIZE_MAX-block+1)return 2;size_t cap=block+pn-1;
 unsigned char *needle=malloc(pn),*b=malloc(cap);if(!needle||!b)die("malloc");
 size_t got=0;while(got<pn){ssize_t r=read(pat,needle+got,pn-got);if(r<=0)die("needle read");got+=r;}close(pat);
 CC_SHA256_CTX pre,post;CC_SHA256_Init(&pre);CC_SHA256_Init(&post);
 uint64_t offset=0,match=0;size_t kept=0;unsigned matches=0;ssize_t r;
 while((r=read(in,b+kept,block))>0){CC_SHA256_Update(&pre,b+kept,r);offset+=r;size_t valid=kept+r;
  unsigned char *cursor=b,*found;size_t remaining=valid;
  while((found=memmem(cursor,remaining,needle,pn))){match=offset-valid+(found-b);if(++matches==2){puts("{\"result\":\"ambiguous\"}");return 4;}cursor=found+1;remaining=valid-(cursor-b);}
  kept=valid<pn-1?valid:pn-1;memmove(b,b+valid-kept,kept);
 }
 if(r<0)die("scan");if(!matches){puts("{\"result\":\"not_found\"}");return 5;}
 if(source-pn>UINT64_MAX-rn)return 2;uint64_t output=source-pn+rn;
 int out=open(argv[4],O_WRONLY|O_CREAT|O_EXCL,0600);if(out<0)die("output");
 if(lseek(in,0,SEEK_SET)<0)die("seek");copy(in,out,match,&post);
 copy(rep,out,rn,&post);if(lseek(in,match+pn,SEEK_SET)<0)die("seek");copy(in,out,source-match-pn,&post);
 unsigned char a[32],z[32];CC_SHA256_Final(a,&pre);CC_SHA256_Final(z,&post);
 close(out);close(in);close(rep);free(b);free(needle);
 printf("{\"result\":\"replaced\",\"offset\":%llu,\"output_bytes\":%llu,\"needle_and_scan_buffer_bytes\":%llu,\"preimage\":\"",(unsigned long long)match,(unsigned long long)output,(unsigned long long)(pn+cap));
 for(int i=0;i<32;i++)printf("%02x",a[i]);printf("\",\"postimage\":\"");for(int i=0;i<32;i++)printf("%02x",z[i]);puts("\"}");return 0;
}
