/*
 * The exit test for the emscripten overlay, under node:
 *
 *   node tests/emscripten.mjs ./tclsh.mjs [package ...]
 *
 * Boots the wasm interpreter the launcher exports, then checks the things the
 * overlay exists to make true: the bundled script library mounts, every static
 * package named on the command line resolves through `load {}` (sqlite3 always),
 * SQLite round-trips a row, and - the one that decides whether a wasm Tcl is
 * usable at all - `vwait` returns while JavaScript keeps running. A busy-wait
 * would satisfy "after fires" and "vwait returns"; only a JS timer that ticks
 * *during* the vwait shows the thread was really handed back.
 */
import { pathToFileURL } from 'node:url';
import { resolve } from 'node:path';

const [launcher, ...packages] = process.argv.slice(2);
if (!launcher) {
    console.error('usage: node tests/emscripten.mjs <tclsh.mjs> [package ...]');
    process.exit(2);
}

let failures = 0;
const check = (name, ok, detail = '') => {
    console.log(`${ok ? ' ok ' : 'FAIL'}  ${name}${detail ? ` -- ${detail}` : ''}`);
    if (!ok) failures++;
};

const { default: createTclsh } = await import(pathToFileURL(resolve(launcher)).href);
const M = await createTclsh();

// Asyncify: anything evaluated may vwait, so every call in is async.
const evaluate = async (script) => {
    const rc = await M.ccall('zippy_eval', 'number', ['string'], [script], { async: true });
    return [rc, M.ccall('zippy_result', 'string', [], [])];
};
const ok = async (name, script, want) => {
    const [rc, result] = await evaluate(script);
    check(name, rc === 0 && (want === undefined || result === want), rc === 0 ? result : `error: ${result}`);
    return result;
};

await ok('interpreter boots from the bundled zip', 'info patchlevel');
await ok('the script library is the bundled one', 'string match //zipfs:/app/* [info library]', '1');
await ok('a package the library ships resolves', 'package require msgcat; expr 1', '1');

for (const pkg of ['sqlite3', ...packages]) {
    await ok(`package require ${pkg} (static, via load {})`, `package require ${pkg}; expr 1`, '1');
}

await ok('sqlite3 round-trips a row', `
    sqlite3 db :memory:
    db eval {CREATE TABLE t(x); INSERT INTO t VALUES(42)}
    set v [db eval {SELECT x FROM t}]
    db close
    set v`, '42');

let ticks = 0;
const timer = setInterval(() => ticks++, 10);
const t0 = Date.now();
const fired = await ok('vwait returns', 'after 300 {set ::x fired}; vwait ::x; set ::x', 'fired');
const elapsed = Date.now() - t0;
clearInterval(timer);
check('the timer actually waited', fired === 'fired' && elapsed >= 280, `${elapsed}ms`);
check('JS kept running during vwait', ticks >= 10, `${ticks} timer ticks while Tcl waited`);

const [rc, msg] = await evaluate('this_command_does_not_exist');
check('an error comes back as a code, not a crash', rc !== 0 && msg.includes('invalid command name'), msg);

process.exit(failures ? 1 : 0);
