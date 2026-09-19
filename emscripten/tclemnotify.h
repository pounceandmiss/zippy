/*
 * tclemnotify.h - the Emscripten notifier's two entry points.
 */
#ifndef TCLEMNOTIFY_H
#define TCLEMNOTIFY_H

/*
 * Called on the interpreter's own stack after every wait, so the host can move
 * whatever JavaScript has queued into Tcl. See the long comment in
 * tclemnotify.c: JS cannot call into a suspended interpreter, so this is the
 * only safe direction.
 */
typedef void TclEm_PumpProc(void *clientData);

/* Install the notifier. Call before the first interpreter is created. */
void TclEm_InstallNotifier(void);

/* Install the pump. May be called at any time; NULL removes it. */
void TclEm_SetPump(TclEm_PumpProc *proc, void *clientData);

#endif /* TCLEMNOTIFY_H */
