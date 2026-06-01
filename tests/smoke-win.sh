#!/usr/bin/env bash
# Windows (MinGW-w64) integration smoke test, the cross-build counterpart of
# tests/smoke.sh. Builds ./wish.exe with every dep and runs per-feature
# assertions against it under wine. Tk needs a display, so the suite skips
# without one (or run under xvfb-run). Run from the repo root, normally via
# `make -f zippy.mk TARGET_OS=windows win-test`.
#
# Note: this clobbers ./wish.exe at the repo root. Rebuild with win-wish.

set -uo pipefail

cd "$(dirname "$0")/.."

if ! command -v wine >/dev/null 2>&1; then
    echo "SKIP: wine is not installed"
    exit 0
fi
if [[ -z "${DISPLAY:-}" ]]; then
    echo "SKIP: wish.exe under wine needs a display (start an X server or run under xvfb-run)"
    exit 0
fi

export WINEDEBUG=${WINEDEBUG:--all}

DEPS="tdom mtls tcllib img rtc rtcma omemo tclwuffs tkwuffs tkdnd"
PASS=0 FAIL=0
BUILDLOG=$(mktemp)
SCRIPT=$(mktemp --suffix=.tcl)
PNG_FILE=$(mktemp --suffix=.png)
trap 'rm -f "$BUILDLOG" "$SCRIPT" "$PNG_FILE"' EXIT

# 8x8 red PNG for the image-decode assertions.
base64 -d > "$PNG_FILE" <<<'iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAEklEQVR4nGP8z4AdMOEQH6QSAM1BAQ/oQeJvAAAAAElFTkSuQmCC'

echo "── building ./wish.exe with DEPS=\"$DEPS\" ──"
if ! make -f zippy.mk TARGET_OS=windows win-wish DEPS="$DEPS" >"$BUILDLOG" 2>&1; then
    echo "BUILD FAILED:"
    tail -20 "$BUILDLOG"
    exit 1
fi

# assert <name> <tcl-body>: run the body under wine inside a catch so a failure
# prints the error rather than popping an (invisible, hang-prone) wish bgerror
# dialog; the body should `error` on failure. Output is CRLF, so strip CR before
# the exact `OK` match. The script goes to a file because stdin piping doesn't
# survive wine.
assert() {
    local name=$1 body=$2 out
    printf '── %-22s ' "$name"
    # $png is the test PNG, injected so bodies stay single-quoted (no bash interp).
    printf 'set png {%s}\nif {[catch {%s} e]} {puts "FAIL: $e"} else {puts OK}\nexit\n' \
        "$PNG_FILE" "$body" > "$SCRIPT"
    out=$(wine ./wish.exe "$SCRIPT" 2>/dev/null | tr -d '\r')
    if grep -qx OK <<<"$out"; then
        echo "OK"; ((PASS++))
    else
        echo "FAIL"; printf '%s\n' "$out" | sed 's/^/    /'; ((FAIL++))
    fi
}

# check <name> <shell-cmd>: shell-level assertion (PE inspection, ...).
check() {
    local name=$1 cmd=$2
    printf '── %-22s ' "$name"
    if bash -c "$cmd"; then echo "OK"; ((PASS++)); else echo "FAIL"; ((FAIL++)); fi
}

assert "tcl 9"        'if {[info tclversion] ne "9.0"} {error $tcl_version}'
assert "tk"           'package require Tk'
assert "thread"       'package require Thread
set t [thread::create {thread::wait}]
thread::send $t {expr 6*7} r
if {$r != 42} {error $r}
thread::release $t'
assert "sqlite3"      'package require sqlite3
sqlite3 db :memory:
db eval {create table t(x); insert into t values(42)}
if {[db eval {select x from t}] != 42} {error fail}
db close'
assert "tdom"         'package require tdom
set d [dom parse {<r><a>hi</a></r>}]
if {[[$d selectNodes /r/a/text()] nodeValue] ne "hi"} {error mismatch}'
assert "tcllib json"  'package require json
if {[json::json2dict {{"a":1}}] ne "a 1"} {error fail}'
assert "mtls"         'package require mtls'
assert "omemo"        'package require omemo
if {[string length [::omemo::version]] == 0} {error noversion}'
assert "tclwuffs"     'package require tclwuffs
set f [open $png rb]; set b [read $f]; close $f
if {[::tclwuffs::sniff $b] ne {png}} {error notpng}'
assert "tkwuffs"      'package require tkwuffs
set f [open $png rb]; set b [read $f]; close $f
image create photo p
::tkwuffs::decode_to_photo $b p
if {[image width p] != 8} {error badsize}'
assert "img decode"   'package require Img
set i [image create photo -file $png]
if {[image width $i] != 8 || [$i get 0 0] ne {255 0 0}} {error baddecode}'
assert "tkdnd"        'package require tkdnd
tkdnd::drop_target register . DND_Files
if {![llength [info commands ::tkdnd::drop_target]]} {error noreg}'

# A working exe is a static PE that links the Tcl/Tk core, never importing
# tcl90.dll/tk90.dll (the dynamic-stub trap).
check "PE32+ executable"  'file -b ./wish.exe | grep -q "PE32+ executable"'
check "no tcl/tk dll dep" \
  '! x86_64-w64-mingw32-objdump -p ./wish.exe | grep -qiE "DLL Name:.*(tcl|tk)9[0-9]\.dll"'

echo
echo "passed=$PASS  failed=$FAIL"
[[ $FAIL -eq 0 ]]
