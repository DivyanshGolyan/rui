/* Narrow execution lifetime fixture. No Store, provider grammar or recovery
 * engine. */
#define _DARWIN_C_SOURCE
#include <assert.h>
#include <curl/curl.h>
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <malloc/malloc.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
enum { W = 16384, CAP = 1000 };
typedef union {
  struct {
    size_t n;
    int cat;
  } v;
  max_align_t align;
} Header;
static _Atomic size_t live[2], peak[2];
static void *allocate(size_t n, int cat) {
  Header *h = malloc(sizeof(*h) + n);
  if (!h)
    return NULL;
  h->v.n = n;
  h->v.cat = cat;
  size_t now = atomic_fetch_add(&live[cat], n) + n;
  size_t old = atomic_load(&peak[cat]);
  while (now > old && !atomic_compare_exchange_weak(&peak[cat], &old, now)) {
  }
  return h + 1;
}
static void release(void *p) {
  if (p) {
    Header *h = (Header *)p - 1;
    live[h->v.cat] -= h->v.n;
    free(h);
  }
}
static void *cm(size_t n) { return allocate(n, 1); }
static void *cr(void *p, size_t n) {
  if (!p)
    return cm(n);
  Header *h = (Header *)p - 1;
  size_t old = h->v.n;
  void *q = cm(n);
  if (!q)
    return NULL;
  memcpy(q, p, old < n ? old : n);
  release(p);
  return q;
}
static char *cs(const char *s) {
  size_t n = strlen(s) + 1;
  char *p = cm(n);
  if (p)
    memcpy(p, s, n);
  return p;
}
static void *cc(size_t a, size_t b) {
  if (b && a > SIZE_MAX / b)
    return NULL;
  void *p = cm(a * b);
  if (p)
    memset(p, 0, a * b);
  return p;
}
typedef struct {
  uint64_t operation, attempt, bytes, offset;
  void *effect;
  int source, occupied, sealed, pending, fenced, published;
} Custody;
typedef struct {
  CURL *easy;
  struct curl_slist *headers;
  unsigned char *window;
  int request, target, in, out, error_source, error_pipe;
  size_t error_bytes;
  pid_t pid;
} Effect;
static Custody *slots;
static int count;
static size_t bytes;
static const char *kind, *variant;
static int owned_fds;
static int scratch(void) {
  char p[] = "/tmp/rui-lifetime-XXXXXX";
  int fd = mkstemp(p);
  assert(fd >= 0);
  assert(fcntl(fd, F_SETFD, FD_CLOEXEC) == 0);
  assert(unlink(p) == 0);
  owned_fds++;
  return fd;
}
static void shut(int *fd) {
  if (*fd >= 0) {
    assert(close(*fd) == 0);
    *fd = -1;
    owned_fds--;
  }
}
static void allwrite(int fd, const void *p, size_t n) {
  while (n) {
    ssize_t k = write(fd, p, n);
    if (k < 0 && errno == EINTR)
      continue;
    assert(k > 0);
    p = (const char *)p + k;
    n -= k;
  }
}
static void snapshot(const char *stage) {
  struct rusage_info_v4 r = {0};
  assert(proc_pid_rusage(getpid(), RUSAGE_INFO_V4, (rusage_info_t *)&r) == 0);
  malloc_statistics_t m = {0};
  malloc_zone_statistics(NULL, &m);
  uint64_t child_phys = 0, child_rss = 0;
  int children = 0, occupied = 0;
  for (int i = 0; slots && i < count; i++) {
    occupied += slots[i].occupied;
    Effect *e = slots[i].effect;
    if (e && e->pid > 0) {
      struct rusage_info_v4 c = {0};
      if (proc_pid_rusage(e->pid, RUSAGE_INFO_V4, (rusage_info_t *)&c) == 0) {
        child_phys += c.ri_phys_footprint;
        child_rss += c.ri_resident_size;
        children++;
      }
    }
  }
  uint64_t scratch_bytes = 0, scratch_blocks = 0;
  for (int i = 0; slots && i < count; i++) {
    Effect *e = slots[i].effect;
    if (!e)
      continue;
    int fds[] = {slots[i].source, e->request, e->target, e->error_source};
    for (int j = 0; j < 4; j++)
      if (fds[j] >= 0) {
        struct stat st;
        assert(fstat(fds[j], &st) == 0);
        scratch_bytes += st.st_size;
        scratch_blocks += st.st_blocks * 512;
      }
  }
  static struct proc_fdinfo fd_sample[10000];
  int fdbytes =
      proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, fd_sample, sizeof(fd_sample));
  assert(fdbytes >= 0);
  printf("{\"os_fd_count\":%zu,\"scratch_logical\":%llu,\"scratch_blocks\":%"
         "llu,\"physical_lifetime_peak\":%llu,",
         (size_t)fdbytes / sizeof(struct proc_fdinfo),
         (unsigned long long)scratch_bytes, (unsigned long long)scratch_blocks,
         r.ri_lifetime_max_phys_footprint);
  printf("\"stage\":\"%s\",\"own_live\":%zu,\"own_peak\":%zu,\"curl_live\":%zu,"
         "\"curl_peak\":%zu,\"malloc_in_use\":%zu,\"malloc_reserved\":%zu,"
         "\"physical\":%llu,\"rss\":%llu,\"child_physical\":%llu,\"child_rss\":"
         "%llu,\"children_observed\":%d,\"owned_fds\":%d,\"occupied\":%d,"
         "\"custody_size\":%zu,\"effect_size\":%zu}\n",
         stage, live[0], peak[0], live[1], peak[1], m.size_in_use,
         m.size_allocated, r.ri_phys_footprint, r.ri_resident_size,
         (unsigned long long)child_phys, (unsigned long long)child_rss,
         children, owned_fds, occupied, sizeof(Custody), sizeof(Effect));
  fflush(stdout);
}
static int headers_seen;
static size_t header(char *p, size_t a, size_t b, void *ctx) {
  (void)ctx;
  size_t n = a * b;
  if (n == 2 && !memcmp(p, "\r\n", 2)) {
    if (++headers_seen == count)
      snapshot("transport_active");
  }
  return n;
}
static size_t upload(char *p, size_t a, size_t b, void *ctx) {
  Effect *e = ctx;
  ssize_t n = read(e->request, p, a * b);
  return n < 0 ? CURL_READFUNC_ABORT : (size_t)n;
}
static size_t capture(char *p, size_t a, size_t b, void *ctx) {
  Custody *s = ctx;
  assert(s->occupied && !s->sealed);
  s->pending = 1;
  allwrite(s->source, p, a * b);
  s->bytes += a * b;
  s->pending = 0;
  return a * b;
}
static void fill(int fd, size_t n, unsigned char *w) {
  memset(w, 'a', W);
  for (size_t i = 1; i < W; i += 2)
    w[i] = '\n';
  while (n) {
    size_t k = n < W ? n : W;
    allwrite(fd, w, k);
    n -= k;
  }
  assert(lseek(fd, 0, SEEK_SET) == 0);
}
static void validate(Custody *s, int edit, unsigned char *w) {
  assert(s->occupied && s->sealed);
  assert(lseek(s->source, 0, SEEK_SET) == 0);
  size_t pos = 0;
  for (;;) {
    ssize_t n = read(s->source, w, W);
    assert(n >= 0);
    if (!n)
      break;
    for (ssize_t j = 0; j < n; j++, pos++)
      assert(w[j] == ((pos & 1) ? '\n' : (edit && pos == 0 ? 'b' : 'a')));
  }
  assert(pos == bytes);
  assert(s->operation == s->attempt + 10000);
  s->published = 1;
}
static void transport_done(Custody *s, CURLM *multi) {
  Effect *e = s->effect;
  assert(!s->pending);
  if (e->easy) {
    assert(curl_multi_remove_handle(multi, e->easy) == CURLM_OK);
    curl_easy_cleanup(e->easy);
    e->easy = NULL;
    curl_slist_free_all(e->headers);
    e->headers = NULL;
  }
  shut(&e->request);
}
int main(int argc, char **argv) {
  if (argc == 3 && !strcmp(argv[1], "--child")) {
    size_t n = strtoull(argv[2], 0, 10);
    unsigned char w[W];
    memset(w, 'a', W);
    for (int i = 1; i < W; i += 2)
      w[i] = '\n';
    while (n) {
      size_t k = n < W ? n : W;
      allwrite(1, w, k);
      allwrite(2, w, k);
      n -= k;
    }
    char c;
    assert(read(0, &c, 1) == 1);
    return 0;
  }
  assert(argc == 6);
  fprintf(stderr, "%s\n", curl_version());
  kind = argv[1];
  variant = argv[2];
  count = atoi(argv[3]);
  bytes = strtoull(argv[4], 0, 10);
  assert(count > 0 && count <= CAP && bytes >= 2 && bytes <= 1048576);
  int model = !strcmp(kind, "model"), bash = !strcmp(kind, "bash"),
      edit = !strcmp(kind, "edit"), early = !strcmp(variant, "early");
  assert(model || bash || edit);
  struct rlimit lim;
  assert(getrlimit(RLIMIT_NOFILE, &lim) == 0);
  lim.rlim_cur = lim.rlim_max < 10000 ? lim.rlim_max : 10000;
  assert(setrlimit(RLIMIT_NOFILE, &lim) == 0);
  snapshot("cold");
  slots = allocate(CAP * sizeof(*slots), 0);
  assert(slots);
  memset(slots, 0, CAP * sizeof(*slots));
  snapshot("fixed_custody");
  unsigned char *shared = allocate(W, 0);
  assert(shared);
  CURLM *multi = NULL;
  if (model) {
    assert(curl_global_init_mem(CURL_GLOBAL_DEFAULT, cm, release, cr, cs, cc) ==
           0);
    multi = curl_multi_init();
    assert(multi);
    assert(curl_multi_setopt(multi, CURLMOPT_MAXCONNECTS, 16L) == CURLM_OK);
  }
  for (int i = 0; i < count; i++) {
    Custody *s = &slots[i];
    s->operation = i + 10001;
    s->attempt = i + 1;
    s->occupied = 1;
    s->source = scratch();
    Effect *e = allocate(sizeof(*e), 0);
    assert(e);
    memset(e, 0, sizeof(*e));
    e->request = e->target = e->in = e->out = e->error_source = e->error_pipe =
        -1;
    s->effect = e;
    if (!model && !early) {
      e->window = allocate(W, 0);
      assert(e->window);
      memset(e->window, 0, W);
    }
    if (model) {
      e->request = scratch();
      fill(e->request, 128, shared);
      e->easy = curl_easy_init();
      assert(e->easy);
      e->headers = curl_slist_append(NULL, "X-Fixture: execution-lifetimes");
      assert(e->headers);
      assert(curl_easy_setopt(e->easy, CURLOPT_URL, argv[5]) == 0);
      assert(curl_easy_setopt(e->easy, CURLOPT_HTTPHEADER, e->headers) == 0);
      assert(curl_easy_setopt(e->easy, CURLOPT_POST, 1L) == 0);
      assert(curl_easy_setopt(e->easy, CURLOPT_POSTFIELDSIZE_LARGE,
                              (curl_off_t)128) == 0);
      assert(curl_easy_setopt(e->easy, CURLOPT_READFUNCTION, upload) == 0);
      assert(curl_easy_setopt(e->easy, CURLOPT_READDATA, e) == 0);
      assert(curl_easy_setopt(e->easy, CURLOPT_HEADERFUNCTION, header) == 0);
      assert(curl_easy_setopt(e->easy, CURLOPT_WRITEFUNCTION, capture) == 0);
      assert(curl_easy_setopt(e->easy, CURLOPT_WRITEDATA, s) == 0);
      assert(curl_easy_setopt(e->easy, CURLOPT_PROXY, "") == 0);
      assert(curl_easy_setopt(e->easy, CURLOPT_TIMEOUT_MS, 30000L) == 0);
      assert(curl_multi_add_handle(multi, e->easy) == CURLM_OK);
    }
    if (edit) {
      e->target = scratch();
      fill(e->target, bytes, shared);
    }
    if (bash) {
      int a[2], b[2], err[2];
      assert(pipe(a) == 0 && pipe(b) == 0 && pipe(err) == 0);
      e->error_source = scratch();
      posix_spawn_file_actions_t fa;
      assert(posix_spawn_file_actions_init(&fa) == 0);
      posix_spawn_file_actions_adddup2(&fa, a[0], 0);
      posix_spawn_file_actions_adddup2(&fa, b[1], 1);
      posix_spawn_file_actions_adddup2(&fa, err[1], 2);
      posix_spawn_file_actions_addclose(&fa, a[1]);
      posix_spawn_file_actions_addclose(&fa, b[0]);
      char *args[] = {"/bin/bash",
                      "--noprofile",
                      "--norc",
                      "-c",
                      "exec \"$1\" --child \"$2\"",
                      "fixture",
                      argv[0],
                      argv[4],
                      NULL};
      char *environment[] = {"PATH=/usr/bin:/bin", "LC_ALL=C", NULL};
      int pipe_fds[] = {a[0], a[1], b[0], b[1], err[0], err[1]};
      for (int j = 0; j < 6; j++)
        assert(fcntl(pipe_fds[j], F_SETFD, FD_CLOEXEC) == 0);
      int rc = posix_spawn(&e->pid, "/bin/bash", &fa, NULL, args, environment);
      assert(rc == 0);
      posix_spawn_file_actions_destroy(&fa);
      close(a[0]);
      close(b[1]);
      close(err[1]);
      e->in = a[1];
      e->out = b[0];
      e->error_pipe = err[0];
      owned_fds += 3;
      assert(fcntl(e->error_pipe, F_SETFL, O_NONBLOCK) == 0);
      assert(fcntl(e->out, F_SETFL, O_NONBLOCK) == 0);
    }
  }
  snapshot("loaded");
  if (model) {
    int running;
    do {
      assert(curl_multi_perform(multi, &running) == CURLM_OK);
      if (running)
        assert(curl_multi_poll(multi, NULL, 0, 20, NULL) == CURLM_OK);
    } while (running);
    int left, done = 0;
    CURLMsg *msg;
    while ((msg = curl_multi_info_read(multi, &left))) {
      if (msg->msg != CURLMSG_DONE || msg->data.result != CURLE_OK) {
        fprintf(stderr, "transfer failed: %d %s\n", msg->data.result,
                curl_easy_strerror(msg->data.result));
        abort();
      }
      done++;
    }
    assert(done == count);
  }
  if (bash) {
    int left = count;
    while (left) {
      left = 0;
      for (int i = 0; i < count; i++) {
        Custody *s = &slots[i];
        Effect *e = s->effect;
        for (int stream = 0; stream < 2; stream++) {
          size_t have = stream ? e->error_bytes : s->bytes;
          if (have < bytes) {
            left++;
            unsigned char *w = e->window ? e->window : shared;
            ssize_t n = read(stream ? e->error_pipe : e->out, w, W);
            if (n < 0) {
              assert(errno == EAGAIN || errno == EINTR);
              continue;
            }
            assert(n > 0);
            allwrite(stream ? e->error_source : s->source, w, n);
            if (stream)
              e->error_bytes += n;
            else
              s->bytes += n;
          }
        }
      }
      if (left)
        usleep(100);
    }
  }
  if (edit) {
    for (size_t offset = 0; offset < bytes; offset += W) {
      for (int i = 0; i < count; i++) {
        Custody *s = &slots[i];
        Effect *e = s->effect;
        unsigned char *w = e->window ? e->window : shared;
        size_t n = bytes - offset < W ? bytes - offset : W;
        assert(read(e->target, w, n) == (ssize_t)n);
        if (offset == 0) {
          assert(w[0] == 'a' && w[1] == '\n');
          w[0] = 'b';
        }
        allwrite(s->source, w, n);
        s->bytes += n;
      }
    }
  }
  for (int i = 0; i < count; i++) {
    assert(slots[i].bytes == bytes);
    slots[i].sealed = 1;
  }
  snapshot("sealed_waiting");
  if (early) {
    for (int i = 0; i < count; i++) {
      Custody *s = &slots[i];
      Effect *e = s->effect;
      if (model)
        transport_done(s, multi);
      if (bash) {
        allwrite(e->in, "x", 1);
        int st;
        assert(waitpid(e->pid, &st, 0) == e->pid && WIFEXITED(st) &&
               WEXITSTATUS(st) == 0);
        e->pid = 0;
        shut(&e->in);
        shut(&e->out);
        shut(&e->error_pipe);
      }
    }
  }
  snapshot("delayed_validation");
  for (int i = 0; i < count; i++) {
    Custody *s = &slots[i];
    Effect *e = s->effect;
    validate(s, edit, shared);
    if (bash) {
      assert(e->error_bytes == bytes);
      int source = s->source;
      s->source = e->error_source;
      validate(s, 0, shared);
      s->source = source;
    }
    if (edit) {
      assert(lseek(s->source, 0, SEEK_SET) == 0);
      assert(lseek(e->target, 0, SEEK_SET) == 0);
      size_t n = 0;
      while (n < bytes) {
        ssize_t k = read(s->source, shared, W);
        assert(k > 0);
        allwrite(e->target, shared, k);
        n += k;
      }
      assert(ftruncate(e->target, bytes) == 0 && fsync(e->target) == 0);
      int source = s->source;
      s->source = e->target;
      validate(s, 1, shared);
      s->source = source;
    }
    if (model)
      transport_done(s, multi);
    if (e->pid) {
      allwrite(e->in, "x", 1);
      int st;
      assert(waitpid(e->pid, &st, 0) == e->pid && WIFEXITED(st) &&
             WEXITSTATUS(st) == 0);
      e->pid = 0;
    }
    shut(&e->in);
    shut(&e->out);
    shut(&e->error_pipe);
    shut(&e->target);
    shut(&e->error_source);
    shut(&s->source);
    release(e->window);
    release(e);
    s->effect = NULL;
    s->occupied = 0;
  }
  snapshot("retained_idle");
  if (multi) {
    assert(curl_multi_cleanup(multi) == 0);
    curl_global_cleanup();
  }
  release(shared);
  release(slots);
  slots = NULL;
  snapshot("closed");
  assert(live[0] == 0 && live[1] == 0 && owned_fds == 0);
  return 0;
}
