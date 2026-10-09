/* Coordinated faults at libc boundaries; no timing-based completion oracle. */
#include <dlfcn.h>
#include <errno.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <unistd.h>

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t changed = PTHREAD_COND_INITIALIZER;
static int entered, released, completed, restored, joined;
static pthread_t drain_id, admission_id;
static int admission_entered, admission_joined;
static _Thread_local int drain_thread;
struct start { void *(*run)(void *); void *arg; };

static void *run(void *raw) {
    struct start value = *(struct start *)raw;
    free(raw);
    void *result = value.run(value.arg);
    if (drain_thread) {
        pthread_mutex_lock(&lock);
        completed = 1; /* Zig Drain.run has published result AND done. */
        pthread_cond_broadcast(&changed);
        pthread_mutex_unlock(&lock);
    }
    return result;
}

int pthread_create(pthread_t *thread, const pthread_attr_t *attrs, void *(*fn)(void *), void *arg) {
    int (*forward)(pthread_t *, const pthread_attr_t *, void *(*)(void *), void *) = dlsym(RTLD_NEXT, "pthread_create");
    struct start *value = malloc(sizeof(*value));
    if (!forward || !value) _exit(90);
    *value = (struct start){ fn, arg };
    int rc = forward(thread, attrs, run, value);
    if (rc) free(value);
    return rc;
}

int pthread_join(pthread_t thread, void **result) {
    int (*forward)(pthread_t, void **) = dlsym(RTLD_NEXT, "pthread_join");
    if (!forward) _exit(91);
    int rc = forward(thread, result);
    pthread_mutex_lock(&lock);
    if (!rc && entered && pthread_equal(thread, drain_id)) joined++;
    if (!rc && admission_entered && pthread_equal(thread, admission_id)) admission_joined++;
    pthread_mutex_unlock(&lock);
    return rc;
}

int tcdrain(int fd) {
    int (*forward)(int) = dlsym(RTLD_NEXT, "tcdrain");
    if (!forward || fd != 1) _exit(92);
    drain_thread = 1;
    pthread_mutex_lock(&lock);
    entered = 1;
    drain_id = pthread_self();
    pthread_cond_broadcast(&changed);
    while (!released) pthread_cond_wait(&changed, &lock);
    pthread_mutex_unlock(&lock);
    return forward(-1); /* Real libc EBADF, not a fabricated success. */
}

void drain_probe_service(void) {
    pthread_mutex_lock(&lock);
    while (!entered) pthread_cond_wait(&changed, &lock);
    released = 1;
    pthread_cond_broadcast(&changed);
    while (!completed) pthread_cond_wait(&changed, &lock);
    pthread_mutex_unlock(&lock);
}

int tcsetattr(int fd, int action, const struct termios *attrs) {
    int (*forward)(int, int, const struct termios *) = dlsym(RTLD_NEXT, "tcsetattr");
    if (!forward) _exit(93);
    int rc;
    if (action == TCSANOW && getenv("RUI_DRAIN_RESTORE_FAILURE")) {
        errno = ENOTTY;
        rc = -1;
    } else rc = forward(fd, action, attrs);
    if (action == TCSANOW) {
        pthread_mutex_lock(&lock);
        restored++;
        pthread_cond_broadcast(&changed);
        pthread_mutex_unlock(&lock);
    }
    return rc;
}

void drain_probe_admission(void) {
    pthread_mutex_lock(&lock);
    admission_entered = 1;
    admission_id = pthread_self();
    while (!restored) pthread_cond_wait(&changed, &lock);
    pthread_mutex_unlock(&lock);
}
int drain_probe_restored(void) { return restored; }
int drain_probe_joined(void) { return joined; }
int drain_probe_admission_joined(void) { return admission_joined; }
