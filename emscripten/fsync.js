/*
 * Copied unchanged from anotherim-js/worker/js/fsync.js
 * (codeberg.org/another-im/anotherim-js, GPL-3.0-or-later, Pavel R.).
 */
/*
 * fsync, made synchronous again.
 *
 * Emscripten's own `fd_sync` is an *async* syscall: it is written to give
 * IDBFS a chance to flush to IndexedDB, so it goes through
 * `Asyncify.handleAsync` and therefore unwinds the entire C stack on every
 * call. SQLite opens its databases with `PRAGMA synchronous = FULL`, which is
 * the right setting on a desktop and means an fsync per commit -- so with the
 * stock implementation every single commit unwound Tcl, the extension, Rust
 * and SQLite into the Asyncify stack buffer and rewound them afterwards. The
 * symptom was a `boot_eval` that returned a pending Promise and then died with
 * "memory access out of bounds": the unwound stack does not fit in
 * ASYNCIFY_STACK_SIZE, and no plausible size makes it fit.
 *
 * It is also wrong in a subtler way. While the stack is unwound the JS event
 * loop runs, so a message from the page could re-enter the interpreter in the
 * middle of a half-finished transaction.
 *
 * MEMFS has nothing to flush, so returning 0 is exactly correct there.
 * Persistence is not lost by this: it is moved to where it belongs. An IDBFS
 * mount is flushed by calling `FS.syncfs` deliberately, at points the host
 * chooses -- after a batch of writes, on a visibility change -- rather than
 * once per commit, which would be one IndexedDB transaction per message and
 * unusable regardless of Asyncify.
 *
 * Passed to the link with --js-library, after the system libraries, so this
 * definition is the one that wins.
 */
addToLibrary({
    // `fd_sync__async: 'auto'` in Emscripten's own libwasi.js is what marks it,
    // and the annotation lives in a table of its own -- replacing the function
    // alone leaves the import still flagged async and still unwinding. Both
    // have to be said.
    fd_sync__async: false,
    fd_sync: (fd) => 0,
});
