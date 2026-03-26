/* apk-tar.c — write ustar tar stream with APK-TOOLS SHA1 PAX extended headers
 *
 * Reads paths (one per line) from stdin. Must be run from staging directory.
 * Writes uncompressed tar stream to stdout. Caller pipes through gzip -9.
 *
 * Each regular file gets a PAX extended header (type='x') containing:
 *   11 ctime=0
 *   11 atime=0
 *   68 APK-TOOLS.checksum.SHA1=<40hex>
 * Directories and symlinks get:
 *   11 ctime=0
 *   11 atime=0
 *
 * This matches abuild-tar --hash output, required by apk-tools v3 for
 * package extraction (apk extract / apk add).
 *
 * Compile: cc -O2 -o apk-tar apk-tar.c
 * (no external dependencies — SHA1 is implemented inline)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>

/* ---- minimal SHA1 (no external deps) ------------------------------------- */

#define ROL32(x,n) (((x)<<(n))|((x)>>(32-(n))))

typedef struct { uint32_t h[5]; uint64_t len; uint8_t buf[64]; int buflen; } SHA1_CTX;

static void sha1_compress(SHA1_CTX *c, const uint8_t *b) {
    uint32_t w[80], a, bb, cc, d, e, f, t;
    static const uint32_t K[4] = {
        0x5A827999u, 0x6ED9EBA1u, 0x8F1BBCDCu, 0xCA62C1D6u
    };
    int i;
    for (i = 0; i < 16; i++)
        w[i] = ((uint32_t)b[4*i]<<24) | ((uint32_t)b[4*i+1]<<16)
             | ((uint32_t)b[4*i+2]<<8) | b[4*i+3];
    for (i = 16; i < 80; i++)
        w[i] = ROL32(w[i-3] ^ w[i-8] ^ w[i-14] ^ w[i-16], 1);
    a = c->h[0]; bb = c->h[1]; cc = c->h[2]; d = c->h[3]; e = c->h[4];
    for (i = 0; i < 80; i++) {
        if      (i < 20) f = (bb & cc) | ((~bb) & d);
        else if (i < 40) f = bb ^ cc ^ d;
        else if (i < 60) f = (bb & cc) | (bb & d) | (cc & d);
        else             f = bb ^ cc ^ d;
        t = ROL32(a, 5) + f + e + K[i/20] + w[i];
        e = d; d = cc; cc = ROL32(bb, 30); bb = a; a = t;
    }
    c->h[0] += a; c->h[1] += bb; c->h[2] += cc; c->h[3] += d; c->h[4] += e;
}

static void sha1_init(SHA1_CTX *c) {
    c->h[0]=0x67452301u; c->h[1]=0xEFCDAB89u; c->h[2]=0x98BADCFEu;
    c->h[3]=0x10325476u; c->h[4]=0xC3D2E1F0u;
    c->len = 0; c->buflen = 0;
}

static void sha1_update(SHA1_CTX *c, const uint8_t *data, size_t len) {
    while (len) {
        int n = 64 - c->buflen;
        if ((int)len < n) n = (int)len;
        memcpy(c->buf + c->buflen, data, n);
        c->buflen += n; data += n; len -= n; c->len += (uint64_t)n;
        if (c->buflen == 64) { sha1_compress(c, c->buf); c->buflen = 0; }
    }
}

static void sha1_final(uint8_t digest[20], SHA1_CTX *c) {
    uint64_t bits = c->len * 8;
    uint8_t pad = 0x80;
    sha1_update(c, &pad, 1);
    pad = 0;
    while (c->buflen != 56) sha1_update(c, &pad, 1);
    /* append bit length big-endian */
    uint8_t lb[8];
    int i;
    for (i = 7; i >= 0; i--) { lb[i] = (uint8_t)(bits & 0xff); bits >>= 8; }
    sha1_update(c, lb, 8);
    for (i = 0; i < 5; i++) {
        digest[4*i]   = (uint8_t)((c->h[i] >> 24) & 0xff);
        digest[4*i+1] = (uint8_t)((c->h[i] >> 16) & 0xff);
        digest[4*i+2] = (uint8_t)((c->h[i] >>  8) & 0xff);
        digest[4*i+3] = (uint8_t)( c->h[i]         & 0xff);
    }
}

