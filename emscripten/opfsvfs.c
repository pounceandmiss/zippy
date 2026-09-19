/*
 * opfsvfs.c - a SQLite VFS over the Origin Private File System, for wasm.
 *
 * Emscripten's default filesystem is memory, so a database lasts until the
 * page is reloaded; its IDBFS persists by copying whole files into IndexedDB
 * on a timer. This VFS gives SQLite real files instead: OPFS
 * FileSystemSyncAccessHandles, whose read/write/flush/truncate are
 * synchronous in a Web Worker, so every page read is a read and every commit
 * is durable when xSync returns.
 *
 * The design is SQLite's own opfs-sahpool (and wa-sqlite's
 * AccessHandlePoolVFS, MIT, whose header layout the JS half keeps): a *pool*
 * of handles is opened by JavaScript before the interpreter exists, and every
 * VFS method here is synchronous. It has to be. Opening a handle is the one
 * asynchronous OPFS call, and it cannot happen inside SQLite: this build
 * unwinds the stack with Asyncify, and the stack from a Tcl command down
 * through sqlite3_step to a VFS method does not fit any plausible
 * ASYNCIFY_STACK_SIZE (see fsync.js). So nothing below is EM_ASYNC_JS.
 *
 * The split: JavaScript (emscripten/opfs-pool.js, `globalThis.opfsPool`) owns
 * the handles and the path-to-handle map; this file owns what SQLite needs
 * from a VFS and OPFS cannot give it - locks and the WAL's shared memory - in
 * process, keyed by path, the way SQLite's unix VFS keeps them per inode.
 * Both are needed: a client may set journal_mode=WAL *and* hold two
 * connections to one database, so the locking_mode=EXCLUSIVE shortcut that
 * makes WAL work without xShmMap is not available. Cross-tab exclusion is the
 * platform's: a sync access handle is exclusive per file, so a second tab
 * fails at the pool, not here.
 *
 * Two entry points beside the VFS: opfsvfs_register(makeDefault), for the
 * worker to call once the pool is up and before anything opens a database,
 * and Opfsvfs_Init(interp), a Tcl command `::opfsvfs::file` for the few places
 * a program handles a database with `file` rather than through SQLite.
 */
#include <emscripten.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/random.h>
#include <sqlite3.h>
#include <tcl.h>

#include "opfsvfs.h"

/* -- the JavaScript pool --------------------------------------------------
 *
 * Every function answers synchronously against globalThis.opfsPool, or with
 * -3 / 0 when there is no pool - which is not an error here but a state the
 * worker chose; opfsvfs_register refuses in that case, so SQLite never sees
 * it. Buffers are wasm memory: JavaScript reads and writes HEAPU8 directly,
 * looked up per call because memory growth replaces the view.
 */

EM_JS(int, opfs_js_ready, (void), {
    return globalThis.opfsPool ? 1 : 0;
});

/* >= 0 a slot; -1 not found (and not created); -2 no free slot. */
EM_JS(int, opfs_js_open, (const char *path, int create, int flags), {
    return globalThis.opfsPool.open(UTF8ToString(path), create, flags);
});

EM_JS(void, opfs_js_close, (int slot), {
    globalThis.opfsPool.close(slot);
});

EM_JS(int, opfs_js_read, (int slot, void *buf, int n, double off), {
    return globalThis.opfsPool.read(slot, HEAPU8.subarray(buf, buf + n), off);
});

EM_JS(int, opfs_js_write, (int slot, const void *buf, int n, double off), {
    return globalThis.opfsPool.write(slot, HEAPU8.subarray(buf, buf + n), off);
});

EM_JS(int, opfs_js_truncate, (int slot, double size), {
    return globalThis.opfsPool.truncate(slot, size);
});

EM_JS(int, opfs_js_flush, (int slot), {
    return globalThis.opfsPool.flush(slot);
});

EM_JS(double, opfs_js_size, (int slot), {
    return globalThis.opfsPool.size(slot);
});

EM_JS(int, opfs_js_exists, (const char *path), {
    return globalThis.opfsPool.exists(UTF8ToString(path)) ? 1 : 0;
});

