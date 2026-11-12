#define _DARWIN_C_SOURCE 1
#include <assert.h>
#include <curl/curl.h>
#include <errno.h>
#include <libproc.h>
#include <openssl/crypto.h>
#include <openssl/sha.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/resource.h>
#include <time.h>
#include <unistd.h>
typedef union {
  max_align_t align;
  struct {
    size_t n;
    int k;
  } x;
} H;
// These hooks count requested bytes; malloc metadata and retained pages stay in
// OS metrics.
static _Atomic size_t live[2], peak[2], blocks[2];
static void *allocx(size_t n, int k) {
  if (n > SIZE_MAX - sizeof(H))
    return NULL;
  H *h = malloc(sizeof(H) + n);
  if (!h)
    return NULL;
  h->x.n = n;
  h->x.k = k;
  size_t v = atomic_fetch_add(&live[k], n) + n, p = peak[k];
  while (v > p && !atomic_compare_exchange_weak(&peak[k], &p, v)) {
  }
  blocks[k]++;
  return h + 1;
}
static void freex(void *p) {
  if (!p)
    return;
  H *h = (H *)p - 1;
  live[h->x.k] -= h->x.n;
  blocks[h->x.k]--;
  free(h);
}
static void *resize(void *p, size_t n, int k) {
  if (!p)
    return allocx(n, k);
  if (!n) {
    freex(p);
    return NULL;
  }
  if (n > SIZE_MAX - sizeof(H))
    return NULL;
  H *h = (H *)p - 1;
  size_t old = h->x.n;
  H *q = realloc(h, sizeof(H) + n);
  if (!q)
    return NULL;
  q->x.n = n;
  size_t v;
  if (n >= old)
    v = atomic_fetch_add(&live[k], n - old) + n - old;
  else
    v = atomic_fetch_sub(&live[k], old - n) - (old - n);
  size_t high = peak[k];
  while (v > high && !atomic_compare_exchange_weak(&peak[k], &high, v)) {
  }
  return q + 1;
}
static void *cm(size_t n) { return allocx(n, 0); }
static void *cr(void *p, size_t n) { return resize(p, n, 0); }
static void *cc(size_t a, size_t b) {
  if (b && a > SIZE_MAX / b)
    return NULL;
  void *p = cm(a * b);
  if (p)
    memset(p, 0, a * b);
  return p;
}
static char *cs(const char *s) {
  size_t n = strlen(s) + 1;
  char *p = cm(n);
  if (p)
    memcpy(p, s, n);
  return p;
}
static void *om(size_t n, const char *f, int l) {
  (void)f;
  (void)l;
  return allocx(n, 1);
}
static void *orr(void *p, size_t n, const char *f, int l) {
  (void)f;
  (void)l;
  return resize(p, n, 1);
}
static void of(void *p, const char *f, int l) {
  (void)f;
  (void)l;
  freex(p);
}
static double now(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec + t.tv_nsec / 1e9;
}
static size_t appbytes, scratchbytes;
static uint64_t maxphys, maxrss, maxbacklog;
static int maxfds;
static double start;
static void sample(const char *phase) {
  struct rusage_info_v4 r = {0};
  assert(!proc_pid_rusage(getpid(), RUSAGE_INFO_V4, (rusage_info_t *)&r));
  struct proc_taskinfo t;
  assert(proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &t, sizeof(t)) ==
         sizeof(t));
  static struct proc_fdinfo fdlist[8192];
  int nb = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, fdlist, sizeof(fdlist));
  assert(nb >= 0 && nb < (int)sizeof(fdlist));
  int fds = nb / PROC_PIDLISTFD_SIZE;
  if (r.ri_lifetime_max_phys_footprint > maxphys)
    maxphys = r.ri_lifetime_max_phys_footprint;
  if (t.pti_resident_size > maxrss)
    maxrss = t.pti_resident_size;
  if (fds > maxfds)
    maxfds = fds;
  if (phase) {
    printf("{\"phase\":\"%s\",\"seconds\":%.6f,\"curl_live\":%zu,\"curl_peak\":"
           "%zu,\"curl_blocks\":%zu,\"tls_live\":%zu,\"tls_peak\":%zu,\"tls_"
           "blocks\":%zu,\"app_bytes\":%zu,\"scratch_bytes\":%zu,\"physical\":%"
           "llu,\"rss\":%llu,\"max_physical\":%llu,\"max_rss\":%llu,\"fds\":%d,"
           "\"max_fds\":%d,\"max_socket_readable\":%llu}\n",
           phase, now() - start, live[0], peak[0], blocks[0], live[1], peak[1],
           blocks[1], appbytes, scratchbytes,
           (unsigned long long)r.ri_phys_footprint,
           (unsigned long long)t.pti_resident_size, (unsigned long long)maxphys,
           (unsigned long long)maxrss, fds, maxfds,
           (unsigned long long)maxbacklog);
    fflush(stdout);
  }
}
typedef struct {
  CURL *e;
  int req, out;
  size_t got;
  int id, paused, once;
  double resume;
} T;
static int scratch(void) {
  char p[] = "/tmp/onepage-transport-capture-XXXXXX";
  int fd = mkstemp(p);
  assert(fd >= 0);
  assert(!unlink(p));
  return fd;
}
static int writeall(int fd, const void *p, size_t n) {
  while (n) {
    ssize_t k = write(fd, p, n);
    if (k < 0 && errno == EINTR)
      continue;
    if (k <= 0)
      return -1;
    p = (const char *)p + k;
    n -= k;
  }
  return 0;
}
static int mode;
static size_t response_bytes;
static double pausetime = .5;
static size_t callbacks;
static size_t rd(char *p, size_t a, size_t b, void *v) {
  T *t = v;
  ssize_t n;
  do {
    n = read(t->req, p, a * b);
  } while (n < 0 && errno == EINTR);
  return n < 0 ? CURL_READFUNC_ABORT : (size_t)n;
}
static size_t wr(char *p, size_t a, size_t b, void *v) {
  T *t = v;
  size_t n = a * b;
  callbacks++;
  // PAUSE accepts no bytes. Unpause can reenter this callback synchronously.
  if ((mode == 1 && t->id % 2 == 0 && !t->once &&
       t->got >= (response_bytes < 524288 ? 0 : 131072)) ||
      (mode == 2 && !t->once)) {
    t->once = 1;
    t->paused = 1;
    t->resume = now() + pausetime;
    return CURL_WRITEFUNC_PAUSE;
  }
  if (mode == 3)
    usleep(100);
  if (mode == 4 && t->id == 0)
    return CURL_WRITEFUNC_ERROR;
  if (writeall(t->out, p, n))
    return CURL_WRITEFUNC_ERROR;
  t->got += n;
  scratchbytes += n;
  if (mode == 2)
    t->once = 0;
  return n;
}
#define CE(x)                                                                  \
  do {                                                                         \
    CURLcode r_ = (x);                                                         \
    if (r_) {                                                                  \
      fprintf(stderr, "curl %d line %d\n", r_, __LINE__);                      \
      exit(2);                                                                 \
    }                                                                          \
  } while (0)
