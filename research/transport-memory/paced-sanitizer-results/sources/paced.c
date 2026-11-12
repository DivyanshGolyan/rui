/* Reuse the audited allocation/OS instrumentation; this is a separate
 * prototype. */
#define main baseline_probe_main
#include "probe.c"
#undef main
#include <fcntl.h>
#include <pthread.h>
#include <sys/socket.h>
#include <sys/un.h>

static size_t fixture_tokens, fixture_events, fixture_payload;
static size_t make_delta(char *out, size_t index) {
  int prefix = sprintf(out,
                       "event: response.output_text.delta\ndata: "
                       "{\"type\":\"response.output_text.delta\",\"sequence_"
                       "number\":\"%05zu\",\"delta\":\"",
                       index);
  size_t length = prefix;
  for (size_t i = 0; i < fixture_tokens; i++) {
    memcpy(out + length, "text", 4);
    length += 4;
  }
  memcpy(out + length, "\"}\n\n", 4);
  return length + 4;
}
static void verify_fixture(const char *bytes, size_t length, size_t offset) {
  char record[2048], head[256];
  size_t record_length = make_delta(record, 0);
  int head_length =
      snprintf(head, sizeof(head),
               "event: response.completed\ndata: "
               "{\"type\":\"response.completed\",\"sequence_number\":\"%05zu\","
               "\"response\":{\"status\":\"completed\",\"text\":\"",
               fixture_events);
  assert(head_length > 0 && head_length < (int)sizeof(head));
  const char *tail = "\"}}\n\n";
  assert(fixture_payload == record_length * fixture_events + head_length +
                                fixture_events * fixture_tokens * 4 +
                                strlen(tail));
  while (length) {
    size_t take;
    if (offset < record_length * fixture_events) {
      size_t index = offset / record_length, pos = offset % record_length;
      assert(make_delta(record, index) == record_length);
      take = record_length - pos;
      if (take > length)
        take = length;
      assert(!memcmp(bytes, record + pos, take));
    } else {
      size_t pos = offset - record_length * fixture_events;
      if (pos < (size_t)head_length) {
        take = head_length - pos;
        if (take > length)
          take = length;
        assert(!memcmp(bytes, head + pos, take));
      } else if (pos <
                 (size_t)head_length + fixture_events * fixture_tokens * 4) {
        take = head_length + fixture_events * fixture_tokens * 4 - pos;
        if (take > length)
          take = length;
        for (size_t i = 0; i < take; i++)
          assert(bytes[i] == "text"[(pos - head_length + i) % 4]);
      } else {
        size_t at = pos - head_length - fixture_events * fixture_tokens * 4;
        take = strlen(tail) - at;
        if (take > length)
          take = length;
        assert(take && !memcmp(bytes, tail + at, take));
      }
    }
    bytes += take;
    offset += take;
    length -= take;
  }
}

