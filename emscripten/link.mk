# link.mk - the emcc link flags every zippy wasm binary needs, in one place so
# a project linking a zippy-built lib<name>.a (see zippy.mk's `lib` target) can
# `include zippy/emscripten/link.mk` and use ZIPPY_EM_LDFLAGS rather than
# transcribe them. Standalone: nothing here depends on zippy.mk.
#
#   ASYNCIFY          Tcl's event loop blocks in Tcl_WaitForEvent; a browser
#                     thread cannot. tclemnotify.c replaces the wait with
#                     emscripten_sleep, and Asyncify is what lets that unwind
#                     the C stack to the JavaScript event loop and rewind it
#                     later. Without it emscripten_sleep is a link error, which
#                     is the right failure: a build that busy-waited would
#                     freeze the tab.
#   ASYNCIFY_STACK_SIZE
#                     Room for the unwound C stack. 64K covers Tcl's event
#                     loop; a deeper chain (a SQLite commit's fsync, say) does
#                     not fit any plausible size, which is why fsync.js exists.
#   STACK_SIZE        The C stack. Emscripten's default is 64K; Tcl assumes
#                     megabytes.
#   MODULARIZE/EXPORT_ES6
#                     An ES module exporting a factory, loadable from a Web
#                     Worker (`import createX from './x.mjs'`) and from node.
#   EXPORTED_RUNTIME_METHODS
#                     What the JavaScript side reaches for: ccall/cwrap to call
#                     in, the string helpers for EM_JS glue, FS and IDBFS to
#                     mount a persistent filesystem.
#   fsync.js          Makes fd_sync synchronous; see that file. Not optional
#                     once SQLite is in the build.
#   idbfs.js          The IndexedDB-backed filesystem, for a store that must
#                     survive a page reload.
#
# Not here: -sEXPORT_NAME (per binary), -sEXPORTED_FUNCTIONS (the consumer's
# entry points; needed when they live in an archive, since EMSCRIPTEN_KEEPALIVE
# does not pull an archive member in by itself), and -lwebsocket.js (only a
# build that opens sockets from C).

ZIPPY_EM_DIR := $(patsubst %/,%,$(dir $(lastword $(MAKEFILE_LIST))))

ZIPPY_EM_LDFLAGS := \
    -sASYNCIFY -sASYNCIFY_STACK_SIZE=65536 -sSTACK_SIZE=1048576 \
    -sEXIT_RUNTIME=0 -sALLOW_MEMORY_GROWTH=1 \
    -sMODULARIZE=1 -sEXPORT_ES6=1 \
    -sEXPORTED_RUNTIME_METHODS=ccall,cwrap,UTF8ToString,stringToNewUTF8,FS,IDBFS \
    -sUSE_ZLIB=1 \
    --js-library $(ZIPPY_EM_DIR)/fsync.js -lidbfs.js
