// THROWAWAY: one SQLite owner, independent I/O reactor, fake streams and one real shell.
// Synthetic report schema and command queue; not the Rui server or its semantic proof.
#include "sqlite3.h"
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define MAX_SLOTS 100
static sqlite3 *db;
static int capacity, reads[MAX_SLOTS], writes[MAX_SLOTS], spools[MAX_SLOTS];
static int wake_pipe[2];
static volatile sig_atomic_t shell_pid;
static atomic_int shutting_down;
static void emergency_cleanup(void) {
    atomic_store(&shutting_down,1);
    pid_t child=(pid_t)shell_pid;
    if(child>0){kill(-child,SIGKILL);kill(child,SIGKILL);while(waitpid(child,NULL,0)<0&&errno==EINTR){}shell_pid=0;}
}
static void emergency_signal(int sig) {emergency_cleanup();_exit(128+sig);}
static atomic_int start_client, stop_ready, cancellation_committed;
static atomic_ullong requested_ns, streamed_bytes, shell_bytes;
static uint64_t reactor_last_tick, reactor_max_gap, first_stop_ns, all_stops_ns, drained_ns;
static int escalated;

static uint64_t now_ns(void) { struct timespec t; assert(clock_gettime(CLOCK_MONOTONIC,&t)==0); return (uint64_t)t.tv_sec*1000000000ULL+t.tv_nsec; }
static double cpu_ms(void) { struct timespec t; assert(clock_gettime(CLOCK_PROCESS_CPUTIME_ID,&t)==0); return t.tv_sec*1000.0+t.tv_nsec/1e6; }
static uint64_t footprint(void) { struct rusage_info_v4 u={0}; assert(proc_pid_rusage(getpid(),RUSAGE_INFO_V4,(rusage_info_t *)&u)==0); return u.ri_phys_footprint; }
static void sleep_ns(long n) { struct timespec t={0,n}; while(nanosleep(&t,&t)&&errno==EINTR){} }
static void sql(const char *s) { char *e=NULL; int rc=sqlite3_exec(db,s,NULL,NULL,&e); if(rc!=SQLITE_OK){fprintf(stderr,"SQL: %s: %s\n",s,e);exit(2);} }
static sqlite3_stmt *prepare(const char *s) { sqlite3_stmt *q; assert(sqlite3_prepare_v2(db,s,-1,&q,NULL)==SQLITE_OK);return q; }
static void open_db(const char *path) {
    assert(sqlite3_open_v2(path,&db,SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE|SQLITE_OPEN_NOMUTEX|SQLITE_OPEN_PRIVATECACHE,NULL)==SQLITE_OK);
    sql("PRAGMA journal_mode=DELETE; PRAGMA synchronous=EXTRA; PRAGMA page_size=4096; PRAGMA mmap_size=0; PRAGMA cache_size=-64; PRAGMA temp_store=FILE; PRAGMA busy_timeout=0;");
}
static void seed(long rows,int width) {
    sql("CREATE TABLE head(revision INTEGER NOT NULL); INSERT INTO head VALUES(0); CREATE TABLE cancelled(id INTEGER PRIMARY KEY); CREATE TABLE turn(id INTEGER PRIMARY KEY,status TEXT NOT NULL); CREATE TABLE member(run INTEGER NOT NULL,seq INTEGER NOT NULL,turn_id INTEGER NOT NULL,binding TEXT NOT NULL,PRIMARY KEY(run,seq)) WITHOUT ROWID; BEGIN IMMEDIATE;");
    char binding[1025]; assert(width>=0&&width<=1024); memset(binding,'b',width);binding[width]=0;
    sqlite3_stmt *t=prepare("INSERT INTO turn VALUES(?1,?2)");
    sqlite3_stmt *m=prepare("INSERT INTO member VALUES(1,?1,?1,?2)");
    const char *states[]={"runnable","waiting_for_permission","in_flight","completed","failed","cancelled"};
    for(long i=1;i<=rows;i++) {
        sqlite3_bind_int64(t,1,i);sqlite3_bind_text(t,2,states[i%6],-1,SQLITE_STATIC);assert(sqlite3_step(t)==SQLITE_DONE);assert(sqlite3_reset(t)==SQLITE_OK);
        sqlite3_bind_int64(m,1,i);sqlite3_bind_text(m,2,binding,-1,SQLITE_STATIC);assert(sqlite3_step(m)==SQLITE_DONE);assert(sqlite3_reset(m)==SQLITE_OK);
    }
    assert(sqlite3_finalize(t)==SQLITE_OK);assert(sqlite3_finalize(m)==SQLITE_OK);sql("COMMIT; ANALYZE;");
}
static int scratch(void) { char p[]="/tmp/rui-cancel-probe-XXXXXX";int fd=mkstemp(p);assert(fd>=0);assert(unlink(p)==0);return fd; }
static void nonblock(int fd) { int f=fcntl(fd,F_GETFL);assert(f>=0&&fcntl(fd,F_SETFL,f|O_NONBLOCK)==0); }
static void write_all(int fd,const char *data,size_t n) { while(n) {ssize_t r=write(fd,data,n);if(r<0&&errno==EINTR)continue;assert(r>0);data+=r;n-=r;} }
static void setup_io(void) {
    assert(pipe(wake_pipe)==0);nonblock(wake_pipe[0]);nonblock(wake_pipe[1]);
    for(int i=0;i<capacity;i++){writes[i]=-1;spools[i]=scratch();}
    for(int i=0;i<capacity-1;i++){int pair[2];assert(socketpair(AF_UNIX,SOCK_STREAM,0,pair)==0);reads[i]=pair[0];writes[i]=pair[1];nonblock(reads[i]);nonblock(writes[i]);}
    int pipefd[2];assert(pipe(pipefd)==0);reads[capacity-1]=pipefd[0];nonblock(reads[capacity-1]);
    shell_pid=fork();assert(shell_pid>=0);
    if(shell_pid==0){
        assert(setpgid(0,0)==0);assert(dup2(pipefd[1],STDOUT_FILENO)==STDOUT_FILENO);
        int nullfd=open("/dev/null",O_RDWR);assert(nullfd>=0);assert(dup2(nullfd,STDIN_FILENO)==STDIN_FILENO);assert(dup2(nullfd,STDERR_FILENO)==STDERR_FILENO);
        struct rlimit lim;assert(getrlimit(RLIMIT_NOFILE,&lim)==0);for(int fd=3;fd<(int)lim.rlim_cur;fd++)close(fd);
        execl("/bin/sh","sh","-c","while :; do printf 'local-tool-output\n'; sleep 0.01; done",(char*)NULL);_exit(127);
    }
    if(setpgid(shell_pid,shell_pid)!=0)assert(errno==EACCES);assert(close(pipefd[1])==0);
}
static void *producer(void *unused) {
    (void)unused;char bytes[1024];memset(bytes,'s',sizeof(bytes));
    while(!atomic_load(&cancellation_committed)) {
        for(int i=0;i<capacity-1;i++) {ssize_t n=write(writes[i],bytes,sizeof(bytes));if(n<0)assert(errno==EAGAIN||errno==EWOULDBLOCK||errno==EINTR||errno==EPIPE);}
        sleep_ns(10000000);
    }
    return NULL;
}
static void *client(void *unused) {
    (void)unused;while(!atomic_load(&start_client))sleep_ns(100000);
    sleep_ns(1000000); // actual arrival is recorded; no inferred queue latency.
    atomic_store(&requested_ns,now_ns());atomic_store(&stop_ready,1);return NULL;
}
static void *reactor(void *unused) {
    (void)unused;char buffer[4096];int stop_sent=0;reactor_last_tick=now_ns();
    while(1) {
        uint64_t tick=now_ns(),gap=tick-reactor_last_tick;reactor_last_tick=tick;if(gap>reactor_max_gap)reactor_max_gap=gap;
        if(atomic_load(&cancellation_committed)&&!stop_sent) {
            first_stop_ns=now_ns();
            for(int i=0;i<capacity-1;i++){assert(close(reads[i])==0);reads[i]=-1;}
            assert(kill(-shell_pid,SIGTERM)==0||errno==ESRCH);all_stops_ns=now_ns();stop_sent=1;
        }
        if(stop_sent&&reads[capacity-1]<0)break;
        if(stop_sent&&now_ns()-all_stops_ns>2000000000ULL&&!escalated){assert(kill(-shell_pid,SIGKILL)==0||errno==ESRCH);escalated=1;}
        assert(!stop_sent||now_ns()-all_stops_ns<5000000000ULL);
        struct pollfd fds[MAX_SLOTS+1];fds[0]=(struct pollfd){wake_pipe[0],POLLIN,0};
        for(int i=0;i<capacity;i++)fds[i+1]=(struct pollfd){reads[i],POLLIN,0};
        int rc=poll(fds,capacity+1,5);if(rc<0){assert(errno==EINTR);continue;}
        if(fds[0].revents){while(read(wake_pipe[0],buffer,sizeof(buffer))>0){}}
        for(int i=0;i<capacity;i++)if(reads[i]>=0&&fds[i+1].revents) {
            for(int quantum=0;quantum<4;quantum++) {
                ssize_t n=read(reads[i],buffer,sizeof(buffer));
                if(n>0){write_all(spools[i],buffer,n);atomic_fetch_add(&streamed_bytes,n);if(i==capacity-1)atomic_fetch_add(&shell_bytes,n);continue;}
                if(n==0){if(atomic_load(&shutting_down))return NULL;assert(i==capacity-1&&stop_sent);assert(close(reads[i])==0);reads[i]=-1;break;}
                assert(errno==EAGAIN||errno==EWOULDBLOCK||errno==EINTR);break;
            }
        }
    }
    drained_ns=now_ns();return NULL;
}
static long long report_bytes;
static uint64_t capture_begin[8],capture_end[8],capture_stream_bytes;
static double capture(long expected,int ordinal) {
    uint64_t start=now_ns(),bytes_before=atomic_load(&streamed_bytes);capture_begin[ordinal]=start;char line[4096],outbuf[8192];FILE *f=tmpfile();assert(f);assert(setvbuf(f,outbuf,_IOFBF,sizeof(outbuf))==0);sql("BEGIN");
    sqlite3_stmt *h=prepare("SELECT revision FROM head");assert(sqlite3_step(h)==SQLITE_ROW&&sqlite3_column_int(h,0)==0);assert(sqlite3_finalize(h)==SQLITE_OK);
    if(ordinal==0)atomic_store(&start_client,1);
    long rows=0;int scans=0,sorts=0;
    while(rows<expected) {
        sqlite3_stmt *q=prepare("SELECT m.seq,t.status,m.binding FROM member m JOIN turn t ON t.id=m.turn_id WHERE m.run=1 AND m.seq>?1 ORDER BY m.seq LIMIT 100");
        sqlite3_bind_int64(q,1,rows);int rc;
        while((rc=sqlite3_step(q))==SQLITE_ROW){long id=sqlite3_column_int64(q,0);assert(id==rows+1);
            int n=snprintf(line,sizeof(line),"{\"turn\":%ld,\"session\":%ld,\"status\":\"%s\",\"binding\":\"%s\"}\n",id,id,sqlite3_column_text(q,1),sqlite3_column_text(q,2));assert(n>0&&(size_t)n<sizeof(line));assert(fwrite(line,1,n,f)==(size_t)n);rows++;
        }
        assert(rc==SQLITE_DONE);scans+=sqlite3_stmt_status(q,SQLITE_STMTSTATUS_FULLSCAN_STEP,0);sorts+=sqlite3_stmt_status(q,SQLITE_STMTSTATUS_SORT,0);assert(sqlite3_finalize(q)==SQLITE_OK);
    }
    assert(rows==expected&&scans==0&&sorts==0);assert(fflush(f)==0);sql("COMMIT");assert(sqlite3_get_autocommit(db));report_bytes+=ftello(f);assert(fclose(f)==0);capture_end[ordinal]=now_ns();capture_stream_bytes+=atomic_load(&streamed_bytes)-bytes_before;return (capture_end[ordinal]-start)/1e6;
}
int main(int argc,char **argv) {
    assert(argc==7);const char *path=argv[1],*mode=argv[2];long rows=strtol(argv[3],NULL,10);int width=atoi(argv[4]);capacity=atoi(argv[5]);int queue=atoi(argv[6]);
    assert(rows>=0&&capacity>=1&&capacity<=MAX_SLOTS&&queue>=1&&queue<=8);signal(SIGPIPE,SIG_IGN);signal(SIGABRT,emergency_signal);signal(SIGTERM,emergency_signal);signal(SIGINT,emergency_signal);assert(atexit(emergency_cleanup)==0);open_db(path);
    if(!strcmp(mode,"seed")){seed(rows,width);assert(sqlite3_close(db)==SQLITE_OK);return 0;}
    assert(!strcmp(mode,"fifo")||!strcmp(mode,"control_first"));sql("DELETE FROM cancelled; UPDATE head SET revision=0;");
    setup_io();pthread_t pt,rt,ct;assert(pthread_create(&pt,NULL,producer,NULL)==0);assert(pthread_create(&rt,NULL,reactor,NULL)==0);assert(pthread_create(&ct,NULL,client,NULL)==0);
    uint64_t warmup=now_ns();while(!atomic_load(&shell_bytes)){assert(now_ns()-warmup<5000000000ULL);sleep_ns(1000000);}
    sleep_ns(20000000); // establish traffic, not included in measured work interval.
    uint64_t started=now_ns(),base_footprint=footprint();double cpu_start=cpu_ms();
    const char *fault=getenv("RUI_PROBE_SIGNAL");
    if(fault){fprintf(stderr,"owned_shell_group=%d\n",(int)shell_pid);fflush(stderr);raise(atoi(fault));assert(0);}
    sqlite3_int64 ignored,peak;sqlite3_status64(SQLITE_STATUS_MEMORY_USED,&ignored,&peak,1);
    double captures[8]={0};int completed=0;
    if(rows==0)atomic_store(&start_client,1);
    for(int i=0;rows&&i<queue;i++) {
        captures[completed++]=capture(rows,i);
        if(!strcmp(mode,"control_first")&&atomic_load(&stop_ready))break;
    }
    while(!atomic_load(&stop_ready))sleep_ns(100000);
    uint64_t owner_started=now_ns();sql("BEGIN IMMEDIATE; INSERT INTO cancelled VALUES(1); UPDATE head SET revision=1; COMMIT;");uint64_t committed=now_ns();
    atomic_store(&cancellation_committed,1);assert(write(wake_pipe[1],"!",1)==1);
    assert(pthread_join(ct,NULL)==0);assert(pthread_join(pt,NULL)==0);assert(pthread_join(rt,NULL)==0);
    int status;assert(waitpid(shell_pid,&status,0)==shell_pid);assert(!(WIFEXITED(status)&&WEXITSTATUS(status)==127));shell_pid=0;
    uint64_t ended=now_ns(),request=atomic_load(&requested_ns);double used_cpu=cpu_ms()-cpu_start;
    assert(request<=owner_started&&owner_started<=committed&&committed<=first_stop_ns&&first_stop_ns<=all_stops_ns&&all_stops_ns<=drained_ns);
    sqlite3_status64(SQLITE_STATUS_MEMORY_USED,&ignored,&peak,0);
    int overlap=0;for(int i=0;i<completed;i++)if(request>=capture_begin[i]&&request<=capture_end[i])overlap=1;
    long long scratch_bytes=0;for(int i=0;i<capacity;i++){scratch_bytes+=lseek(spools[i],0,SEEK_END);assert(close(spools[i])==0);if(writes[i]>=0)assert(close(writes[i])==0);}
    assert(scratch_bytes==(long long)atomic_load(&streamed_bytes));close(wake_pipe[0]);close(wake_pipe[1]);
    printf("{\"sqlite\":\"%s\",\"rows\":%ld,\"width\":%d,\"capacity\":%d,\"policy\":\"%s\",\"queued_inspections\":%d,\"completed_before_stop\":%d,\"report_bytes\":%lld,\"capture_ms\":[",sqlite3_libversion(),rows,width,capacity,mode,queue,completed,report_bytes);
    for(int i=0;i<completed;i++)printf("%s%.6f",i?",":"",captures[i]);
    printf("],\"arrived_during_capture\":%s,\"bytes_drained_during_captures\":%llu,\"request_after_start_ms\":%.6f,\"queue_wait_ms\":%.6f,\"stop_ack_ms\":%.6f,\"sql_commit_ms\":%.6f,\"first_interruption_ms\":%.6f,\"all_interruptions_ms\":%.6f,\"local_drain_ms\":%.6f,\"reactor_max_tick_gap_including_warmup_ms\":%.6f,\"process_cpu_ms\":%.6f,\"elapsed_ms\":%.6f,\"sqlite_heap_peak\":%lld,\"physical_start\":%llu,\"physical_end\":%llu,\"streamed_bytes\":%llu,\"shell_escalated\":%d}\n",overlap?"true":"false",(unsigned long long)capture_stream_bytes,(request-started)/1e6,(owner_started-request)/1e6,(committed-request)/1e6,(committed-owner_started)/1e6,(first_stop_ns-request)/1e6,(all_stops_ns-request)/1e6,(drained_ns-request)/1e6,reactor_max_gap/1e6,used_cpu,(ended-started)/1e6,(long long)peak,(unsigned long long)base_footprint,(unsigned long long)footprint(),(unsigned long long)atomic_load(&streamed_bytes),escalated);
    assert(sqlite3_get_autocommit(db));assert(sqlite3_close(db)==SQLITE_OK);return 0;
}