#define CHUNK 16384
struct Capture {
  CURL *easy;
  int request_fd, capture_fd, id, paused, resume_failed;
  size_t accepted;
  _Atomic size_t written;
  _Atomic int failed;
};
struct Chunk {
  struct Capture *capture;
  size_t size;
  char bytes[CHUNK];
};
struct Sink {
  pthread_mutex_t mutex;
  pthread_cond_t changed;
  struct Chunk *chunks;
  size_t head, count, capacity, bytes, peak_bytes;
  int stop, strategy, delay_us, stall_ms, fail;
  _Atomic int stalled;
  _Atomic size_t written;
  CURLM *multi;
  struct Capture *transfers;
  int population;
  size_t stall_after;
};
static struct Sink sink;
static int control_fd;
static size_t controls, pause_calls;
static double max_callback, max_perform, max_unpause;
static _Atomic double max_write;
static int burst_id;
static _Atomic int active_transfers;
static uint64_t nano(void) { return (uint64_t)(now() * 1e9); }
static void control_service(void) {
  for (;;) {
    struct sockaddr_un peer;
    socklen_t length = sizeof(peer);
    uint64_t packet[2];
    ssize_t n = recvfrom(control_fd, packet, sizeof(packet), 0,
                         (struct sockaddr *)&peer, &length);
    if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))
      return;
    if (n < 0 && errno == EINTR)
      continue;
    assert(n == sizeof(packet));
    assert(sendto(control_fd, packet, sizeof(packet), 0,
                  (struct sockaddr *)&peer, length) == sizeof(packet));
    controls++;
  }
}
static void phase(const char *name) {
  pthread_mutex_lock(&sink.mutex);
  size_t queued = sink.bytes, count = sink.count, peakq = sink.peak_bytes;
  pthread_mutex_unlock(&sink.mutex);
  printf(
      "{\"event\":\"%s\",\"burst\":%d,\"monotonic_ns\":%llu,\"written\":%zu,"
      "\"queue_bytes\":%zu,\"queue_chunks\":%zu,\"queue_peak_bytes\":%zu,"
      "\"controls_serviced\":%zu,\"pause_calls\":%zu,\"callback_max_s\":%.9f,"
      "\"perform_max_s\":%.9f,\"unpause_max_s\":%.9f,\"write_max_s\":%.9f}\n",
      name, burst_id, (unsigned long long)nano(), sink.written, queued, count,
      peakq, controls, pause_calls, max_callback, max_perform, max_unpause,
      max_write);
  if (appbytes) {
    size_t accepted = 0, minimum = SIZE_MAX, maximum = 0;
    for (int i = 0; i < sink.population; i++) {
      size_t written = sink.transfers[i].written;
      accepted += sink.transfers[i].accepted;
      if (written < minimum)
        minimum = written;
      if (written > maximum)
        maximum = written;
    }
    printf("{\"capture_progress\":%d,\"monotonic_ns\":%llu,\"accepted\":%zu,"
           "\"min_written\":%zu,\"max_written\":%zu}\n",
           burst_id, (unsigned long long)nano(), accepted, minimum, maximum);
  }
  struct rusage usage;
  assert(!getrusage(RUSAGE_SELF, &usage));
  printf("{\"cpu_event\":\"%s\",\"burst\":%d,\"cpu_seconds\":%.9f}\n", name,
         burst_id,
         usage.ru_utime.tv_sec + usage.ru_utime.tv_usec / 1e6 +
             usage.ru_stime.tv_sec + usage.ru_stime.tv_usec / 1e6);
  sample(name);
}
static void capture_write(struct Capture *t, const void *bytes, size_t length) {
  double begin = now();
  if (sink.stall_ms && !sink.stalled) {
    size_t minimum = SIZE_MAX, maximum = 0;
    for (int i = 0; i < sink.population; i++) {
      size_t value = sink.transfers[i].written;
      if (value < minimum)
        minimum = value;
      if (value > maximum)
        maximum = value;
    }
    if (minimum >= sink.stall_after && !atomic_exchange(&sink.stalled, 1)) {
      printf(
          "{\"stall_started\":true,\"burst\":%d,\"monotonic_ns\":%llu,\"active_"
          "transfers\":%d,\"min_written\":%zu,\"max_written\":%zu}\n",
          burst_id, (unsigned long long)nano(), active_transfers, minimum,
          maximum);
      fflush(stdout);
      usleep(sink.stall_ms * 1000);
    }
  }
  if (sink.delay_us)
    usleep(sink.delay_us);
  if (!t->failed) {
    if (sink.fail && t->id == 0 && t->written >= CHUNK)
      t->failed = 1;
    else if (writeall(t->capture_fd, bytes, length))
      t->failed = 1;
    else {
      t->written += length;
      sink.written += length;
      if (t->written == fixture_payload)
        printf("{\"capture_finished\":%d,\"monotonic_ns\":%llu}\n", t->id,
               (unsigned long long)nano());
    }
  }
  double duration = now() - begin;
  /* Only the capture owner updates this; active snapshots use atomic reads. */
  if (duration > max_write)
    max_write = duration;
}
static int drain_one(void) {
  pthread_mutex_lock(&sink.mutex);
  if (!sink.count) {
    pthread_mutex_unlock(&sink.mutex);
    return 0;
  }
  struct Chunk *chunk = &sink.chunks[sink.head];
  pthread_mutex_unlock(&sink.mutex);
  /* This occupied slot cannot be reused while its write is pending. */
  capture_write(chunk->capture, chunk->bytes, chunk->size);
  pthread_mutex_lock(&sink.mutex);
  sink.bytes -= chunk->size;
  sink.count--;
  sink.head = (sink.head + 1) % sink.capacity;
  pthread_mutex_unlock(&sink.mutex);
  return 1;
}
static void *writer(void *unused) {
  (void)unused;
  for (;;) {
    pthread_mutex_lock(&sink.mutex);
    while (!sink.count && !sink.stop)
      pthread_cond_wait(&sink.changed, &sink.mutex);
    int done = sink.stop && !sink.count;
    pthread_mutex_unlock(&sink.mutex);
    if (done)
      return NULL;
    drain_one();
    ME(curl_multi_wakeup(sink.multi));
  }
}
static size_t capture_callback(char *bytes, size_t a, size_t b, void *ctx) {
  double begin = now();
  struct Capture *t = ctx;
  size_t length = a * b, result = length;
  assert(length <= CHUNK);
  if (t->failed)
    result = CURL_WRITEFUNC_ERROR;
  else if (sink.strategy == 0) {
    capture_write(t, bytes, length);
    if (t->failed)
      result = CURL_WRITEFUNC_ERROR;
    else
      t->accepted += length;
  } else {
    pthread_mutex_lock(&sink.mutex);
    if (sink.count == sink.capacity) {
      t->paused = 1;
      pause_calls++;
      result = CURL_WRITEFUNC_PAUSE;
    } else {
      struct Chunk *c = &sink.chunks[(sink.head + sink.count) % sink.capacity];
      c->capture = t;
      c->size = length;
      memcpy(c->bytes, bytes, length);
      sink.count++;
      sink.bytes += length;
      if (sink.bytes > sink.peak_bytes)
        sink.peak_bytes = sink.bytes;
      t->accepted += length;
      pthread_cond_signal(&sink.changed);
    }
    pthread_mutex_unlock(&sink.mutex);
  }
  double duration = now() - begin;
  if (duration > max_callback)
    max_callback = duration;
  return result;
}
static size_t request_read(char *bytes, size_t a, size_t b, void *ctx) {
  struct Capture *t = ctx;
  ssize_t length;
  do {
    length = read(t->request_fd, bytes, a * b);
  } while (length < 0 && errno == EINTR);
  return length < 0 ? CURL_READFUNC_ABORT : (size_t)length;
}
static int queue_count(void) {
  pthread_mutex_lock(&sink.mutex);
  int n = sink.count;
  pthread_mutex_unlock(&sink.mutex);
  return n;
}
static void tick(CURLM *m, int *running) {
  control_service();
  double begin = now();
  ME(curl_multi_perform(m, running));
  double duration = now() - begin;
  if (duration > max_perform)
    max_perform = duration;
  control_service();
}
static void finish_handle(struct Capture *t, CURLM *m, CURLcode result,
                          int *connections, int *errors, curl_off_t *setup,
                          curl_off_t *handshake) {
  long nc = 0, status = 0;
  curl_off_t app = 0, tcp = 0;
  CE(curl_easy_getinfo(t->easy, CURLINFO_NUM_CONNECTS, &nc));
  CE(curl_easy_getinfo(t->easy, CURLINFO_RESPONSE_CODE, &status));
  CE(curl_easy_getinfo(t->easy, CURLINFO_APPCONNECT_TIME_T, &app));
  CE(curl_easy_getinfo(t->easy, CURLINFO_CONNECT_TIME_T, &tcp));
  *connections += nc;
  if (nc) {
    *setup += app;
    assert(app >= tcp);
    *handshake += app - tcp;
  }
  if (result != CURLE_OK) {
    (*errors)++;
    assert(sink.fail && t->id == 0);
  } else
    assert(status == 200);
  ME(curl_multi_remove_handle(m, t->easy));
  curl_easy_cleanup(t->easy);
  t->easy = NULL;
  assert(!close(t->request_fd));
  scratchbytes -= 1024;
  active_transfers--;
}
int main(int argc, char **argv) {
  assert(argc == 20);
  fixture_tokens = strtoull(argv[18], NULL, 10);
  fixture_events = strtoull(argv[19], NULL, 10);
  assert(fixture_tokens > 0 && fixture_tokens <= 256 && fixture_events > 0 &&
         fixture_events < 100000);
  sink.stall_after = strtoull(argv[13], NULL, 10);
  int n = atoi(argv[1]), protocol = atoi(argv[2]), bursts = atoi(argv[3]);
  size_t payload = strtoull(argv[4], NULL, 10);
  fixture_payload = payload;
  sink.strategy = atoi(argv[5]);
  sink.delay_us = atoi(argv[6]);
  sink.stall_ms = atoi(argv[7]);
  sink.capacity = atoi(argv[8]);
  long cache = atol(argv[9]);
  curl_off_t rate = strtoll(argv[14], NULL, 10);
  long receive = atol(argv[15]), hosts = atol(argv[16]),
       streams = atol(argv[17]);
  sink.fail = atoi(argv[12]);
  const char *base = argv[10], *directory = argv[11];
  assert(n > 0 && n <= 1000 && bursts > 0 && bursts <= 4 &&
         payload <= 16777216 &&
         (payload + 1024) * n <= (size_t)2 * 1024 * 1024 * 1024);
  assert(sink.capacity > 0 && sink.capacity <= 256 && sink.strategy >= 0 &&
         sink.strategy <= 2 && sink.delay_us >= 0 && sink.delay_us <= 10000 &&
         sink.stall_ms >= 0 && sink.stall_ms <= 5000);
  struct rlimit limit = {8192, 8192};
  assert(!setrlimit(RLIMIT_NOFILE, &limit));
  start = now();
  pthread_mutex_init(&sink.mutex, NULL);
  pthread_cond_init(&sink.changed, NULL);
  char path[100];
  assert(snprintf(path, sizeof(path), "%s/control", directory) <
         (int)sizeof(path));
  control_fd = socket(AF_UNIX, SOCK_DGRAM, 0);
  assert(control_fd >= 0);
  int space = 262144;
  assert(!setsockopt(control_fd, SOL_SOCKET, SO_RCVBUF, &space, sizeof(space)));
  assert(!fcntl(control_fd, F_SETFL, O_NONBLOCK));
  struct sockaddr_un address = {.sun_family = AF_UNIX};
  strcpy(address.sun_path, path);
  assert(!bind(control_fd, (struct sockaddr *)&address, sizeof(address)));
  phase("cold");
  printf("{\"ready\":true,\"monotonic_ns\":%llu}\n",
         (unsigned long long)nano());
  fflush(stdout);
  while (!controls) {
    control_service();
    usleep(1000);
  }
  assert(CRYPTO_set_mem_functions(om, orr, of));
  CE(curl_global_init_mem(CURL_GLOBAL_DEFAULT, cm, freex, cr, cs, cc));
  const curl_version_info_data *v = curl_version_info(CURLVERSION_NOW);
  assert(!strcmp(v->version, "8.22.0") && strstr(v->ssl_version, "3.6.3") &&
         !strcmp(v->nghttp2_version, "1.70.0"));
  assert(v->features & CURL_VERSION_ASYNCHDNS);
  assert(v->features & CURL_VERSION_THREADSAFE);
  printf("{\"curl\":\"%s\",\"tls\":\"%s\",\"nghttp2\":\"%s\",\"capture_record_"
         "bytes\":%zu,\"queue_slot_bytes\":%zu}\n",
         v->version, v->ssl_version, v->nghttp2_version, sizeof(struct Capture),
         sizeof(struct Chunk));
  CURLM *m = curl_multi_init();
  assert(m);
  sink.multi = m;
  ME(curl_multi_setopt(m, CURLMOPT_MAXCONNECTS, cache));
  if (protocol == 2) {
    ME(curl_multi_setopt(m, CURLMOPT_MAX_HOST_CONNECTIONS, hosts));
    ME(curl_multi_setopt(m, CURLMOPT_MAX_CONCURRENT_STREAMS, streams));
  }
  struct curl_slist *headers = curl_slist_append(NULL, "Expect:");
  assert(headers);
  for (burst_id = 0; burst_id < bursts; burst_id++) {
    peak[0] = live[0];
    peak[1] = live[1];
    sink.head = sink.count = sink.bytes = sink.peak_bytes = 0;
    sink.written = 0;
    sink.stop = 0;
    sink.stalled = 0;
    max_callback = max_perform = max_unpause = max_write = 0;
    pause_calls = 0;
    phase("burst_start");
    struct Capture *transfers = calloc(n, sizeof(*transfers));
    assert(transfers);
    sink.transfers = transfers;
    sink.population = n;
    active_transfers = n;
    sink.chunks =
        sink.strategy ? calloc(sink.capacity, sizeof(struct Chunk)) : NULL;
    assert(!sink.strategy || sink.chunks);
    appbytes = n * sizeof(*transfers) +
               (sink.strategy ? sink.capacity * sizeof(struct Chunk) : 0);
    char block[CHUNK];
    memset(block, 'a', 1024);
    char url[256], cert[160];
    assert(snprintf(url, sizeof(url), "%s/%d", base, burst_id) <
           (int)sizeof(url));
    assert(snprintf(cert, sizeof(cert), "%s/cert.pem", directory) <
           (int)sizeof(cert));
    for (int i = 0; i < n; i++) {
      struct Capture *t = &transfers[i];
      t->id = i;
      t->request_fd = scratch();
      t->capture_fd = scratch();
      assert(!writeall(t->request_fd, block, 1024));
      assert(lseek(t->request_fd, 0, SEEK_SET) == 0);
      char verify[1024];
      assert(read(t->request_fd, verify, sizeof(verify)) == sizeof(verify) &&
             !memcmp(verify, block, sizeof(verify)));
      assert(lseek(t->request_fd, 0, SEEK_SET) == 0);
      scratchbytes += 1024;
      t->easy = curl_easy_init();
      assert(t->easy);
      CE(curl_easy_setopt(t->easy, CURLOPT_URL, url));
      CE(curl_easy_setopt(t->easy, CURLOPT_CAINFO, cert));
      CE(curl_easy_setopt(t->easy, CURLOPT_PROXY, ""));
      CE(curl_easy_setopt(t->easy, CURLOPT_POST, 1L));
      CE(curl_easy_setopt(t->easy, CURLOPT_POSTFIELDSIZE_LARGE,
                          (curl_off_t)1024));
      CE(curl_easy_setopt(t->easy, CURLOPT_HTTPHEADER, headers));
      CE(curl_easy_setopt(t->easy, CURLOPT_READFUNCTION, request_read));
      CE(curl_easy_setopt(t->easy, CURLOPT_READDATA, t));
      CE(curl_easy_setopt(t->easy, CURLOPT_WRITEFUNCTION, capture_callback));
      CE(curl_easy_setopt(t->easy, CURLOPT_WRITEDATA, t));
      CE(curl_easy_setopt(t->easy, CURLOPT_PRIVATE, t));
      CE(curl_easy_setopt(t->easy, CURLOPT_HTTP_VERSION,
                          protocol == 2 ? CURL_HTTP_VERSION_2TLS
                                        : CURL_HTTP_VERSION_1_1));
      CE(curl_easy_setopt(t->easy, CURLOPT_PIPEWAIT, 1L));
      CE(curl_easy_setopt(t->easy, CURLOPT_UPLOAD_BUFFERSIZE, 16384L));
      CE(curl_easy_setopt(t->easy, CURLOPT_MAX_RECV_SPEED_LARGE, rate));
      CE(curl_easy_setopt(t->easy, CURLOPT_BUFFERSIZE, receive));
      CE(curl_easy_setopt(t->easy, CURLOPT_TIMEOUT, 120L));
      ME(curl_multi_add_handle(m, t->easy));
      control_service();
    }
    pthread_t worker;
    if (sink.strategy == 2)
      assert(!pthread_create(&worker, NULL, writer, NULL));
    phase("transfer_start");
    int running = 1, done = 0, transport_errors = 0, new_connections = 0;
    curl_off_t connect_us = 0, handshake_us = 0;
    double last = now(), began = now();
    size_t cursor = 0;
    while (done < n || queue_count()) {
      assert(now() - began < 125);
      tick(m, &running);
      if (sink.strategy == 1) {
        drain_one();
        control_service();
      }
      for (int j = 0; j < n; j++) {
        struct Capture *t = &transfers[(cursor + j) % n];
        if (t->paused && t->easy && queue_count() < (int)sink.capacity) {
          t->paused = 0;
          double begin = now();
          CURLcode result = curl_easy_pause(t->easy, CURLPAUSE_CONT);
          if (result != CURLE_OK) {
            assert(t->failed && result == CURLE_WRITE_ERROR);
            t->resume_failed = result;
          }
          double duration = now() - begin;
          if (duration > max_unpause)
            max_unpause = duration;
          control_service();
        }
      }
      cursor = (cursor + 1) % n;
      int remaining;
      CURLMsg *msg;
      while ((msg = curl_multi_info_read(m, &remaining))) {
        if (msg->msg != CURLMSG_DONE)
          continue;
        struct Capture *t;
        CE(curl_easy_getinfo(msg->easy_handle, CURLINFO_PRIVATE, &t));
        if (msg->data.result == CURLE_OK) {
          long hv = 0;
          CE(curl_easy_getinfo(t->easy, CURLINFO_HTTP_VERSION, &hv));
          assert(t->accepted == payload &&
                 hv == (protocol == 2 ? CURL_HTTP_VERSION_2_0
                                      : CURL_HTTP_VERSION_1_1));
        }
        finish_handle(t, m, msg->data.result, &new_connections,
                      &transport_errors, &connect_us, &handshake_us);
        done++;
        control_service();
      }
      for (int i = 0; i < n; i++)
        if (transfers[i].easy && transfers[i].resume_failed) {
          finish_handle(&transfers[i], m, (CURLcode)transfers[i].resume_failed,
                        &new_connections, &transport_errors, &connect_us,
                        &handshake_us);
          done++;
          control_service();
        }
      if (now() - last > .1) {
        scratchbytes = (size_t)(n - done) * 1024 + sink.written;
        phase("active");
        last = now();
      }
      struct curl_waitfd extra = {.fd = control_fd, .events = CURL_WAIT_POLLIN};
      ME(curl_multi_poll(m, &extra, 1,
                         sink.strategy == 1 && queue_count() ? 0 : 2, NULL));
    }
    if (sink.strategy == 2) {
      pthread_mutex_lock(&sink.mutex);
      sink.stop = 1;
      pthread_cond_signal(&sink.changed);
      pthread_mutex_unlock(&sink.mutex);
      assert(!pthread_join(worker, NULL));
    }
    scratchbytes = sink.written;
    phase("capture_complete");
    printf("{\"burst_summary\":%d,\"connections_created\":%d,\"new_connection_"
           "appconnect_us_sum\":%lld,\"handshake_phase_us_sum\":%lld,"
           "\"transport_errors\":%d,\"capture_bytes\":"
           "%zu,\"capture_seconds\":%.9f}\n",
           burst_id, new_connections, (long long)connect_us,
           (long long)handshake_us, transport_errors, (size_t)sink.written,
           now() - began);
    int ignored = 0;
    double until = now() + .2;
    while (now() < until) {
      tick(m, &ignored);
      struct curl_waitfd extra = {.fd = control_fd, .events = CURL_WAIT_POLLIN};
      ME(curl_multi_poll(m, &extra, 1, 5, NULL));
    }
    phase("validation_delayed");
    int failures = 0;
    size_t verified = 0;
    for (int i = 0; i < n; i++) {
      struct Capture *t = &transfers[i];
      assert(lseek(t->capture_fd, 0, SEEK_SET) == 0);
      size_t bytes = 0;
      ssize_t got;
      while ((got = read(t->capture_fd, block, sizeof(block))) > 0) {
        verify_fixture(block, got, bytes);
        bytes += got;
        control_service();
      }
      assert(got == 0 && bytes == t->written);
      if (t->failed) {
        failures++;
        assert(sink.fail && i == 0);
      } else {
        assert(bytes == payload);
        verified += bytes;
      }
      assert(!close(t->capture_fd));
      scratchbytes -= bytes;
    }
    assert(failures == (sink.fail ? 1 : 0));
    free(transfers);
    free(sink.chunks);
    sink.chunks = NULL;
    appbytes = 0;
    printf("{\"verified_burst\":%d,\"verified_bytes\":%zu,\"capture_failures\":"
           "%d}\n",
           burst_id, verified, failures);
    phase("captures_released");
    until = now() + 1;
    while (now() < until) {
      tick(m, &ignored);
      struct curl_waitfd extra = {.fd = control_fd, .events = CURL_WAIT_POLLIN};
      ME(curl_multi_poll(m, &extra, 1, 10, NULL));
    }
    phase("serviced_idle");
  }
  curl_multi_cleanup(m);
  curl_slist_free_all(headers);
  phase("multi_released");
  curl_global_cleanup();
  OPENSSL_cleanup();
  assert(!live[0] && !live[1] && !appbytes && !scratchbytes);
  phase("cleaned");
  printf("{\"stop_controls\":true}\n");
  fflush(stdout);
  double until = now() + 2;
  while (now() < until) {
    control_service();
    usleep(1000);
  }
  assert(!close(control_fd));
  assert(!unlink(path));
  phase("retained_idle");
  pthread_cond_destroy(&sink.changed);
  pthread_mutex_destroy(&sink.mutex);
  printf("{\"success\":true}\n");
  return 0;
}
