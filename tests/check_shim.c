/*
 * check_shim.c - minimal `lib` shim for check-deps.
 */
#include <stddef.h>
#include <tcl.h>
#include "static_pkgs.h"

extern const unsigned char _binary_scripts_zip_start[];
extern const unsigned char _binary_scripts_zip_end[];

int
Zippy_CheckRun(const char *script)
{
    Tcl_Interp *interp;
    int rc;

    Tcl_FindExecutable(NULL);
    interp = Tcl_CreateInterp();
    Zippy_RegisterStaticPackages(NULL);
    rc = TclZipfs_MountBuffer(interp, _binary_scripts_zip_start,
        (size_t)(_binary_scripts_zip_end - _binary_scripts_zip_start),
        "//zipfs:/app", 0);
    if (rc == TCL_OK) rc = Tcl_Init(interp);
    if (rc == TCL_OK) rc = Tcl_Eval(interp, script);
    Tcl_DeleteInterp(interp);
    return rc;
}
