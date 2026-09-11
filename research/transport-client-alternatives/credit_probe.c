/* Protocol-only credit probe: no sockets, TLS, scratch, or production code. */
#include <nghttp2/nghttp2.h>
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#define BODY (256 * 1024)
static size_t sent[2], received[2];
static int index_for(int32_t id) { assert(id == 1 || id == 3); return (id - 1) / 2; }
static nghttp2_ssize body(nghttp2_session *s, int32_t id, uint8_t *buf,
                         size_t len, uint32_t *flags, nghttp2_data_source *source, void *u) {
  (void)s; (void)source; (void)u;
  int i = index_for(id);
  if (len > BODY - sent[i]) len = BODY - sent[i];
  for (size_t j = 0; j < len; ++j) buf[j] = (uint8_t)((sent[i] + j + i) % 251);
  sent[i] += len;
  if (sent[i] == BODY) *flags |= NGHTTP2_DATA_FLAG_EOF;
  return (nghttp2_ssize)len;
}
static int capture(nghttp2_session *s, uint8_t flags, int32_t id,
                   const uint8_t *data, size_t len, void *u) {
  (void)s; (void)flags; (void)u;
  int i = index_for(id);
  assert(len <= BODY - received[i]);
  for (size_t j = 0; j < len; ++j) assert(data[j] == (uint8_t)((received[i] + j + i) % 251));
  received[i] += len;
  return 0;
}
static int transfer(nghttp2_session *from, nghttp2_session *to) {
  const uint8_t *data;
  nghttp2_ssize n = nghttp2_session_mem_send2(from, &data);
  assert(n >= 0);
  if (n) assert(nghttp2_session_mem_recv2(to, data, (size_t)n) == n);
  return n != 0;
}
static void pump(nghttp2_session *client, nghttp2_session *server) {
  for (int step = 0; step < 10000; ++step) {
    int progress = transfer(client, server);
    progress |= transfer(server, client);
    if (!progress) return;
  }
  assert(!"pump failed to quiesce");
}
#define NV(k,v) {(uint8_t *)k,(uint8_t *)v,sizeof(k)-1,sizeof(v)-1,NGHTTP2_NV_FLAG_NONE}
static void run(int manual) {
  memset(sent, 0, sizeof(sent)); memset(received, 0, sizeof(received));
  nghttp2_session *client, *server;
  nghttp2_session_callbacks *cb;
  nghttp2_option *opt;
  assert(!nghttp2_option_new(&opt));
  nghttp2_option_set_no_auto_window_update(opt, manual);
  assert(!nghttp2_session_callbacks_new(&cb));
  nghttp2_session_callbacks_set_on_data_chunk_recv_callback(cb, capture);
  assert(!nghttp2_session_client_new2(&client, cb, NULL, opt));
  nghttp2_session_callbacks_del(cb);
  assert(!nghttp2_session_callbacks_new(&cb));
  assert(!nghttp2_session_server_new(&server, cb, NULL));
  nghttp2_session_callbacks_del(cb); nghttp2_option_del(opt);
  nghttp2_settings_entry setting = {NGHTTP2_SETTINGS_INITIAL_WINDOW_SIZE, 16384};
  assert(!nghttp2_submit_settings(client, 0, &setting, 1));
  assert(!nghttp2_submit_settings(server, 0, NULL, 0));
  pump(client, server);
  nghttp2_nv req[] = {NV(":method","GET"),NV(":scheme","https"),NV(":authority","fixture"),NV(":path","/")};
  assert(nghttp2_submit_request2(client, NULL, req, 4, NULL, NULL) == 1);
  assert(nghttp2_submit_request2(client, NULL, req, 4, NULL, NULL) == 3);
  pump(client, server);
  nghttp2_nv res[] = {NV(":status","200")};
  nghttp2_data_provider2 provider = {{0}, body};
  assert(!nghttp2_submit_response2(server, 1, res, 1, &provider));
  assert(!nghttp2_submit_response2(server, 3, res, 1, &provider));
  pump(client, server);
  printf("{\"manual\":%d,\"phase\":\"withheld\",\"received\":[%zu,%zu]}\n", manual, received[0], received[1]);
  if (manual) {
    assert(received[0] == 16384 && received[1] == 16384);
    /* Connection credit alone cannot reopen either exhausted stream. */
    assert(!nghttp2_session_consume_connection(client, 32768));
    pump(client, server);
    assert(received[0] == 16384 && received[1] == 16384);
    assert(!nghttp2_session_consume_stream(client, 1, 16384));
    pump(client, server);
    assert(received[0] == 32768 && received[1] == 16384);
    printf("{\"manual\":1,\"phase\":\"release_stream_1\",\"received\":[%zu,%zu]}\n", received[0], received[1]);
    for (int i = 0; i < 2; ++i) {
      size_t accounted = i == 0 ? 16384 : 0;
      /* Initial connection consumption above covered each stream's first chunk. */
      size_t conn_accounted = 16384;
      while (received[i] < BODY) {
        size_t current = received[i];
        assert(!nghttp2_session_consume_connection(client, current - conn_accounted));
        assert(!nghttp2_session_consume_stream(client, 1 + 2*i, current - accounted));
        accounted = current; conn_accounted = current;
        pump(client, server);
        assert(received[i] > current);
      }
      if (i == 0) assert(received[1] == 16384);
    }
  }
  assert(received[0] == BODY && received[1] == BODY);
  printf("{\"manual\":%d,\"phase\":\"complete_verified\",\"received\":[%zu,%zu]}\n", manual, received[0], received[1]);
  nghttp2_session_del(client); nghttp2_session_del(server);
}
int main(void) { printf("{\"nghttp2\":\"%s\"}\n", nghttp2_version(0)->version_str); run(1); run(0); }