#define ME(x)                                                                  \
  do {                                                                         \
    CURLMcode r_ = (x);                                                        \
    if (r_) {                                                                  \
      fprintf(stderr, "multi %d line %d\n", r_, __LINE__);                     \
      exit(2);                                                                 \
    }                                                                          \
  } while (0)
int main(int ac, char **av) {
  if (ac != 11)
    return 2;
  int n = atoi(av[1]);
  size_t reqbytes = strtoull(av[2], 0, 10);
  response_bytes = strtoull(av[3], 0, 10);
  int items = atoi(av[4]);
  mode = atoi(av[5]);
  long cache = atol(av[6]), buf = atol(av[7]);
  int h2 = atoi(av[8]);
  assert(n > 0 && n <= 1000 && items > 0 && reqbytes >= (size_t)items);
  struct rlimit lim = {8192, 8192};
  assert(!setrlimit(RLIMIT_NOFILE, &lim));
  start = now();
  sample("cold");
  assert(CRYPTO_set_mem_functions(om, orr, of));
  CE(curl_global_init_mem(CURL_GLOBAL_DEFAULT, cm, freex, cr, cs, cc));
  const curl_version_info_data *vi = curl_version_info(CURLVERSION_NOW);
  printf("{\"version\":\"%s\",\"ssl\":\"%s\",\"features\":%d,\"http2_"
         "supported\":%s,\"http3_supported\":%s,\"nghttp2\":\"%s\"}\n",
         vi->version, vi->ssl_version, vi->features,
         (vi->features & CURL_VERSION_HTTP2) ? "true" : "false",
         (vi->features & CURL_VERSION_HTTP3) ? "true" : "false",
         vi->nghttp2_version ? vi->nghttp2_version : "");
  assert(!strcmp(vi->version, "8.22.0") && strstr(vi->ssl_version, "3.6.3"));
  assert(!h2 || (vi->features & CURL_VERSION_HTTP2));
  CURLM *m = curl_multi_init();
  assert(m);
  if (cache >= 0)
    ME(curl_multi_setopt(m, CURLMOPT_MAXCONNECTS, cache));
  if (h2) {
    ME(curl_multi_setopt(m, CURLMOPT_MAX_HOST_CONNECTIONS, 1L));
    ME(curl_multi_setopt(m, CURLMOPT_MAX_CONCURRENT_STREAMS, 1000L));
  }
  T *ts = calloc(n, sizeof(T));
  assert(ts);
  appbytes = n * sizeof(T);
  struct curl_slist *headers = NULL;
  headers = curl_slist_append(headers, "Expect:");
  assert(headers);
  sample("initialized");
  char block[16384];
  size_t stride = reqbytes / items;
  for (int i = 0; i < n; i++) {
    T *t = &ts[i];
    t->id = i;
    t->req = scratch();
    t->out = scratch();
    SHA256_CTX requesthash;
    unsigned char request_expected[32], request_actual[32];
    SHA256_Init(&requesthash);
    for (size_t o = 0; o < reqbytes;) {
      size_t z = reqbytes - o;
      if (z > sizeof(block))
        z = sizeof(block);
      for (size_t j = 0; j < z; j++)
        block[j] =
            ((o + j + 1) % stride == 0 && (o + j + 1) / stride <= (size_t)items)
                ? '\n'
                : 'a';
      SHA256_Update(&requesthash, block, z);
      assert(!writeall(t->req, block, z));
      o += z;
    }
    SHA256_Final(request_expected, &requesthash);
    assert(lseek(t->req, 0, SEEK_SET) == 0);
    SHA256_Init(&requesthash);
    ssize_t rz;
    while ((rz = read(t->req, block, sizeof(block))) > 0)
      SHA256_Update(&requesthash, block, rz);
    assert(rz == 0);
    SHA256_Final(request_actual, &requesthash);
    assert(!memcmp(request_expected, request_actual, 32));
    assert(lseek(t->req, 0, SEEK_SET) == 0);
    scratchbytes += reqbytes;
    t->e = curl_easy_init();
    assert(t->e);
    CE(curl_easy_setopt(t->e, CURLOPT_URL, av[9]));
    CE(curl_easy_setopt(t->e, CURLOPT_CAINFO, av[10]));
    CE(curl_easy_setopt(t->e, CURLOPT_SSL_OPTIONS,
                        (long)CURLSSLOPT_NO_PARTIALCHAIN));
    CE(curl_easy_setopt(t->e, CURLOPT_PROXY, ""));
    CE(curl_easy_setopt(t->e, CURLOPT_HTTP_VERSION,
                        h2 ? CURL_HTTP_VERSION_2TLS : CURL_HTTP_VERSION_1_1));
    CE(curl_easy_setopt(t->e, CURLOPT_PIPEWAIT, 1L));
    CE(curl_easy_setopt(t->e, CURLOPT_POST, 1L));
    CE(curl_easy_setopt(t->e, CURLOPT_POSTFIELDSIZE_LARGE,
                        (curl_off_t)reqbytes));
    CE(curl_easy_setopt(t->e, CURLOPT_HTTPHEADER, headers));
    CE(curl_easy_setopt(t->e, CURLOPT_READFUNCTION, rd));
    CE(curl_easy_setopt(t->e, CURLOPT_READDATA, t));
    CE(curl_easy_setopt(t->e, CURLOPT_WRITEFUNCTION, wr));
    CE(curl_easy_setopt(t->e, CURLOPT_WRITEDATA, t));
    CE(curl_easy_setopt(t->e, CURLOPT_PRIVATE, t));
    CE(curl_easy_setopt(t->e, CURLOPT_BUFFERSIZE, buf));
    CE(curl_easy_setopt(t->e, CURLOPT_TIMEOUT, 120L));
    ME(curl_multi_add_handle(m, t->e));
  }
  printf("{\"allocation_header_bytes\":%zu,\"transfer_record_bytes\":%zu,"
         "\"measurement_fd_array_bytes\":%zu,\"copy_window_bytes\":%zu}\n",
         sizeof(H), sizeof(T), 8192 * sizeof(struct proc_fdinfo),
         sizeof(block));
  sample("staged");
  int running = 1, done = 0, errors = 0, conns = 0, pausedsample = 0;
  double loaded = now(), last = now();
  while (done < n) {
    ME(curl_multi_perform(m, &running));
    double tm = now();
    for (int i = 0; i < n; i++) {
      T *t = &ts[i];
      if (t->paused && tm >= t->resume) {
        t->paused = 0;
        CE(curl_easy_pause(t->e, CURLPAUSE_CONT));
      }
    }
    int q;
    CURLMsg *msg;
    while ((msg = curl_multi_info_read(m, &q))) {
      if (msg->msg != CURLMSG_DONE)
        continue;
      T *t;
      CE(curl_easy_getinfo(msg->easy_handle, CURLINFO_PRIVATE, &t));
      done++;
      long nc = 0, hv = 0;
      CE(curl_easy_getinfo(t->e, CURLINFO_NUM_CONNECTS, &nc));
      CE(curl_easy_getinfo(t->e, CURLINFO_HTTP_VERSION, &hv));
      conns += nc;
      if (msg->data.result != CURLE_OK) {
        errors++;
        fprintf(stderr, "transfer %d result %d\n", t->id, msg->data.result);
      } else {
        assert(t->got == response_bytes);
        assert(hv == (h2 ? CURL_HTTP_VERSION_2_0 : CURL_HTTP_VERSION_1_1));
      }
      ME(curl_multi_remove_handle(m, t->e));
    }
    if (tm - last > .01) {
      sample(NULL);
      last = tm;
      for (int i = 0; i < n; i++) {
        curl_socket_t s;
        CE(curl_easy_getinfo(ts[i].e, CURLINFO_ACTIVESOCKET, &s));
        int bytes = 0;
        if (s != CURL_SOCKET_BAD && !ioctl(s, FIONREAD, &bytes) &&
            (uint64_t)bytes > maxbacklog)
          maxbacklog = bytes;
      }
    }
    if (!pausedsample && tm - loaded > .25) {
      sample("loaded");
      pausedsample = 1;
    }
    if (tm - start > 125) {
      fprintf(stderr, "deadline\n");
      return 3;
    }
    ME(curl_multi_poll(m, NULL, 0, 5, NULL));
  }
  sample("completed_waiting_validation");
  usleep(200000);
  sample("delayed_validation");
  for (int i = 0; i < n; i++) {
    curl_easy_cleanup(ts[i].e);
    ts[i].e = NULL;
    assert(!close(ts[i].req));
    scratchbytes -= reqbytes;
  }
  sample("transport_released_capture_retained");
  usleep(200000);
  sample("cache_idle");
  double drain_until = now() + 1;
  while (now() < drain_until) {
    ME(curl_multi_perform(m, &running));
    ME(curl_multi_poll(m, NULL, 0, 10, NULL));
    sample(NULL);
  }
  sample("serviced_cache_idle");
  curl_multi_cleanup(m);
  curl_slist_free_all(headers);
  sample("multi_released");
  unsigned char expected[32], actual[32];
  SHA256_CTX hash;
  SHA256_Init(&hash);
  memset(block, 'x', sizeof(block));
  for (size_t o = 0; o < response_bytes;) {
    size_t z = response_bytes - o;
    if (z > sizeof(block))
      z = sizeof(block);
    SHA256_Update(&hash, block, z);
    o += z;
  }
  SHA256_Final(expected, &hash);
  for (int i = 0; i < n; i++) {
    T *t = &ts[i];
    assert(lseek(t->out, 0, SEEK_SET) == 0);
    SHA256_Init(&hash);
    ssize_t z;
    while ((z = read(t->out, block, sizeof(block))) > 0)
      SHA256_Update(&hash, block, z);
    assert(z == 0);
    SHA256_Final(actual, &hash);
    if (!(mode == 4 && i == 0))
      assert(!memcmp(expected, actual, 32));
    assert(!close(t->out));
    scratchbytes -= t->got;
  }
  free(ts);
  appbytes = 0;
  curl_global_cleanup();
  OPENSSL_cleanup();
  assert(live[0] == 0 && live[1] == 0 && blocks[0] == 0 && blocks[1] == 0);
  sample("cleaned");
  usleep(250000);
  sample("retained_idle");
  printf("{\"completed\":%d,\"errors\":%d,\"connections_created\":%d,"
         "\"callbacks\":%zu,\"integrity\":true}\n",
         done, errors, conns, callbacks);
  return errors != (mode == 4 ? 1 : 0);
}
