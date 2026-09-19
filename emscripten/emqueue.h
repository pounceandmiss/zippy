/*
 * emqueue.h - a JavaScript-to-Tcl event queue, drained on the interpreter's
 * own stack. See emqueue.c for why it has to work that way.
 */
#ifndef ZIPPY_EMQUEUE_H
#define ZIPPY_EMQUEUE_H

#include <tcl.h>

/* Called from a Tcl timer while this module has anything to watch. */
typedef void EmQueue_DrainProc(void *clientData);

/* Start and stop draining. Both are idempotent for a given (proc, data). */
void EmQueue_Watch(EmQueue_DrainProc *proc, void *clientData);
void EmQueue_Unwatch(EmQueue_DrainProc *proc, void *clientData);

/*
 * The oldest event from globalThis[name].queue - an array of arrays, whose
 * first element is the id of whatever queued it - as separator-joined fields,
 * or NULL when there is none. The caller frees it with free().
 */
char *EmQueue_Poll(const char *name);

/*
 * Split a polled event in place. Returns the number of fields found (the id
 * is fields[0]), at most max; the last field keeps the rest of the event
 * verbatim, separators and all, so a caller passes the arity of the event it
 * is reading and free-form text goes last. The separator is US (0x1f).
 */
int EmQueue_Split(char *packed, char **fields, int max);

/*
 * Evaluate a command prefix with words appended, reporting a failure to
 * bgerror the way any other event-driven callback would. The prefix is
 * copied first: a handler is entitled to destroy whatever owns it.
 */
void EmQueue_Dispatch(Tcl_Interp *interp, Tcl_Obj *prefix, int nWords,
        char *const *words);

#endif /* ZIPPY_EMQUEUE_H */
