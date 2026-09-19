/*
 * emqueue.c - a JavaScript-to-Tcl event queue, drained on the interpreter's
 * own stack.
 *
 * The interpreter spends most of its life suspended: Tcl's event loop wants
 * to block, a browser thread may not, so zippy's notifier sleeps instead
 * (tclemnotify.c) and Asyncify unwinds the C stack into a side buffer for the
 * duration. JavaScript runs while it is parked, and a callback that tried to
 * call in would find nothing working: Asyncify instruments every function in
 * the module, and one entered from outside while the module is unwound
 * returns immediately without doing its work - not an error, just silence.
 *
 * So nothing is pushed. A JavaScript handler appends its event to an array
 * and returns; this drains the array from a Tcl timer, which runs from the
 * event loop with the whole interpreter available again. The notifier already
 * wakes every 20ms when nothing else is scheduled, so a 10ms timer is the
 * same thread waking at about the same rate. It is armed only while somebody
 * is watching.
 *
 * The notifier has a pump hook of its own (TclEm_SetPump) that would do the
 * same job, but it is a single slot and tacky's shim takes it for the request
 * inbox.
 *
 * Users: emscripten/wschan.c (WebSockets), emscripten/httpx.c (HTTP). Each
 * keeps its own state object under a global name of its own, with a `queue`
 * array of [id, kind, ...fields].
 */

#include <emscripten.h>
#include <stdlib.h>
#include <string.h>
#include <tcl.h>

#include "emqueue.h"

#define EMQ_POLL_MS 10
#define EMQ_MAX_WATCHERS 8
#define EMQ_SEP '\x1f'

EM_JS(char *, EmQueue_Poll, (const char *name), {
    const st = globalThis[UTF8ToString(name)];
    if (!st || st.queue.length === 0) {
        return 0;
    }
    return stringToNewUTF8(st.queue.shift().join("\x1f"));
});

typedef struct {
    EmQueue_DrainProc *proc;
    void *clientData;
} Watcher;

static Watcher watchers[EMQ_MAX_WATCHERS];
static int nWatchers = 0;
static int armed = 0;

static void Tick(void *clientData);

static void
Arm(void)
{
    if (nWatchers > 0 && !armed) {
        armed = 1;
        Tcl_CreateTimerHandler(EMQ_POLL_MS, Tick, NULL);
    }
}

/*
 * A drain may add or remove watchers - a closing socket is the ordinary case
 * - so it runs against a copy, and the list is consulted again only when the
 * next tick is armed.
 */
static void
Tick(void *clientData)
{
    Watcher local[EMQ_MAX_WATCHERS];
    int n = nWatchers, i;

    (void)clientData;
    armed = 0;
    memcpy(local, watchers, (size_t)n * sizeof *local);
    for (i = 0; i < n; i++) {
        local[i].proc(local[i].clientData);
    }
    Arm();
}

void
EmQueue_Watch(EmQueue_DrainProc *proc, void *clientData)
{
    int i;

    for (i = 0; i < nWatchers; i++) {
        if (watchers[i].proc == proc && watchers[i].clientData == clientData) {
            return;
        }
    }
    if (nWatchers == EMQ_MAX_WATCHERS) {
        Tcl_Panic("emqueue: too many watchers");
    }
    watchers[nWatchers].proc = proc;
    watchers[nWatchers].clientData = clientData;
    nWatchers++;
    Arm();
}

void
EmQueue_Unwatch(EmQueue_DrainProc *proc, void *clientData)
{
    int i;

    for (i = 0; i < nWatchers; i++) {
        if (watchers[i].proc == proc && watchers[i].clientData == clientData) {
            watchers[i] = watchers[--nWatchers];
            return;
        }
    }
}

int
EmQueue_Split(char *packed, char **fields, int max)
{
    int n = 0;

    if (packed == NULL || max <= 0) {
        return 0;
    }
    fields[n++] = packed;
    for (; *packed != '\0'; packed++) {
        if (*packed == EMQ_SEP) {
            if (n == max) {
                return n;
            }
            *packed = '\0';
            fields[n++] = packed + 1;
        }
    }
    return n;
}

void
EmQueue_Dispatch(Tcl_Interp *interp, Tcl_Obj *prefix, int nWords,
        char *const *words)
{
    Tcl_Obj *script;
    int i, code;

    /* A copy, because the handler may destroy whatever owns the prefix; a
     * pure list evaluates through Tcl_EvalObjv anyway, so nothing is
     * re-parsed and no word is re-quoted. */
    script = Tcl_DuplicateObj(prefix);
    Tcl_IncrRefCount(script);
    for (i = 0; i < nWords; i++) {
        Tcl_ListObjAppendElement(NULL, script, Tcl_NewStringObj(words[i], -1));
    }
    code = Tcl_EvalObjEx(interp, script, TCL_EVAL_GLOBAL);
    if (code != TCL_OK) {
        Tcl_BackgroundException(interp, code);
    }
    Tcl_DecrRefCount(script);
}
