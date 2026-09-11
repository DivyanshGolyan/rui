/* Fault controls for the fixture's ownership boundary; not production faults.
 */
#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
typedef struct {
  int occupied, pending, sealed, published;
  _Atomic int fenced;
  char *window;
  int gate[2], target;
} Owner;
static void *callback(void *p) {
  Owner *o = p;
  char byte;
  assert(read(o->gate[0], &byte, 1) == 1);
  /* Completion may still reference its input after cancellation. */
  assert(o->window[0] == 'a');
  assert(o->occupied && o->pending);
  if (!o->sealed)
    assert(write(o->target, o->window, 16384) == 16384);
  if (!o->fenced)
    o->published++;
  return NULL;
}
static int cleanup(Owner *o) {
  if (o->pending)
    return EBUSY;
  free(o->window);
  if (o->target >= 0) {
    assert(close(o->target) == 0);
    o->target = -1;
  }
  o->window = NULL;
  o->occupied = 0;
  return 0;
}
int main(int argc, char **argv) {
  Owner o = {.occupied = 1, .pending = 1};
  char target[] = "/tmp/onepage-lifetime-pending-XXXXXX";
  o.target = mkstemp(target);
  assert(o.target >= 0 && unlink(target) == 0);
  o.window = malloc(16384);
  assert(o.window);
  memset(o.window, 'a', 16384);
  assert(pipe(o.gate) == 0);
  pthread_t thread;
  assert(pthread_create(&thread, NULL, callback, &o) == 0);
  o.fenced = 1;
  assert(cleanup(&o) == EBUSY && o.occupied && o.window);
  if (argc > 1 && !strcmp(argv[1], "broken-release"))
    free(o.window);
  assert(write(o.gate[1], "x", 1) == 1);
  assert(pthread_join(thread, NULL) == 0);
  o.pending = 0;
  assert(!o.published);
  assert(cleanup(&o) == 0);
  close(o.gate[0]);
  close(o.gate[1]);
  /* A saved result can outlive a delayed callback's physical cleanup. */
  Owner settled = {
      .occupied = 1, .pending = 1, .fenced = 1, .sealed = 1, .published = 1};
  char second[] = "/tmp/onepage-lifetime-settled-XXXXXX";
  settled.target = mkstemp(second);
  assert(settled.target >= 0 && unlink(second) == 0);
  settled.window = malloc(16384);
  assert(settled.window);
  memset(settled.window, 'a', 16384);
  assert(pipe(settled.gate) == 0);
  assert(pthread_create(&thread, NULL, callback, &settled) == 0);
  assert(cleanup(&settled) == EBUSY && settled.occupied &&
         settled.published == 1);
  assert(write(settled.gate[1], "x", 1) == 1);
  assert(pthread_join(thread, NULL) == 0);
  struct stat observed;
  assert(fstat(settled.target, &observed) == 0 && observed.st_size == 0);
  assert(settled.published == 1);
  settled.pending = 0;
  assert(cleanup(&settled) == 0);
  close(settled.gate[0]);
  close(settled.gate[1]);
  /* A real failed syscall cannot become a complete capture or success. */
  char name[] = "/tmp/onepage-lifetime-fault-XXXXXX";
  int fd = mkstemp(name);
  assert(fd >= 0);
  unlink(name);
  assert(write(fd, "a\n", 2) == 2);
  close(fd);
  errno = 0;
  assert(write(fd, "b", 1) == -1 && errno == EBADF);
  Owner failed = {.occupied = 1, .fenced = 1, .target = -1};
  assert(!failed.sealed && !failed.published);
  assert(cleanup(&failed) == 0);
  puts("{\"pending_cleanup_rejected\":true,\"delayed_callback_drained\":true,"
       "\"cancelled_publication_suppressed\":true,\"failed_capture_not_"
       "sealed\":true,\"released_after_join\":true,\"settled_credit_held_"
       "through_callback\":true,\"sealed_source_not_written\":true}");
}
