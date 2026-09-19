/*
 * compat.c - libc calls Emscripten's musl leaves out, for deps that expect a
 * Linux libc. Compiled into every launcher and into lib<name>.a.
 *
 * getrandom(2): picomemo's omemoRandom uses it as its portable default.
 * Emscripten offers getentropy (over crypto.getRandomValues in a browser or
 * node) but not getrandom, so this is the one over the other. getentropy
 * refuses more than 256 bytes per call, hence the loop; the flags are ignored
 * because there is no blocking pool to speak of.
 */

#include <errno.h>
#include <stddef.h>
#include <sys/random.h>
#include <sys/types.h>

ssize_t
getrandom(void *buf, size_t buflen, unsigned int flags)
{
    unsigned char *out = (unsigned char *)buf;
    size_t done = 0;

    (void)flags;
    while (done < buflen) {
        size_t n = buflen - done;
        if (n > 256) {
            n = 256;
        }
        if (getentropy(out + done, n) != 0) {
            return -1; /* errno is getentropy's */
        }
        done += n;
    }
    return (ssize_t)done;
}
