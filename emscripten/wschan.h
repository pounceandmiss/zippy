/*
 * wschan.h - the entry point of emscripten/wschan.c: WebSockets for Tcl in a
 * browser.
 */
#ifndef ZIPPY_WSCHAN_H
#define ZIPPY_WSCHAN_H

#include <tcl.h>

/*
 * Provide the ::wschan commands in interp. Safe to call from any launcher;
 * the commands work only where JavaScript has a WebSocket, which is every
 * browser and, since node 22, node as well.
 */
int Wschan_Init(Tcl_Interp *interp);

#endif /* ZIPPY_WSCHAN_H */