/* ---- tar helpers --------------------------------------------------------- */

#define BSIZE 512

static const char _zeros[BSIZE];

static void xwrite(const void *buf, size_t n) {
    const char *p = (const char *)buf;
    while (n) {
        ssize_t w = write(STDOUT_FILENO, p, n);
        if (w < 0 && errno == EINTR) continue;
        if (w <= 0) { perror("apk-tar: write"); exit(1); }
        p += w; n -= (size_t)w;
    }
}

static void pad_to_block(size_t sz) {
    size_t rem = sz % BSIZE;
    if (rem) xwrite(_zeros, BSIZE - rem);
}

static unsigned int hdr_cksum(const char h[BSIZE]) {
    unsigned int s = 0, i;
    for (i = 0;   i < 148; i++) s += (unsigned char)h[i];
    s += ' ' * 8;
    for (i = 156; i < BSIZE; i++) s += (unsigned char)h[i];
    return s;
}

/* Fill a ustar header. uid/gid forced to 0/root for package files. */
static void make_hdr(char h[BSIZE], const char *name, unsigned mode,
                     off_t size, time_t mtime, char typeflag,
                     const char *linkname) {
    size_t nlen;
    memset(h, 0, BSIZE);

    nlen = strlen(name);
    if (nlen <= 99) {
        memcpy(h, name, nlen);
    } else {
        /* ustar prefix/name split at a '/' boundary */
        int split = -1, i;
        for (i = (int)nlen - 1; i > 0; i--) {
            if (name[i] == '/') {
                if (i <= 154 && (int)nlen - i - 1 <= 99) { split = i; break; }
            }
        }
        if (split >= 0) {
            memcpy(h,       name + split + 1, nlen - split - 1);  /* name    */
            memcpy(h + 345, name,             split);              /* prefix  */
        } else {
            memcpy(h, name, 99);  /* truncate as last resort */
        }
    }

    snprintf(h+100, 8,  "%07o",  mode & 07777u);
    snprintf(h+108, 8,  "%07o",  0u);   /* uid = root */
    snprintf(h+116, 8,  "%07o",  0u);   /* gid = root */
    snprintf(h+124, 12, "%011lo", (unsigned long)size);
    snprintf(h+136, 12, "%011lo", (unsigned long)mtime);
    h[156] = typeflag;
    if (linkname) strncpy(h+157, linkname, 99);
    memcpy(h+257, "ustar", 5); h[262] = '\0';
    memcpy(h+263, "00", 2);
    strncpy(h+265, "root", 31);
    strncpy(h+297, "root", 31);

    unsigned int cs = hdr_cksum(h);
    snprintf(h+148, 8, "%06o", cs);
    h[154] = '\0'; h[155] = ' ';
}

/* Write PAX extended header entry (type='x') */
static void write_pax(const char *path, const char *pax, size_t paxlen) {
    char pname[512];
    const char *p = (path[0]=='.' && path[1]=='/') ? path+2 : path;
    snprintf(pname, sizeof(pname), "./PaxHeaders/%s", p);

    char hdr[BSIZE];
    make_hdr(hdr, pname, 0644, (off_t)paxlen, 0, 'x', NULL);
    xwrite(hdr, BSIZE);
    xwrite(pax, paxlen);
    pad_to_block(paxlen);
}