EM_JS(int, opfs_js_delete, (const char *path), {
    return globalThis.opfsPool.remove(UTF8ToString(path)) ? 0 : 1;
});

EM_JS(int, opfs_js_rename, (const char *from, const char *to), {
    return globalThis.opfsPool.rename(UTF8ToString(from), UTF8ToString(to)) ? 0 : 1;
});

/* Wall-clock milliseconds. Not emscripten_date_now(): that one lives in
 * <emscripten/html5.h>, and nothing else here needs that header. */
EM_JS(double, opfs_js_now, (void), {
    return Date.now();
});

/* A newline-separated list of every path in the pool; the caller frees. */
EM_JS(char *, opfs_js_list, (void), {
    return stringToNewUTF8(globalThis.opfsPool.list().join('\n'));
});

/*
 * Whether opfsvfs_register has succeeded. Tcl_LinkVar publishes it as
 * ::opfsvfs::available, read on every access, because an interpreter is
 * created at module instantiation and the pool arrives afterwards: a value
 * snapshotted in Opfsvfs_Init would say "no" forever.
 */
static int opfsAvailable = 0;

/* -- in-process state: one record per open path --------------------------- */

typedef struct OpfsFile OpfsFile;

typedef struct OpfsInode {
    char *path;
    int nRef;                 /* OpfsFiles open on this path */

    /* The pager's five-level lock. eLock is the highest level any file
     * holds; owner is the file holding RESERVED or above, if any; nShared
     * counts files at SHARED or above. */
    int nShared;
    int eLock;
    OpfsFile *owner;

    /* The WAL's shared memory: heap regions in place of an mmap'd -shm file,
     * and the eight lock slots SQLite coordinates through it. */
    char **aRegion;
    int nRegion;
    int szRegion;
    int nShmRef;
    int aSharedCount[SQLITE_SHM_NLOCK];
    OpfsFile *aExclOwner[SQLITE_SHM_NLOCK];

    struct OpfsInode *next;
} OpfsInode;

struct OpfsFile {
    sqlite3_file base;
    OpfsInode *inode;
    int slot;
    int eLock;
    int deleteOnClose;
    int hasShm;
    unsigned sharedShm;   /* shm slots this file holds shared */
    unsigned exclShm;     /* ... and exclusive */
};

static OpfsInode *inodes = NULL;

static OpfsInode *
inodeFind(const char *path, int create)
{
    OpfsInode *in;

    for (in = inodes; in; in = in->next) {
        if (strcmp(in->path, path) == 0) {
            return in;
        }
    }
    if (!create) {
        return NULL;
    }
    in = (OpfsInode *)sqlite3_malloc(sizeof *in);
    if (in == NULL) {
        return NULL;
    }
    memset(in, 0, sizeof *in);
    in->path = sqlite3_mprintf("%s", path);
    if (in->path == NULL) {
        sqlite3_free(in);
        return NULL;
    }
    in->next = inodes;
    inodes = in;
    return in;
}

static void
inodeRelease(OpfsInode *in)
{
    OpfsInode **pp;
    int i;

    if (--in->nRef > 0) {
        return;
    }
    for (pp = &inodes; *pp; pp = &(*pp)->next) {
        if (*pp == in) {
            *pp = in->next;
            break;
        }
    }
    for (i = 0; i < in->nRegion; i++) {
        sqlite3_free(in->aRegion[i]);
    }
    sqlite3_free(in->aRegion);
    sqlite3_free(in->path);
    sqlite3_free(in);
}

/* -- sqlite3_io_methods ---------------------------------------------------- */

static int
opfsClose(sqlite3_file *pFile)
{
    OpfsFile *f = (OpfsFile *)pFile;

    if (f->inode == NULL) {
        return SQLITE_OK;
    }
    pFile->pMethods->xUnlock(pFile, SQLITE_LOCK_NONE);
    if (f->hasShm) {
        pFile->pMethods->xShmUnmap(pFile, 0);
    }
    opfs_js_close(f->slot);
    if (f->deleteOnClose) {
        opfs_js_delete(f->inode->path);
    }
    inodeRelease(f->inode);
    f->inode = NULL;
    return SQLITE_OK;
}

