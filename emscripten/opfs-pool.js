/*
 * opfs-pool.js - the JavaScript half of emscripten/opfsvfs.c: a pool of OPFS
 * sync access handles that SQLite's files are mapped onto.
 *
 * Every OPFS handle is opened here, asynchronously, before the interpreter
 * runs; after that every call the C VFS makes is synchronous. The files in
 * the pool have opaque names and each begins with a 4 KiB header that says
 * which SQLite path it currently holds (or none), so the mapping survives a
 * reload without a separate index. The layout is wa-sqlite's
 * AccessHandlePoolVFS (Roy T. Hashimoto, MIT), which is SQLite's own
 * opfs-sahpool layout; the pool logic follows it, the VFS half is ours.
 *
 * Usage, from a Web Worker (sync access handles exist nowhere else):
 *
 *   import { createOpfsPool } from './opfs-pool.js';
 *   const pool = await createOpfsPool({ directory: 'my-app', capacity: 64 });
 *   // then, before anything opens a database:
 *   Module.ccall('opfsvfs_register', 'number', ['number'], [1]);
 *
 * createOpfsPool installs the pool as globalThis.opfsPool, which is where
 * opfsvfs.c looks. It rejects with a reason when OPFS is unavailable
 * ('unsupported', 'refused') or another tab holds the files ('locked') -
 * sync access handles are exclusive, so one open store per origin at a time
 * is the platform's rule, not ours. A caller falls back to something else.
 */

const SECTOR_SIZE = 4096;
const HEADER_MAX_PATH_SIZE = 512;
const HEADER_FLAGS_SIZE = 4;
const HEADER_DIGEST_SIZE = 8;
const HEADER_CORPUS_SIZE = HEADER_MAX_PATH_SIZE + HEADER_FLAGS_SIZE;
const HEADER_OFFSET_FLAGS = HEADER_MAX_PATH_SIZE;
const HEADER_OFFSET_DIGEST = HEADER_CORPUS_SIZE;
const HEADER_OFFSET_DATA = SECTOR_SIZE;

// sqlite3.h's SQLITE_OPEN_* bits that matter to the pool.
const SQLITE_OPEN_DELETEONCLOSE = 0x00000008;
const SQLITE_OPEN_MAIN_DB = 0x00000100;
const SQLITE_OPEN_MAIN_JOURNAL = 0x00000800;
const SQLITE_OPEN_WAL = 0x00080000;
const SQLITE_OPEN_SUPER_JOURNAL = 0x00004000;

// Files of these kinds outlive a session; anything else found in the pool
// at start (a temp file from a session that was killed) is discarded.
const PERSISTENT_FILE_TYPES =
    SQLITE_OPEN_MAIN_DB | SQLITE_OPEN_MAIN_JOURNAL | SQLITE_OPEN_SUPER_JOURNAL | SQLITE_OPEN_WAL;

export class OpfsPoolError extends Error {
    constructor(reason, message) {
        super(message);
        this.reason = reason; // 'unsupported' | 'refused' | 'locked'
    }
}

/**
 * The pool. `slots[i]` is a sync access handle; `paths[i]` the SQLite path
 * it holds, or '' when free. The C side addresses files by slot after open.
 */
class OpfsPool {
    #dir;
    #slots = [];
    #names = [];
    #paths = [];
    #flags = [];
    #byPath = new Map();

    constructor(dir) {
        this.#dir = dir;
    }

    async init(capacity) {
        const entries = [];
        for await (const [name, handle] of this.#dir) {
            if (handle.kind === 'file') entries.push([name, handle]);
        }
        // All at once: a second tab that holds any of these makes
        // createSyncAccessHandle throw, and one failure means the store is
        // someone else's for now.
        const handles = await Promise.all(entries.map(async ([name, handle]) => {
            try {
                return [name, await handle.createSyncAccessHandle()];
            } catch (err) {
                throw new OpfsPoolError('locked', `store is open in another tab (${err.name})`);
            }
        }));
        for (const [name, ah] of handles) {
            this.#adopt(name, ah);
        }
        while (this.#slots.length < capacity) {
            const name = Math.random().toString(36).slice(2);
            const handle = await this.#dir.getFileHandle(name, { create: true });
            const ah = await handle.createSyncAccessHandle();
            this.#adopt(name, ah);
            this.#setPath(this.#slots.length - 1, '', 0);
        }
    }

