/*
 * Copied unchanged from another-tcl-libs/tclemnotify/tclemnotify.c
 * (codeberg.org/another-im/another-tcl-libs, Pavel R.), where it was written
 * for the anotherim-js browser client. Kept here because every zippy wasm
 * build needs it, not only that one.
 */
/*
 * tclemnotify.c - a Tcl notifier for Emscripten.
 *
 * The problem this solves, stated plainly: Tacky is event-loop driven and
 * `tackyd-json.tcl` ends in `vwait forever`, but a browser thread -- even a
 * Web Worker's -- cannot block. `Tcl_VwaitObjCmd` loops on `Tcl_DoOneEvent`
 * inside a C stack frame, so the only way back to JavaScript from in there is
 * to unwind the whole C stack and rewind it later. That is exactly what
 * Emscripten's Asyncify does, and `emscripten_sleep` is the call that does it.
 *
 * So the notifier is small, and all of the work is in one line: where a Unix
 * notifier would block in `select`/`epoll_wait`, this one sleeps, and the
 * sleep hands the thread back to the JavaScript event loop for the duration.
 * Timers arriving from JS (a postMessage, a WebSocket frame) are queued on the
 * Tcl event queue by the worker glue, and Tcl finds them on the next pass.
 *
 * Installed with `Tcl_SetNotifier`, the same public hook `tclXtNotify.c` uses,
 * so nothing in Tcl itself is patched.
 *
 * Requires `-sASYNCIFY`. Without it `emscripten_sleep` is a link error, which
 * is the right failure: a build that quietly busy-waited would look like it
 * worked and freeze the tab.
 */

#include <emscripten.h>
#include <string.h>
#include <tcl.h>

#include "tclemnotify.h"


/*
 * How long a "wait forever" actually waits before Tcl is given another look.
 *
 * Tcl asks for an unbounded wait whenever nothing is scheduled, which for a
 * chat client is most of the time. The thread is yielded for this long either
 * way, so the cost of a short slice is a wakeup that finds nothing, and the
 * cost of a long one is latency on an event JS queued without alerting us.
 * 20ms is under a frame and cheap enough to be invisible.
 */
#define IDLE_SLICE_MS 20

/*
 * The longest single sleep. A Tcl timer far in the future (Tacky schedules
 * reconnect backoff in minutes) must not turn into one enormous sleep: a
 * sleeping Asyncify stack cannot be interrupted, so an event queued from JS
 * would wait out the whole thing. Chopping it up costs one wakeup per slice.
 */
#define MAX_SLICE_MS 50

static int notifierInitialised = 0;

/*
 * The pump, and why there has to be one.
 *
 * JavaScript cannot call into the interpreter while it is waiting. Asyncify
 * suspends the C stack for the duration of the sleep, and re-entering wasm in
 * that state is not allowed -- a `Module.ccall` made from a JS timer while
 * `vwait` is on the stack does not run, which is how a first version of this
 * spike hung: the JS side set the variable that `vwait forever` was waiting
 * for, and the interpreter never saw it.
 *
 * So the traffic is pulled, not pushed. Whatever the host wants Tcl to see --
 * a postMessage frame, a WebSocket payload, an IndexedDB completion -- is
 * queued on the JavaScript side, and this hook drains that queue on the
 * interpreter's own stack, right after each sleep returns and before Tcl looks
 * at its event queue again.
 *
 * The cost is latency of at most one idle slice (20ms), which for a chat
 * client is nothing, and the benefit is that there is exactly one place where
 * the two worlds touch.
 */
static TclEm_PumpProc *pumpProc = NULL;
static void *pumpClientData = NULL;

void
TclEm_SetPump(TclEm_PumpProc *proc, void *clientData)
{
    pumpProc = proc;
    pumpClientData = clientData;
}

static void *
EmInitNotifier(void)
{
    notifierInitialised = 1;
    /* A non-NULL token; Tcl only ever hands it back to EmFinalizeNotifier. */
    return &notifierInitialised;
}

static void
EmFinalizeNotifier(void *token)
{
    (void)token;
    notifierInitialised = 0;
}

/*
 * Nothing to do. `Tcl_SetTimer` matters only to a notifier embedded in a
 * foreign event loop that has to be told when to call back; ours is asked for
 * a timeout on every `Tcl_WaitForEvent` instead.
 */
static void
EmSetTimer(const Tcl_Time *timePtr)
{
    (void)timePtr;
}

/*
 * Nothing to do either, and this one is load-bearing rather than merely empty:
 * `Tcl_AlertNotifier` exists to wake a notifier blocked in another thread. In
 * a Worker there is one thread, so anything that queues a Tcl event has
 * already run on it, and the sleep below will end on its own.
 */
static void
EmAlertNotifier(void *token)
{
    (void)token;
}

static void
EmServiceModeHook(int mode)
{
    (void)mode;
}

/*
 * File handlers are not implemented, deliberately.
 *
 * A browser has no file descriptors worth waiting on: the network is a
 * WebSocket owned by JavaScript and storage is IndexedDB, both of which reach
 * Tcl as queued events rather than as readable fds. Registering a handler is
 * therefore accepted and ignored -- a channel driver that expected one would
 * simply never fire, which is a bug to catch in the layer above, not here.
 */
static void
EmCreateFileHandler(int fd, int mask, Tcl_FileProc *proc, void *clientData)
{
    (void)fd;
    (void)mask;
    (void)proc;
    (void)clientData;
}

static void
EmDeleteFileHandler(int fd)
{
    (void)fd;
}

/*
 * The whole point.
 *
 * Returns 0 always: no file events are ever detected here, and Tcl's timer
 * and idle handling happens in the generic layer once this returns.
 */
static int
EmWaitForEvent(const Tcl_Time *timePtr)
{
    long ms;

    if (timePtr == NULL) {
        ms = IDLE_SLICE_MS;
    } else {
        ms = (long)timePtr->sec * 1000 + (long)timePtr->usec / 1000;
        if (ms < 0) {
            ms = 0;
        }
        if (ms > MAX_SLICE_MS) {
            ms = MAX_SLICE_MS;
        }
    }

    /*
     * A zero-length poll still yields, which matters: Tcl polls with a zero
     * timeout whenever an idle handler is pending, and a tight loop of those
     * would starve the JS event loop exactly as a block would.
     */
    emscripten_sleep((unsigned int)ms);

    /*
     * On the interpreter's stack again, and nothing of Tcl's is part-way
     * through: the safe moment to let the host queue events.
     */
    if (pumpProc != NULL) {
        pumpProc(pumpClientData);
    }
    return 0;
}

/*
 * Install. Call once, before the first interpreter is created -- Tcl caches
 * its notifier per thread at first use.
 */
void
TclEm_InstallNotifier(void)
{
    Tcl_NotifierProcs procs;

    memset(&procs, 0, sizeof(procs));
    procs.initNotifierProc = EmInitNotifier;
    procs.finalizeNotifierProc = EmFinalizeNotifier;
    procs.alertNotifierProc = EmAlertNotifier;
    procs.setTimerProc = EmSetTimer;
    procs.serviceModeHookProc = EmServiceModeHook;
    procs.waitForEventProc = EmWaitForEvent;
    procs.createFileHandlerProc = EmCreateFileHandler;
    procs.deleteFileHandlerProc = EmDeleteFileHandler;
    Tcl_SetNotifier(&procs);
}
