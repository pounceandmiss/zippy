/*
 * opfs-mock-dir.mjs - OPFS, in memory, for the tests.
 *
 * emscripten/opfsvfs.c talks to a pool of FileSystemSyncAccessHandles, and
 * those exist only in a Web Worker in a browser. Rather than reimplement the
 * pool's side of the bargain here - which would test the mock - this supplies
 * the layer *under* it: a directory handle whose files are Uint8Arrays and
 * whose access handles have the synchronous read/write/truncate/getSize/flush
 * that the real ones do. `openOpfsPool` (emscripten/opfs-pool.js) then runs
 * unchanged over it, headers and all, so a pool opened a second time over the
 * same MockDirectory rediscovers its files exactly as a page reload does.
 *
 * Modelled faithfully in the two places that matter to the VFS: a read returns
 * how many bytes it actually got (short at end of file), and a second
 * createSyncAccessHandle on a file that already has one throws, as the
 * exclusivity the pool relies on requires.
 */

class MockSyncAccessHandle {
    constructor(file) {
        this.file = file;
        this.closed = false;
    }

    #check() {
        if (this.closed) throw new DOMException('handle is closed', 'InvalidStateError');
    }

    read(buf, { at = 0 } = {}) {
        this.#check();
        const view = new Uint8Array(buf.buffer, buf.byteOffset, buf.byteLength);
        const n = Math.max(0, Math.min(view.length, this.file.size - at));
        view.set(this.file.data.subarray(at, at + n));
        return n;
    }

    write(buf, { at = 0 } = {}) {
        this.#check();
        const view = new Uint8Array(buf.buffer, buf.byteOffset, buf.byteLength);
        this.#grow(at + view.length);
        this.file.data.set(view, at);
        this.file.size = Math.max(this.file.size, at + view.length);
        return view.length;
    }

    truncate(size) {
        this.#check();
        if (size > this.file.size) {
            this.#grow(size);
            this.file.data.fill(0, this.file.size, size);
        }
        this.file.size = size;
    }

    getSize() {
        this.#check();
        return this.file.size;
    }

    flush() {
        this.#check();
    }

    close() {
        this.closed = true;
        this.file.handle = null;
    }

    #grow(need) {
        if (need <= this.file.data.length) return;
        const grown = new Uint8Array(Math.max(need, this.file.data.length * 2, 8192));
        grown.set(this.file.data.subarray(0, this.file.size));
        this.file.data = grown;
    }
}

class MockFileHandle {
    constructor(file) {
        this.kind = 'file';
        this.file = file;
    }

    async createSyncAccessHandle() {
        if (this.file.handle) {
            throw new DOMException('already open', 'NoModificationAllowedError');
        }
        this.file.handle = new MockSyncAccessHandle(this.file);
        return this.file.handle;
    }
}

/**
 * A FileSystemDirectoryHandle over a Map of name -> { data, size }. Keep the
 * instance to keep the files: that is what makes a reopen a reopen.
 */
export class MockDirectory {
    constructor() {
        this.files = new Map();
    }

    async getFileHandle(name, { create = false } = {}) {
        let file = this.files.get(name);
        if (!file) {
            if (!create) throw new DOMException(`no such file: ${name}`, 'NotFoundError');
            file = { data: new Uint8Array(8192), size: 0, handle: null };
            this.files.set(name, file);
        }
        return new MockFileHandle(file);
    }

    async getDirectoryHandle() {
        throw new DOMException('flat', 'NotFoundError');
    }

    async *entries() {
        for (const [name, file] of this.files) {
            yield [name, new MockFileHandle(file)];
        }
    }

    [Symbol.asyncIterator]() {
        return this.entries();
    }
}