static int
opfsRead(sqlite3_file *pFile, void *buf, int n, sqlite3_int64 off)
{
    OpfsFile *f = (OpfsFile *)pFile;
    int got = opfs_js_read(f->slot, buf, n, (double)off);

    if (got < 0) {
        return SQLITE_IOERR_READ;
    }
    if (got < n) {
        /* SQLite requires the unread tail to be zeroed. */
        memset((char *)buf + got, 0, (size_t)(n - got));
        return SQLITE_IOERR_SHORT_READ;
    }
    return SQLITE_OK;
}

static int
opfsWrite(sqlite3_file *pFile, const void *buf, int n, sqlite3_int64 off)
{
    OpfsFile *f = (OpfsFile *)pFile;

    return opfs_js_write(f->slot, buf, n, (double)off) == n ? SQLITE_OK : SQLITE_IOERR_WRITE;
}

static int
opfsTruncate(sqlite3_file *pFile, sqlite3_int64 size)
{
    OpfsFile *f = (OpfsFile *)pFile;

    return opfs_js_truncate(f->slot, (double)size) == 0 ? SQLITE_OK : SQLITE_IOERR_TRUNCATE;
}

static int
opfsSync(sqlite3_file *pFile, int flags)
{
    OpfsFile *f = (OpfsFile *)pFile;

    (void)flags;
    return opfs_js_flush(f->slot) == 0 ? SQLITE_OK : SQLITE_IOERR_FSYNC;
}

static int
opfsFileSize(sqlite3_file *pFile, sqlite3_int64 *pSize)
{
    OpfsFile *f = (OpfsFile *)pFile;
    double size = opfs_js_size(f->slot);

    if (size < 0) {
        return SQLITE_IOERR_FSTAT;
    }
    *pSize = (sqlite3_int64)size;
    return SQLITE_OK;
}

/*
 * The pager lock protocol, in process. The same rules as SQLite's unix VFS
 * applies across processes with fcntl, applied here across the connections
 * of one process, which is the only kind a Worker has:
 *
 *   SHARED     refused while another file holds PENDING or EXCLUSIVE
 *   RESERVED   from SHARED; refused while another file holds RESERVED+
 *   EXCLUSIVE  takes PENDING first (refused while another holds it), then
 *              waits for every other SHARED holder to leave
 *
 * BUSY is the answer to every refusal, and SQLite's busy handler retries.
 */
static int
opfsLock(sqlite3_file *pFile, int eNew)
{
    OpfsFile *f = (OpfsFile *)pFile;
    OpfsInode *in = f->inode;

    if (f->eLock >= eNew) {
        return SQLITE_OK;
    }
    switch (eNew) {
    case SQLITE_LOCK_SHARED:
        if (in->eLock >= SQLITE_LOCK_PENDING) {
            return SQLITE_BUSY;
        }
        in->nShared++;
        if (in->eLock < SQLITE_LOCK_SHARED) {
            in->eLock = SQLITE_LOCK_SHARED;
        }
        f->eLock = SQLITE_LOCK_SHARED;
        return SQLITE_OK;
    case SQLITE_LOCK_RESERVED:
        if (f->eLock < SQLITE_LOCK_SHARED) {
            return SQLITE_MISUSE;
        }
        if (in->eLock >= SQLITE_LOCK_RESERVED) {
            return SQLITE_BUSY;
        }
        in->eLock = SQLITE_LOCK_RESERVED;
        in->owner = f;
        f->eLock = SQLITE_LOCK_RESERVED;
        return SQLITE_OK;
    case SQLITE_LOCK_PENDING:
    case SQLITE_LOCK_EXCLUSIVE:
        if (f->eLock < SQLITE_LOCK_SHARED) {
            return SQLITE_MISUSE;
        }
        if (in->owner != f && in->eLock >= SQLITE_LOCK_RESERVED) {
            return SQLITE_BUSY;
        }
        in->owner = f;
        if (f->eLock < SQLITE_LOCK_PENDING) {
            f->eLock = SQLITE_LOCK_PENDING;
            in->eLock = SQLITE_LOCK_PENDING;
        }
        if (eNew == SQLITE_LOCK_PENDING) {
            return SQLITE_OK;
        }
        if (in->nShared > 1) {
            return SQLITE_BUSY; /* keep PENDING; the readers will drain */
        }
        f->eLock = SQLITE_LOCK_EXCLUSIVE;
        in->eLock = SQLITE_LOCK_EXCLUSIVE;
        return SQLITE_OK;
    default:
        return SQLITE_MISUSE;
    }
}