    #adopt(name, ah) {
        const slot = this.#slots.length;
        this.#slots.push(ah);
        this.#names.push(name);
        this.#paths.push('');
        this.#flags.push(0);
        const path = this.#readPath(slot);
        if (path) {
            this.#paths[slot] = path;
            this.#byPath.set(path, slot);
        }
    }

    // -- the header --------------------------------------------------------

    #readPath(slot) {
        const ah = this.#slots[slot];
        const corpus = new Uint8Array(HEADER_CORPUS_SIZE);
        if (ah.read(corpus, { at: 0 }) < HEADER_CORPUS_SIZE) {
            this.#setPath(slot, '', 0); // fresh or torn: make it free
            return '';
        }
        const view = new DataView(corpus.buffer);
        const flags = view.getUint32(HEADER_OFFSET_FLAGS);
        this.#flags[slot] = flags;
        if (corpus[0] && ((flags & SQLITE_OPEN_DELETEONCLOSE) || (flags & PERSISTENT_FILE_TYPES) === 0)) {
            this.#setPath(slot, '', 0); // a temp file from a killed session
            return '';
        }
        const digest = new Uint32Array(HEADER_DIGEST_SIZE / 4);
        ah.read(digest, { at: HEADER_OFFSET_DIGEST });
        const want = computeDigest(corpus);
        if (!digest.every((v, i) => v === want[i])) {
            console.warn('opfs-pool: discarding a file with a bad header');
            this.#setPath(slot, '', 0);
            return '';
        }
        const end = corpus.indexOf(0);
        if (end === 0) {
            ah.truncate(HEADER_OFFSET_DATA); // free, and made sure of it
            return '';
        }
        return new TextDecoder().decode(corpus.subarray(0, end));
    }

    #setPath(slot, path, flags) {
        const ah = this.#slots[slot];
        const corpus = new Uint8Array(HEADER_CORPUS_SIZE);
        const { written } = new TextEncoder().encodeInto(path, corpus);
        if (written >= HEADER_MAX_PATH_SIZE) throw new Error('path too long');
        new DataView(corpus.buffer).setUint32(HEADER_OFFSET_FLAGS, flags);
        ah.write(corpus, { at: 0 });
        ah.write(computeDigest(corpus), { at: HEADER_OFFSET_DIGEST });
        ah.flush();
        const old = this.#paths[slot];
        if (old) this.#byPath.delete(old);
        this.#paths[slot] = path;
        this.#flags[slot] = flags;
        if (path) {
            this.#byPath.set(path, slot);
        } else {
            ah.truncate(HEADER_OFFSET_DATA);
        }
    }

    #free() {
        return this.#paths.indexOf('');
    }

    // -- what opfsvfs.c calls, all synchronous -------------------------------

    /** slot, or -1 (not found), -2 (pool full) */
    open(path, create, flags) {
        let slot = this.#byPath.get(path);
        if (slot === undefined) {
            if (!create) return -1;
            slot = this.#free();
            if (slot < 0) return -2;
            this.#setPath(slot, path, flags);
        }
        return slot;
    }

    close(slot) {
        this.#slots[slot].flush();
    }

    read(slot, u8, off) {
        return this.#slots[slot].read(u8, { at: HEADER_OFFSET_DATA + off });
    }

    write(slot, u8, off) {
        return this.#slots[slot].write(u8, { at: HEADER_OFFSET_DATA + off });
    }

    truncate(slot, size) {
        this.#slots[slot].truncate(HEADER_OFFSET_DATA + size);
        return 0;
    }

    flush(slot) {
        this.#slots[slot].flush();
        return 0;
    }

    size(slot) {
        return this.#slots[slot].getSize() - HEADER_OFFSET_DATA;
    }

    exists(path) {
        return this.#byPath.has(path);
    }

    remove(path) {
        const slot = this.#byPath.get(path);
        if (slot === undefined) return false;
        this.#setPath(slot, '', 0);
        return true;
    }

    rename(from, to) {
        const slot = this.#byPath.get(from);
        if (slot === undefined) return false;
        const flags = this.#flags[slot];
        this.remove(to);
        this.#setPath(slot, to, flags);
        return true;
    }

    list() {
        return this.#paths.filter((p) => p);
    }

    /** How many free slots remain; a caller may want to warn early. */
    get free() {
        return this.#paths.filter((p) => !p).length;
    }

    async close_all() {
        for (const ah of this.#slots) ah.close();
        this.#slots = [];
        this.#names = [];
        this.#paths = [];
        this.#flags = [];
        this.#byPath.clear();
    }
}

/**
 * A synchronous digest of the header, so a torn write is noticed. WebCrypto
 * is asynchronous, hence cyrb53 (bryc, public domain), as in wa-sqlite.
 */
function computeDigest(corpus) {
    if (!corpus[0]) return new Uint32Array([0xfecc5f80, 0xaccec037]);
    let h1 = 0xdeadbeef;
    let h2 = 0x41c6ce57;
    for (const v of corpus) {
        h1 = Math.imul(h1 ^ v, 2654435761);
        h2 = Math.imul(h2 ^ v, 1597334677);
    }
    h1 = Math.imul(h1 ^ (h1 >>> 16), 2246822507) ^ Math.imul(h2 ^ (h2 >>> 13), 3266489909);
    h2 = Math.imul(h2 ^ (h2 >>> 16), 2246822507) ^ Math.imul(h1 ^ (h1 >>> 13), 3266489909);
    return new Uint32Array([h1 >>> 0, h2 >>> 0]);
}

/**
 * Open (or create) the pool under `directory` in this origin's OPFS and
 * install it as globalThis.opfsPool. Rejects with an OpfsPoolError.
 */
export async function createOpfsPool({ directory = 'zippy-sqlite', capacity = 64 } = {}) {
    if (typeof navigator === 'undefined' || !navigator.storage?.getDirectory ||
        typeof FileSystemFileHandle === 'undefined' ||
        !FileSystemFileHandle.prototype.createSyncAccessHandle) {
        throw new OpfsPoolError('unsupported', 'no OPFS sync access handles here');
    }
    let dir;
    try {
        dir = await navigator.storage.getDirectory();
        for (const part of directory.split('/')) {
            if (part) dir = await dir.getDirectoryHandle(part, { create: true });
        }
    } catch (err) {
        throw new OpfsPoolError('refused', `OPFS refused: ${err.name}: ${err.message}`);
    }
    return openOpfsPool(dir, capacity);
}

/**
 * The second half of createOpfsPool: take a directory handle that is already
 * in hand and make the pool over it. Separate because the tests hand it a
 * directory of their own (tests/opfs-mock-dir.mjs) - and because reopening a
 * pool over the same directory, which is what a page reload does, is then one
 * call rather than a second trip through OPFS.
 */
export async function openOpfsPool(dir, capacity = 64) {
    const pool = new OpfsPool(dir);
    await pool.init(capacity);
    globalThis.opfsPool = pool;
    return pool;
}
