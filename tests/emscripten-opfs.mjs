/*
 * The exit test for the OPFS VFS, under node:
 *
 *   node tests/emscripten-opfs.mjs ./tclsh.mjs
 *
 * emscripten/opfsvfs.c puts SQLite's files in a pool of OPFS sync access
 * handles instead of Emscripten's memory filesystem. Node has no OPFS, so the
 * pool runs over tests/opfs-mock-dir.mjs - the real pool code (headers, slot
 * map, the lot) over in-memory files - and everything above it is the real
 * thing: the wasm build's SQLCipher, through the VFS, through EM_JS.
 *
 * What it checks is what the VFS exists to make true, in the shape Tacky uses
 * it: an encrypted database in WAL mode, two connections open at once (a
 * storage migration holds two), a write on one seen by the other, the files
 * still there after a reopen of the pool - which is what a page reload is -
 * and the `::opfsvfs::file` seam for the code that manages database files with
 * `file` rather than through SQLite.
 */
import { pathToFileURL } from 'node:url';
import { resolve } from 'node:path';
import { MockDirectory } from './opfs-mock-dir.mjs';
import { openOpfsPool } from '../emscripten/opfs-pool.js';

const [launcher] = process.argv.slice(2);
if (!launcher) {
    console.error('usage: node tests/emscripten-opfs.mjs <tclsh.mjs>');
    process.exit(2);
}

let failures = 0;
const check = (name, ok, detail = '') => {
    console.log(`${ok ? ' ok ' : 'FAIL'}  ${name}${detail ? ` -- ${detail}` : ''}`);
    if (!ok) failures++;
};

const { default: createTclsh } = await import(pathToFileURL(resolve(launcher)).href);
const M = await createTclsh();

const evaluate = async (script) => {
    const rc = await M.ccall('zippy_eval', 'number', ['string'], [script], { async: true });
    return [rc, M.ccall('zippy_result', 'string', [], [])];
};
const ok = async (name, script, want) => {
    const [rc, result] = await evaluate(script);
    check(name, rc === 0 && (want === undefined || result === want),
        rc === 0 ? result : `error: ${result}`);
    return result;
};

// The interpreter exists before the pool does, exactly as in the worker: the
// module is instantiated, then JavaScript opens the handles, then the VFS is
// registered. ::opfsvfs::available has to follow that, not the boot.
await ok('the Tcl seam is there before any pool', 'info commands ::opfsvfs::file', '::opfsvfs::file');
await ok('... and reports no OPFS yet', 'set ::opfsvfs::available', '0');
check('opfsvfs_register refuses without a pool',
    M.ccall('opfsvfs_register', 'number', ['number'], [1]) !== 0);

const dir = new MockDirectory();
let pool = await openOpfsPool(dir, 16);
check('opfsvfs_register installs the VFS as the default',
    M.ccall('opfsvfs_register', 'number', ['number'], [1]) === 0);
await ok('... and ::opfsvfs::available now says so', 'set ::opfsvfs::available', '1');

await ok('an encrypted database opens in the pool', `
    package require sqlite3
    sqlite3 db /store.db
    db eval {PRAGMA key = 'secret'}
    db eval {PRAGMA journal_mode = WAL}`, 'wal');
await ok('it takes a schema and a row', `
    db eval {CREATE TABLE t(x INTEGER)}
    db eval {INSERT INTO t VALUES(1)}
    db eval {SELECT count(*) FROM t}`, '1');
check('the pool holds the database and its WAL',
    pool.exists('/store.db') && pool.exists('/store.db-wal'), pool.list().join(' '));

// Two connections at once: the pager locks and the heap-backed wal-index in
// opfsvfs.c are there for this, and nothing else exercises them.
await ok('a second connection opens the same database', `
    sqlite3 db2 /store.db
    db2 eval {PRAGMA key = 'secret'}
    db2 eval {SELECT count(*) FROM t}`, '1');
await ok('a commit on one is seen by the other', `
    db eval {INSERT INTO t VALUES(2)}
    db2 eval {SELECT count(*) FROM t}`, '2');
await ok('and a commit on the second is seen by the first', `
    db2 eval {INSERT INTO t VALUES(3)}
    db eval {SELECT sum(x) FROM t}`, '6');

await ok('both close cleanly', 'db close; db2 close; expr 1', '1');

// A page reload: the handles are dropped and the pool is built again over the
// same files, which is where the header in each file earns its keep.
await pool.close_all();
pool = await openOpfsPool(dir, 16);
check('a reopened pool rediscovers the database', pool.exists('/store.db'), pool.list().join(' '));
await ok('the rows survived the reopen', `
    sqlite3 db /store.db
    db eval {PRAGMA key = 'secret'}
    db eval {SELECT sum(x) FROM t}`, '6');
await ok('a wrong key is still refused', `
    sqlite3 bad /store.db
    bad eval {PRAGMA key = 'wrong'}
    set rc [catch {bad eval {SELECT count(*) FROM t}} err]
    bad close
    expr {$rc && [string match "*not a database*" $err]}`, '1');
await ok('close again', 'db close; expr 1', '1');

// ::opfsvfs::file: `file exists`, `file delete`, `file rename` and `glob`
// reach Emscripten's filesystem, where none of these files are.
await ok('opfsvfs::file exists sees a pooled file', 'opfsvfs::file exists /store.db', '1');
await ok('... and not a missing one', 'opfsvfs::file exists /nope.db', '0');
await ok('opfsvfs::file list finds it under a prefix', 'opfsvfs::file list /store', '/store.db');
await ok('opfsvfs::file rename moves it', `
    opfsvfs::file rename /store.db /moved.db
    list [opfsvfs::file exists /store.db] [opfsvfs::file exists /moved.db]`, '0 1');
await ok('the renamed database still opens', `
    sqlite3 db /moved.db
    db eval {PRAGMA key = 'secret'}
    set n [db eval {SELECT sum(x) FROM t}]
    db close
    set n`, '6');
await ok('opfsvfs::file delete removes it', `
    opfsvfs::file delete /moved.db
    opfsvfs::file exists /moved.db`, '0');
await ok('deleting what is not there is not an error',
    'opfsvfs::file delete /moved.db; expr 1', '1');
await ok('renaming what is not there is', `
    expr {[catch {opfsvfs::file rename /nope.db /x.db}]}`, '1');

check('the pool is empty again', pool.list().length === 0, pool.list().join(' '));

process.exit(failures ? 1 : 0);