static int
opfsUnlock(sqlite3_file *pFile, int eNew)
{
    OpfsFile *f = (OpfsFile *)pFile;
    OpfsInode *in = f->inode;

    if (f->eLock <= eNew) {
        return SQLITE_OK;
    }
    if (f->eLock > SQLITE_LOCK_SHARED) {
        in->owner = NULL;
        in->eLock = SQLITE_LOCK_SHARED;
    }
    if (eNew == SQLITE_LOCK_NONE) {
        in->nShared--;
        if (in->nShared == 0) {
            in->eLock = SQLITE_LOCK_NONE;
        }
    }
    f->eLock = eNew;
    return SQLITE_OK;
}

static int
opfsCheckReservedLock(sqlite3_file *pFile, int *pResOut)
{
    OpfsFile *f = (OpfsFile *)pFile;
    OpfsInode *in = f->inode;

    *pResOut = in->eLock >= SQLITE_LOCK_RESERVED && in->owner != f;
    return SQLITE_OK;
}

static int
opfsFileControl(sqlite3_file *pFile, int op, void *pArg)
{
    (void)pFile;
    (void)op;
    (void)pArg;
    return SQLITE_NOTFOUND;
}

static int
opfsSectorSize(sqlite3_file *pFile)
{
    (void)pFile;
    return 4096;
}

static int
opfsDeviceCharacteristics(sqlite3_file *pFile)
{
    (void)pFile;
    /* A handle stays valid after its path is deleted, and a sync access
     * handle's write is atomic per call at the sizes SQLite uses. */
    return SQLITE_IOCAP_UNDELETABLE_WHEN_OPEN;
}

/*
 * The WAL index, in heap memory shared by every connection to the path.
 * Regions are zero-filled on allocation, and freed when the last connection
 * unmaps; the next opener finds an empty index and SQLite rebuilds it from
 * the WAL, which is what it does after a crash and is always correct.
 */
static int
opfsShmMap(sqlite3_file *pFile, int iRegion, int szRegion, int bExtend, void volatile **pp)
{
    OpfsFile *f = (OpfsFile *)pFile;
    OpfsInode *in = f->inode;

    if (!f->hasShm) {
        f->hasShm = 1;
        in->nShmRef++;
    }
    if (in->nRegion > 0 && in->szRegion != szRegion) {
        return SQLITE_IOERR_SHMMAP;
    }
    in->szRegion = szRegion;
    if (iRegion >= in->nRegion) {
        char **aNew;
        int i;

        if (!bExtend) {
            *pp = NULL;
            return SQLITE_OK;
        }
        aNew = (char **)sqlite3_realloc(in->aRegion, (iRegion + 1) * (int)sizeof(char *));
        if (aNew == NULL) {
            return SQLITE_IOERR_NOMEM;
        }
        in->aRegion = aNew;
        for (i = in->nRegion; i <= iRegion; i++) {
            in->aRegion[i] = (char *)sqlite3_malloc(szRegion);
            if (in->aRegion[i] == NULL) {
                return SQLITE_IOERR_NOMEM;
            }
            memset(in->aRegion[i], 0, (size_t)szRegion);
            in->nRegion = i + 1;
        }
    }
    *pp = in->aRegion[iRegion];
    return SQLITE_OK;
}

