// Zig 0.17.0's Cache.Manifest.checkInputPath hashes a file whose stat changed
// into the manifest's own digest and then compares it with the unpopulated
// input digest, so identical bytes at a new inode or mtime always miss. A
// restored cache on a fresh checkout therefore never hits. For every manifest
// input whose current bytes hash to the recorded digest, record the current
// size, inode and mtime; anything else is left to miss as before.
#define _GNU_SOURCE
#include <dirent.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#define ROTL(x, b) (uint64_t)(((x) << (b)) | ((x) >> (64 - (b))))

static uint64_t load64(const uint8_t *p) {
    uint64_t v;
    memcpy(&v, p, 8);
    return v;
}

static void round1(uint64_t v[4]) {
    v[0] += v[1]; v[1] = ROTL(v[1], 13); v[1] ^= v[0]; v[0] = ROTL(v[0], 32);
    v[2] += v[3]; v[3] = ROTL(v[3], 16); v[3] ^= v[2];
    v[0] += v[3]; v[3] = ROTL(v[3], 21); v[3] ^= v[0];
    v[2] += v[1]; v[1] = ROTL(v[1], 17); v[1] ^= v[2]; v[2] = ROTL(v[2], 32);
}

// SipHash128(1, 3) with std.Build.Cache.hasher_init's key.
static void siphash(const uint8_t *in, size_t len, uint8_t out[16]) {
    static const uint8_t key[16] = {0x02, 0xe9, 0xfa, 0xfe, 0xe0, 0x95, 0x81, 0x55,
                                    0xf5, 0x5a, 0x15, 0xcb, 0x4a, 0xf4, 0x00, 0x09};
    uint64_t k0 = load64(key), k1 = load64(key + 8);
    uint64_t v[4] = {k0 ^ 0x736f6d6570736575ULL, k1 ^ 0x646f72616e646f6dULL,
                     k0 ^ 0x6c7967656e657261ULL, k1 ^ 0x7465646279746573ULL};
    v[1] ^= 0xee;
    size_t end = len - len % 8;
    for (size_t i = 0; i < end; i += 8) {
        uint64_t m = load64(in + i);
        v[3] ^= m; round1(v); v[0] ^= m;
    }
    uint64_t b = (uint64_t)len << 56;
    for (size_t i = 0; i < len % 8; i++) b |= (uint64_t)in[end + i] << (8 * i);
    v[3] ^= b; round1(v); v[0] ^= b;
    v[2] ^= 0xee;
    for (int i = 0; i < 3; i++) round1(v);
    uint64_t lo = v[0] ^ v[1] ^ v[2] ^ v[3];
    v[1] ^= 0xdd;
    for (int i = 0; i < 3; i++) round1(v);
    uint64_t hi = v[0] ^ v[1] ^ v[2] ^ v[3];
    memcpy(out, &lo, 8);
    memcpy(out + 8, &hi, 8);
}

static int hash_file(const char *path, struct stat *st, uint8_t out[16]) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) return -1;
    if (fstat(fd, st) != 0 || !S_ISREG(st->st_mode)) { close(fd); return -1; }
    if (st->st_size == 0) {
        close(fd);
        siphash((const uint8_t *)"", 0, out);
        return 0;
    }
    void *map = mmap(NULL, (size_t)st->st_size, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (map == MAP_FAILED) return -1;
    siphash(map, (size_t)st->st_size, out);
    munmap(map, (size_t)st->st_size);
    return 0;
}

// Each record is size, inode, mtime, digest and flags, then a NUL-terminated
// path; records are packed with no padding.
enum { HEADER = 41 };

static const char *bases[8];
static int base_count;
static long updated, kept, unmatched;

static void restat_manifest(const char *path) {
    int fd = open(path, O_RDWR);
    if (fd < 0) return;
    struct stat mst;
    if (fstat(fd, &mst) != 0 || mst.st_size < 2) { close(fd); return; }
    size_t size = (size_t)mst.st_size;
    uint8_t *m = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (m == MAP_FAILED) return;
    size_t off = 0;
    while (off + HEADER + 1 < size) {
        uint8_t flags = m[off + 40];
        const char *name = (const char *)m + off + HEADER;
        size_t name_len = strnlen(name, size - off - HEADER);
        if (name_len == 0 || off + HEADER + name_len >= size) break;
        size_t end = off + HEADER + name_len;
        // Directories and metadata-only inputs record no content digest.
        if (!(flags & 3)) {
            int done = 0;
            for (int i = 0; i < base_count && !done; i++) {
                char full[8192];
                if (name[0] == '/') {
                    if (i > 0) break;
                    snprintf(full, sizeof full, "%s", name);
                } else {
                    snprintf(full, sizeof full, "%s/%s", bases[i], name);
                }
                struct stat st;
                uint8_t digest[16];
                if (hash_file(full, &st, digest) != 0 || memcmp(digest, m + off + 24, 16) != 0) continue;
                uint64_t fsize = (uint64_t)st.st_size, inode = (uint64_t)st.st_ino;
#ifdef __APPLE__
                int64_t mtime = (int64_t)st.st_mtimespec.tv_sec * 1000000000 + st.st_mtimespec.tv_nsec;
#else
                int64_t mtime = (int64_t)st.st_mtim.tv_sec * 1000000000 + st.st_mtim.tv_nsec;
#endif
                if (memcmp(m + off, &fsize, 8) == 0 && memcmp(m + off + 8, &inode, 8) == 0 &&
                    memcmp(m + off + 16, &mtime, 8) == 0) {
                    kept++;
                } else {
                    memcpy(m + off, &fsize, 8);
                    memcpy(m + off + 8, &inode, 8);
                    memcpy(m + off + 16, &mtime, 8);
                    updated++;
                }
                done = 1;
            }
            if (!done) unmatched++;
        }
        off = end + 1;
    }
    munmap(m, size);
}

static void restat_dir(const char *dir) {
    DIR *d = opendir(dir);
    if (!d) return;
    struct dirent *e;
    while ((e = readdir(d))) {
        if (e->d_name[0] == '.' || strcmp(e->d_name, "timestamp") == 0) continue;
        char path[8192];
        snprintf(path, sizeof path, "%s/%s", dir, e->d_name);
        restat_manifest(path);
    }
    closedir(d);
}

// Usage: zig_cache_restat <manifest dir>... -- <base dir>...
// Base dirs are tried in order for relative manifest paths: the working
// directory, the Zig lib directory, and the local and global caches.
int main(int argc, char **argv) {
    int split = 1;
    while (split < argc && strcmp(argv[split], "--") != 0) split++;
    for (int i = split + 1; i < argc && base_count < 8; i++) bases[base_count++] = argv[i];
    for (int i = 1; i < split; i++) restat_dir(argv[i]);
    printf("zig cache restat: %ld updated, %ld unchanged, %ld without matching bytes\n", updated, kept, unmatched);
    return 0;
}
