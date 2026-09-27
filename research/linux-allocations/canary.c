#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>
static void *volatile held[2];
__attribute__((noinline)) static void retained_one(void) { held[0] = malloc(257); memset(held[0], 1, 257); }
__attribute__((noinline)) static void retained_two(void) { held[1] = malloc(4099); memset(held[1], 2, 4099); }
__attribute__((noinline)) static void released(void) { void *p = malloc(8193); memset(p, 3, 8193); asm volatile("" : : "r"(p) : "memory"); free(p); }
int main(void) {
    retained_one(); retained_two(); released();
    void (*stop)(void) = dlsym(RTLD_DEFAULT, "heaptrack_stop");
    if (!stop) return 1;
    stop();
    return 0;
}
