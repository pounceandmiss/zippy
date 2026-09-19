/*
 * httpx.h - the entry point of emscripten/httpx.c: HTTP for Tcl in a browser.
 */
#ifndef ZIPPY_HTTPX_H
#define ZIPPY_HTTPX_H

#include <tcl.h>

/* Provide the ::httpx commands in interp. */
int Httpx_Init(Tcl_Interp *interp);

#endif /* ZIPPY_HTTPX_H */