/* Compute SHA1 of file, write 40-char hex into hexbuf[41] */
static int file_sha1_hex(const char *path, char hexbuf[41]) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) { perror(path); return -1; }
    SHA1_CTX ctx;
    sha1_init(&ctx);
    uint8_t buf[65536];
    ssize_t n;
    while ((n = read(fd, buf, sizeof(buf))) > 0)
        sha1_update(&ctx, buf, (size_t)n);
    close(fd);
    uint8_t digest[20];
    sha1_final(digest, &ctx);
    int i;
    for (i = 0; i < 20; i++)
        snprintf(hexbuf + 2*i, 3, "%02x", (unsigned int)digest[i]);
    return 0;
}

static void process_regular(const char *path, const struct stat *st) {
    char hex[41];
    if (file_sha1_hex(path, hex) < 0) return;

    /* PAX content: 11 ctime=0\n11 atime=0\n68 APK-TOOLS.checksum.SHA1=<hex>\n */
    char pax[128];
    int plen = snprintf(pax, sizeof(pax),
        "11 ctime=0\n11 atime=0\n68 APK-TOOLS.checksum.SHA1=%s\n", hex);
    write_pax(path, pax, (size_t)plen);

    char hdr[BSIZE];
    make_hdr(hdr, path, (unsigned)st->st_mode, st->st_size, st->st_mtime, '0', NULL);
    xwrite(hdr, BSIZE);

    int fd = open(path, O_RDONLY);
    if (fd < 0) { perror(path); return; }
    uint8_t buf[65536];
    ssize_t n;
    size_t written = 0;
    while ((n = read(fd, buf, sizeof(buf))) > 0) {
        xwrite(buf, (size_t)n);
        written += (size_t)n;
    }
    close(fd);
    pad_to_block(written);
}

static void process_dir(const char *path, const struct stat *st) {
    const char *pax = "11 ctime=0\n11 atime=0\n";
    write_pax(path, pax, 22);

    /* Directory entries must end with '/' in ustar */
    char dpath[4096];
    size_t plen = strlen(path);
    if (path[plen-1] != '/') {
        if (plen + 2 < sizeof(dpath)) {
            memcpy(dpath, path, plen);
            dpath[plen] = '/'; dpath[plen+1] = '\0';
        } else {
            strncpy(dpath, path, sizeof(dpath)-1);
            dpath[sizeof(dpath)-1] = '\0';
        }
    } else {
        strncpy(dpath, path, sizeof(dpath)-1);
        dpath[sizeof(dpath)-1] = '\0';
    }

    char hdr[BSIZE];
    make_hdr(hdr, dpath, (unsigned)st->st_mode, 0, st->st_mtime, '5', NULL);
    xwrite(hdr, BSIZE);
}

static void process_symlink(const char *path, const struct stat *st) {
    char target[256];
    ssize_t n = readlink(path, target, sizeof(target)-1);
    if (n < 0) { perror(path); return; }
    target[n] = '\0';

    const char *pax = "11 ctime=0\n11 atime=0\n";
    write_pax(path, pax, 22);

    char hdr[BSIZE];
    make_hdr(hdr, path, (unsigned)st->st_mode, 0, st->st_mtime, '2', target);
    xwrite(hdr, BSIZE);
}

/* ---- main ---------------------------------------------------------------- */

int main(void) {
    char line[4096];
    while (fgets(line, (int)sizeof(line), stdin)) {
        size_t len = strlen(line);
        while (len && (line[len-1] == '\n' || line[len-1] == '\r'))
            line[--len] = '\0';
        if (!len) continue;

        struct stat st;
        if (lstat(line, &st) < 0) { perror(line); continue; }

        if      (S_ISREG(st.st_mode)) process_regular(line, &st);
        else if (S_ISDIR(st.st_mode)) process_dir(line, &st);
        else if (S_ISLNK(st.st_mode)) process_symlink(line, &st);
        /* other types (device, fifo) skipped */
    }

    /* end-of-archive: two zero blocks */
    xwrite(_zeros, BSIZE);
    xwrite(_zeros, BSIZE);
    return 0;
}
