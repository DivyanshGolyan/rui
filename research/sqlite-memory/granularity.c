/* Independent filesystem calibration, not a replacement SQLite workload. */
#include <libproc.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <assert.h>
static uint64_t writes(void){struct rusage_info_v2 r;assert(proc_pid_rusage(getpid(),RUSAGE_INFO_V2,(rusage_info_t*)&r)==0);return r.ri_diskio_byteswritten;}
int main(int argc,char**argv){
 assert(argc==2);int fd=open(argv[1],O_CREAT|O_EXCL|O_RDWR,0600);assert(fd>=0);
 unsigned char buf[16384];memset(buf,0x5a,sizeof buf);
 for(int i=0;i<64;i++)assert(write(fd,buf,sizeof buf)==sizeof buf);assert(fsync(fd)==0);
 const char*names[]={"one_4k","four_adjacent_4k","four_spaced_4k","one_16k","same_4k_twice"};
 for(int mode=0;mode<5;mode++){
  uint64_t before=writes(),logical=0,sync_bytes=0,write_bytes=0;
  for(int i=0;i<100;i++){
   off_t start=(i%8)*65536;int count=mode==1||mode==2?4:mode==4?2:1;int n=mode==3?16384:4096;
   uint64_t a=writes();
   for(int j=0;j<count;j++){off_t offset=start+(mode==2?j*16384:mode==1?j*4096:0);assert(pwrite(fd,buf,n,offset)==n);logical+=n;}
   uint64_t b=writes();assert(fsync(fd)==0);uint64_t c=writes();write_bytes+=b-a;sync_bytes+=c-b;
  }
  printf("{\"case\":\"%s\",\"system_page_bytes\":%ld,\"fsyncs\":100,\"logical_write_bytes\":%llu,\"process_write_delta\":%llu,\"during_write\":%llu,\"during_sync\":%llu}\n",names[mode],sysconf(_SC_PAGESIZE),logical,writes()-before,write_bytes,sync_bytes);
 }
 assert(close(fd)==0);assert(unlink(argv[1])==0);return 0;
}