/* The eight wal-index lock slots, each shared-or-exclusive across files. */
static int
opfsShmLock(sqlite3_file *pFile, int ofst, int n, int flags)
{
    OpfsFile *f = (OpfsFile *)pFile;
    OpfsInode *in = f->inode;
    int i;

    if (ofst < 0 || n <= 0 || ofst + n > SQLITE_SHM_NLOCK) {
        return SQLITE_MISUSE;
    }
    if (flags & SQLITE_SHM_UNLOCK) {
        for (i = ofst; i < ofst + n; i++) {
            unsigned bit = 1u << i;

            if (f->exclShm & bit) {
                in->aExclOwner[i] = NULL;
                f->exclShm &= ~bit;
            }
            if (f->sharedShm & bit) {
                in->aSharedCount[i]--;
                f->sharedShm &= ~bit;
            }
        }
        return SQLITE_OK;
    }
    if (flags & SQLITE_SHM_SHARED) {
        for (i = ofst; i < ofst + n; i++) {
            if (in->aExclOwner[i] != NULL && in->aExclOwner[i] != f) {
                return SQLITE_BUSY;
            }
        }
        for (i = ofst; i < ofst + n; i++) {
            unsigned bit = 1u << i;

            if (!(f->sharedShm & bit) && !(f->exclShm & bit)) {
                in->aSharedCount[i]++;
                f->sharedShm |= bit;
            }
        }
        return SQLITE_OK;
    }
    /* exclusive */
    for (i = ofst; i < ofst + n; i++) {
        unsigned bit = 1u << i;
        int mine = (f->sharedShm & bit) ? 1 : 0;

        if (in->aExclOwner[i] != NULL && in->aExclOwner[i] != f) {
            return SQLITE_BUSY;
        }
        if (in->aSharedCount[i] > mine) {
            return SQLITE_BUSY;
        }
    }
    for (i = ofst; i < ofst + n; i++) {
        unsigned bit = 1u << i;

        if (f->sharedShm & bit) {
            in->aSharedCount[i]--;
            f->sharedShm &= ~bit;
        }
        in->aExclOwner[i] = f;
        f->exclShm |= bit;
    }
    return SQLITE_OK;
}

static void
opfsShmBarrier(sqlite3_file *pFile)
{
    (void)pFile; /* one thread: nothing to order */
}

static int
opfsShmUnmap(sqlite3_file *pFile, int deleteFlag)
{
    OpfsFile *f = (OpfsFile *)pFile;
    OpfsInode *in = f->inode;

    (void)deleteFlag;
    if (!f->hasShm) {
        return SQLITE_OK;
    }
    opfsShmLock(pFile, 0, SQLITE_SHM_NLOCK, SQLITE_SHM_UNLOCK);
    f->hasShm = 0;
    if (--in->nShmRef == 0) {
        int i;

        for (i = 0; i < in->nRegion; i++) {
            sqlite3_free(in->aRegion[i]);
        }
        sqlite3_free(in->aRegion);
        in->aRegion = NULL;
        in->nRegion = 0;
    }
    return SQLITE_OK;
}

static const sqlite3_io_methods opfsIoMethods = {
    2,                          /* iVersion: xShm* present, no xFetch/xUnfetch */
    opfsClose,
    opfsRead,
    opfsWrite,
    opfsTruncate,
    opfsSync,
    opfsFileSize,
    opfsLock,
    opfsUnlock,
    opfsCheckReservedLock,
    opfsFileControl,
    opfsSectorSize,
    opfsDeviceCharacteristics,
    opfsShmMap,
    opfsShmLock,
    opfsShmBarrier,
    opfsShmUnmap,
    0, 0                        /* xFetch, xUnfetch */
};

/* -- sqlite3_vfs ----------------------------------------------------------- */

#define OPFS_MAX_PATH 480   /* under the pool header's 512, with room to spare */

static int
opfsOpen(sqlite3_vfs *pVfs, const char *zName, sqlite3_file *pFile, int flags, int *pOutFlags)
{
    OpfsFile *f = (OpfsFile *)pFile;
    char tmp[64];
    int slot;

    (void)pVfs;
    memset(f, 0, sizeof *f);
    if (zName == NULL) {
        /* A temp file: SQLite deletes it on close and never names it. */
        static unsigned tmpSeq = 0;
        snprintf(tmp, sizeof tmp, "/tmp/sqlite-%u-%u", (unsigned)(opfs_js_now() / 1000), tmpSeq++);
        zName = tmp;
        flags |= SQLITE_OPEN_DELETEONCLOSE | SQLITE_OPEN_CREATE;
    }
    slot = opfs_js_open(zName, (flags & SQLITE_OPEN_CREATE) ? 1 : 0, flags);
    if (slot < 0) {
        return slot == -2 ? SQLITE_FULL : SQLITE_CANTOPEN;
    }
    f->inode = inodeFind(zName, 1);
    if (f->inode == NULL) {
        opfs_js_close(slot);
        return SQLITE_NOMEM;
    }
    f->inode->nRef++;
    f->slot = slot;
    f->deleteOnClose = (flags & SQLITE_OPEN_DELETEONCLOSE) != 0;
    f->base.pMethods = &opfsIoMethods;
    if (pOutFlags) {
        *pOutFlags = flags;
    }
    return SQLITE_OK;
}

