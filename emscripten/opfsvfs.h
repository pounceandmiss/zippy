/*
 * opfsvfs.h - the two entry points of emscripten/opfsvfs.c, for a launcher or
 * a project shim that brings the VFS up.
 */
#ifndef ZIPPY_OPFSVFS_H
#define ZIPPY_OPFSVFS_H

#include <tcl.h>

/*
 * Register the "opfs" VFS, as SQLite's default when makeDefault is true.
 * Returns SQLITE_OK, or SQLITE_ERROR when no pool has been installed (see
 * emscripten/opfs-pool.js) - in which case nothing changes and the caller
 * falls back to another filesystem. Call it from JavaScript, through
 * ccall('opfsvfs_register', ...), once the pool is up and before anything
 * opens a database.
 */
int opfsvfs_register(int makeDefault);

/*
 * Provide `::opfsvfs::file` and `::opfsvfs::available` in interp. Safe to call
 * whether or not a pool exists; `available` follows opfsvfs_register, so an
 * interpreter created before the pool still reports the truth afterwards.
 */
int Opfsvfs_Init(Tcl_Interp *interp);

#endif /* ZIPPY_OPFSVFS_H */
