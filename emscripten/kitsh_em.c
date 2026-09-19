/*
 * kitsh_em.c - the zippy launcher for wasm32-emscripten.
 *
 * The native launcher (kitsh.c) is Tcl_Main over a zip appended to its own
 * executable, found again at runtime through TclZipfs_AppHook. Neither half
 * survives the move to wasm: there is no executable file in the virtual
 * filesystem to read the zip back from, and Tcl_Main is a REPL over stdin.
 *
 * So this launcher takes the `lib` target's shape instead. The script zip is
 * a C array (emscripten/blob2c.tcl) mounted from memory with
 * TclZipfs_MountBuffer, the static packages are registered from the same
 * table kitsh.c uses, and the Emscripten notifier goes in before the first
 * interpreter so that `vwait` yields to the JavaScript event loop rather than
 * freezing the thread (see tclemnotify.c).
 *
 * `main` runs at module instantiation and brings the interpreter up; if the
 * bundle has a main.tcl it is sourced then, otherwise the module waits to be
 * driven through `zippy_eval`, which is how the tests use it. Both are
 * Asyncify-aware entry points: call them with {async: true}, because anything
 * they evaluate may `vwait`.
 */

#include <emscripten.h>
#include <stdio.h>
#include <tcl.h>

#include "static_pkgs.h"
#include "tclemnotify.h"
#include "opfsvfs.h"
#include "wschan.h"
#include "httpx.h"

extern const unsigned char _binary_scripts_zip_start[];
extern const unsigned long _binary_scripts_zip_len;

static Tcl_Interp *interp = NULL;

static int
fail(const char *what)
{
    fprintf(stderr, "zippy: %s: %s\n", what,
        interp ? Tcl_GetStringResult(interp) : "no interpreter");
    return 1;
}

/*
 * Create the interpreter over the bundled scripts. Returns 0 on success.
 * Exported so a host that wants to drive the boot itself (a test, say) can
 * call it instead of relying on main.
 */
EMSCRIPTEN_KEEPALIVE
int
zippy_boot(void)
{
    if (interp != NULL) {
        return 0;
    }
    TclEm_InstallNotifier();
    Tcl_FindExecutable("/zippy");
    interp = Tcl_CreateInterp();
    if (interp == NULL) {
        return fail("Tcl_CreateInterp");
    }
    /* NULL: register lazily, process-wide, resolved by `load {} <Name>`. */
    Zippy_RegisterStaticPackages(NULL);
    if (TclZipfs_MountBuffer(interp, _binary_scripts_zip_start,
            _binary_scripts_zip_len, "//zipfs:/app", 0) != TCL_OK) {
        return fail("TclZipfs_MountBuffer");
    }
    Tcl_SetVar2Ex(interp, "tcl_library", NULL,
        Tcl_NewStringObj("//zipfs:/app/tcl_library", -1), TCL_GLOBAL_ONLY);
    if (Tcl_Init(interp) != TCL_OK) {
        return fail("Tcl_Init");
    }
    /* `::opfsvfs::file` and `::opfsvfs::available`, whether or not a pool is
     * up: the VFS is registered later, from JavaScript, if at all. */
    if (Opfsvfs_Init(interp) != TCL_OK) {
        return fail("Opfsvfs_Init");
    }
    if (Wschan_Init(interp) != TCL_OK) {
        return fail("Wschan_Init");
    }
    if (Httpx_Init(interp) != TCL_OK) {
        return fail("Httpx_Init");
    }
    return 0;
}

/* Evaluate a script. Returns the Tcl completion code; see zippy_result. */
EMSCRIPTEN_KEEPALIVE
int
zippy_eval(const char *script)
{
    if (interp == NULL && zippy_boot() != 0) {
        return TCL_ERROR;
    }
    return Tcl_EvalEx(interp, script, -1, TCL_EVAL_GLOBAL);
}

/* The interpreter's result after the last zippy_eval. */
EMSCRIPTEN_KEEPALIVE
const char *
zippy_result(void)
{
    return interp ? Tcl_GetStringResult(interp) : "";
}

int
main(int argc, char **argv)
{
    (void)argc;
    (void)argv;
    if (zippy_boot() != 0) {
        return 1;
    }
    Tcl_Obj *mainTcl = Tcl_NewStringObj("//zipfs:/app/main.tcl", -1);
    int present;

    Tcl_IncrRefCount(mainTcl);
    present = Tcl_FSAccess(mainTcl, 0) == 0;
    Tcl_DecrRefCount(mainTcl);
    if (present && Tcl_EvalFile(interp, "//zipfs:/app/main.tcl") != TCL_OK) {
        return fail("main.tcl");
    }
    return 0;
}