static int
opfsDelete(sqlite3_vfs *pVfs, const char *zName, int syncDir)
{
    (void)pVfs;
    (void)syncDir;
    opfs_js_delete(zName);
    return SQLITE_OK;
}

static int
opfsAccess(sqlite3_vfs *pVfs, const char *zName, int flags, int *pResOut)
{
    (void)pVfs;
    (void)flags; /* exists, readable, writable: all the same to a pool */
    *pResOut = opfs_js_exists(zName);
    return SQLITE_OK;
}

static int
opfsFullPathname(sqlite3_vfs *pVfs, const char *zName, int nOut, char *zOut)
{
    (void)pVfs;
    if (zName[0] == '/') {
        snprintf(zOut, (size_t)nOut, "%s", zName);
    } else {
        snprintf(zOut, (size_t)nOut, "/%s", zName);
    }
    return SQLITE_OK;
}

static int
opfsRandomness(sqlite3_vfs *pVfs, int nBuf, char *zBuf)
{
    int nLeft = nBuf;

    (void)pVfs;
    /* getentropy over crypto.getRandomValues; 256 bytes per call at most. */
    while (nLeft > 0) {
        int n = nLeft > 256 ? 256 : nLeft;

        if (getentropy(zBuf, (size_t)n) != 0) {
            memset(zBuf, 0, (size_t)nLeft);
            return nBuf - nLeft;
        }
        zBuf += n;
        nLeft -= n;
    }
    return nBuf;
}

static int
opfsSleep(sqlite3_vfs *pVfs, int microseconds)
{
    (void)pVfs;
    /* Nothing to wait for: the only other connection that could hold a lock
     * is on this very thread, and it is not running while we are. Returning
     * at once lets the busy handler try again, which will succeed or not on
     * the same information. Never emscripten_sleep here - that unwinds. */
    return microseconds;
}

static int
opfsCurrentTimeInt64(sqlite3_vfs *pVfs, sqlite3_int64 *pTime)
{
    (void)pVfs;
    /* Milliseconds since the Julian epoch, as SQLite's unix VFS computes it. */
    *pTime = (sqlite3_int64)opfs_js_now() + 210866760000000LL;
    return SQLITE_OK;
}

static int
opfsCurrentTime(sqlite3_vfs *pVfs, double *pJulian)
{
    sqlite3_int64 ms;

    opfsCurrentTimeInt64(pVfs, &ms);
    *pJulian = (double)ms / 86400000.0;
    return SQLITE_OK;
}

static int
opfsGetLastError(sqlite3_vfs *pVfs, int nBuf, char *zBuf)
{
    (void)pVfs;
    (void)nBuf;
    (void)zBuf;
    return 0;
}

static sqlite3_vfs opfsVfs = {
    2,                      /* iVersion */
    sizeof(OpfsFile),       /* szOsFile */
    OPFS_MAX_PATH,          /* mxPathname */
    0,                      /* pNext */
    "opfs",                 /* zName */
    0,                      /* pAppData */
    opfsOpen,
    opfsDelete,
    opfsAccess,
    opfsFullPathname,
    0, 0, 0, 0,             /* xDlOpen, xDlError, xDlSym, xDlClose */
    opfsRandomness,
    opfsSleep,
    opfsCurrentTime,
    opfsGetLastError,
    opfsCurrentTimeInt64,
    0, 0, 0                 /* xSetSystemCall, xGetSystemCall, xNextSystemCall */
};

/*
 * Register the VFS, as the default if asked. For the worker to call once the
 * pool is up and before anything opens a database. Refuses without a pool:
 * a default VFS that fails every open would turn "no OPFS" into a broken
 * SQLite rather than the fallback the worker meant to take.
 */
