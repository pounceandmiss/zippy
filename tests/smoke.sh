#!/usr/bin/env bash
# Integration smoke test. Builds a single ./wish with every dep enabled and
# runs per-feature assertions against it. Wish requires DISPLAY — without
# one, the whole suite skips. Run from the zippy repo root, normally via
# `make -f zippy.mk test`.
#
# Note: this clobbers ./wish at the repo root. `make clean && make` to recover.

set -uo pipefail

cd "$(dirname "$0")/.."

if [[ -z "${DISPLAY:-}" ]]; then
    echo "SKIP: wish requires DISPLAY (start an X server or run under xvfb-run)"
    exit 0
fi

DEPS="tdom mtls tcllib img rtc rtcma omemo tclwuffs tkwuffs"
PASS=0 FAIL=0
BUILDLOG=$(mktemp)
PNG_FILE=$(mktemp --suffix=.png)
trap 'rm -f "$BUILDLOG" "$PNG_FILE"' EXIT

# 8x8 red PNG written to a temp file so Tcl scripts can just -file it without
# any base64/escaping gymnastics inside the assertion strings.
base64 -d > "$PNG_FILE" <<<'iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAEklEQVR4nGP8z4AdMOEQH6QSAM1BAQ/oQeJvAAAAAElFTkSuQmCC'

echo "── building wish with DEPS=\"$DEPS\" ──"
rm -f _build/kitsh_wish ./wish
if ! make -f zippy.mk SHELL_TYPE=wish DEPS="$DEPS" wish >"$BUILDLOG" 2>&1; then
    echo "BUILD FAILED:"
    tail -20 "$BUILDLOG"
    exit 1
fi

# assert <name> <tcl-script>: pipe the script into ./wish, require output
# to contain a line `OK`. Pass script as a single-quoted string to avoid
# bash interpolation of $vars and brackets.
assert() {
    local name=$1 script=$2 out
    printf '── %-25s ' "$name"
    if ! out=$(printf '%s\n' "$script" | ./wish 2>&1); then
        echo "FAIL (run)"
        printf '%s\n' "$out" | sed 's/^/    /'
        ((FAIL++)); return
    fi
    if ! grep -qx OK <<<"$out"; then
        echo "FAIL (assert)"
        printf '%s\n' "$out" | sed 's/^/    /'
        ((FAIL++)); return
    fi
    echo "OK"
    ((PASS++))
}

# check <name> <shell-cmd>: shell-level assertion (ldd, file size, …).
check() {
    local name=$1 cmd=$2
    printf '── %-25s ' "$name"
    if bash -c "$cmd"; then echo "OK"; ((PASS++)); else echo "FAIL"; ((FAIL++)); fi
}

assert "tcl 9" 'if {[info tclversion] eq "9.0"} {puts OK}; exit'
assert "tk loaded" 'package require Tk; puts OK; exit'

assert "tdom parse" 'package require tdom
set d [dom parse {<r><a>hi</a></r>}]
set n [$d selectNodes /r/a/text()]
if {[$n nodeValue] eq "hi"} {puts OK}
exit'

assert "mtls" 'package require mtls; puts OK; exit'

assert "rtc" 'package require rtc; puts OK; exit'

assert "rtcma" 'package require rtcma; puts OK; exit'

assert "omemo version" 'package require omemo
if {[string length [::omemo::version]] > 0} {puts OK}
exit'

# PNG_FILE bash-interpolated into otherwise-single-quoted Tcl.
assert "tclwuffs sniff PNG" '
package require tclwuffs
set f [open '"$PNG_FILE"' rb]
set bytes [read $f]; close $f
if {[::tclwuffs::sniff $bytes] eq "png"} {puts OK}
exit'

assert "tkwuffs decode PNG" '
package require tkwuffs
set f [open '"$PNG_FILE"' rb]
set bytes [read $f]; close $f
image create photo p
::tkwuffs::decode_to_photo $bytes p
if {[image width p] == 8 && [image height p] == 8} {puts OK}
exit'

assert "tcllib json" 'package require json
if {[json::json2dict {{"a":1}}] eq "a 1"} {puts OK}
exit'

# PNG_FILE is bash-interpolated into an otherwise single-quoted Tcl script.
assert "img PNG decode" '
package require Img
set i [image create photo -file '"$PNG_FILE"']
if {[image width $i] == 8 && [$i get 0 0] eq {255 0 0}} {puts OK}
exit'

# ldd assertions: bundled deps must not pull in their system counterparts.
# (libpng/libtiff/libjpeg from Img would show up in ldd if linking went wrong;
# libssl/libcrypto would show up if mtls fell back to system OpenSSL.)
check "mtls bundles ssl"    '! ldd ./wish | grep -qE "\blibssl|\blibcrypto"'
check "img bundles libtiff" '! ldd ./wish | grep -qE "\blibtiff"'
check "img bundles libjpeg" '! ldd ./wish | grep -qE "\blibjpeg"'

echo
echo "passed=$PASS  failed=$FAIL"
[[ $FAIL -eq 0 ]]