EMSCRIPTEN_KEEPALIVE
int
opfsvfs_register(int makeDefault)
{
    int rc;

    if (!opfs_js_ready()) {
        return SQLITE_ERROR;
    }
    rc = sqlite3_vfs_register(&opfsVfs, makeDefault);
    if (rc == SQLITE_OK) {
        opfsAvailable = 1;
    }
    return rc;
}

/* -- ::opfsvfs::file, the Tcl seam ----------------------------------------- */

/*
 * `opfsvfs::file exists PATH`, `delete PATH ?PATH ...?`, `rename FROM TO`,
 * `list ?PREFIX?`: what a program that manages database files with `file`
 * needs when those files live in the pool rather than in the filesystem
 * `file` reaches. `delete` of a missing path is not an error, like
 * `file delete`. `list` returns every pooled path under PREFIX.
 */
static int
OpfsFileCmd(void *cd, Tcl_Interp *ip, int objc, Tcl_Obj *const objv[])
{
    static const char *subs[] = { "exists", "delete", "rename", "list", NULL };
    enum { EXISTS, DELETE, RENAME, LIST };
    int idx, i;

    (void)cd;
    if (objc < 2) {
        Tcl_WrongNumArgs(ip, 1, objv, "subcommand ?arg ...?");
        return TCL_ERROR;
    }
    if (Tcl_GetIndexFromObj(ip, objv[1], subs, "subcommand", 0, &idx) != TCL_OK) {
        return TCL_ERROR;
    }
    if (!opfs_js_ready()) {
        Tcl_SetResult(ip, "no OPFS pool in this session", TCL_STATIC);
        return TCL_ERROR;
    }
    switch (idx) {
    case EXISTS:
        if (objc != 3) {
            Tcl_WrongNumArgs(ip, 2, objv, "path");
            return TCL_ERROR;
        }
        Tcl_SetObjResult(ip, Tcl_NewBooleanObj(opfs_js_exists(Tcl_GetString(objv[2]))));
        return TCL_OK;
    case DELETE:
        for (i = 2; i < objc; i++) {
            opfs_js_delete(Tcl_GetString(objv[i]));
        }
        return TCL_OK;
    case RENAME:
        if (objc != 4) {
            Tcl_WrongNumArgs(ip, 2, objv, "from to");
            return TCL_ERROR;
        }
        if (opfs_js_rename(Tcl_GetString(objv[2]), Tcl_GetString(objv[3])) != 0) {
            Tcl_SetObjResult(ip, Tcl_ObjPrintf("cannot rename %s: no such file",
                Tcl_GetString(objv[2])));
            return TCL_ERROR;
        }
        return TCL_OK;
    case LIST: {
        const char *prefix = objc > 2 ? Tcl_GetString(objv[2]) : "";
        size_t plen = strlen(prefix);
        char *all = opfs_js_list();
        char *p = all, *nl;
        Tcl_Obj *result = Tcl_NewListObj(0, NULL);

        if (objc > 3) {
            Tcl_WrongNumArgs(ip, 2, objv, "?prefix?");
            free(all);
            return TCL_ERROR;
        }
        while (p && *p) {
            nl = strchr(p, '\n');
            if (nl) {
                *nl = '\0';
            }
            if (strncmp(p, prefix, plen) == 0) {
                Tcl_ListObjAppendElement(ip, result, Tcl_NewStringObj(p, -1));
            }
            p = nl ? nl + 1 : NULL;
        }
        free(all);
        Tcl_SetObjResult(ip, result);
        return TCL_OK;
    }
    }
    return TCL_ERROR;
}

int
Opfsvfs_Init(Tcl_Interp *interp)
{
    if (Tcl_CreateNamespace(interp, "::opfsvfs", NULL, NULL) == NULL) {
        return TCL_ERROR;
    }
    Tcl_CreateObjCommand(interp, "::opfsvfs::file", OpfsFileCmd, NULL, NULL);
    if (Tcl_LinkVar(interp, "::opfsvfs::available", &opfsAvailable,
            TCL_LINK_BOOLEAN | TCL_LINK_READ_ONLY) != TCL_OK) {
        return TCL_ERROR;
    }
    return Tcl_PkgProvide(interp, "opfsvfs", "0.1");
}
