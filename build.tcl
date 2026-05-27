#!/usr/bin/env tclsh9.0
#
# Usage: build.tcl <shell> <basedir> <outfile> <sources> <entry_script> <excludes> <static_pkgs> [libdir ...]
#
#   shell        - "wish" or "tclsh" (selects base interpreter)
#   basedir      - project root (contains _build/, app files, output)
#   outfile      - full path to output binary
#   sources      - comma-separated list of paths to bundle. Each path is copied
#                  under its basename. Special case: an entry whose basename is
#                  "." or empty (e.g. "./") globs its CONTENTS into the root.
#                  Empty string = standalone (no app bundling).
#   entry_script - path within the bundled tree of the startup script. If not
#                  "main.tcl", a synthetic main.tcl is written at the zipfs
#                  root that sources this path. Empty for standalone.
#   excludes     - comma-separated names to skip when copying app files
#   static_pkgs  - comma-separated pkg:loadname:version triples for statically
#                  linked packages registered via Tcl_StaticPackage in kitsh.c
#   libdirs      - lib directories to copy into the image

# ==== Helpers ====

proc readFile {path} {
    set fd [open $path r]
    try {
        return [read $fd]
    } finally {
        close $fd
    }
}

proc writeFile {path content} {
    set fd [open $path w]
    try {
        puts -nonewline $fd $content
    } finally {
        close $fd
    }
}

# Rewrite `load [file join $dir foo.so] Foo` to `load {} Foo` in a pkgIndex.tcl,
# so the package resolves through Tcl_StaticPackage entries registered in
# kitsh.c instead of trying to dlopen a non-existent shared library. Returns
# 1 if the file was patched, 0 if no matching load lines were found.
proc patchPkgIndexLoadPaths {pkgIndex} {
    set content [readFile $pkgIndex]
    set hits [regsub -all {\[file join \$dir [^\]]+\.(?:so|dll|dylib)\]} \
        $content {{}} content]
    if {$hits == 0} { return 0 }
    writeFile $pkgIndex $content
    return 1
}

# ==== Parse args ====
lassign $argv shell baseDir outFile sources entryScript excludes staticPkgs
set libDirs [lrange $argv 7 end]

# ==== Resolve paths ====
set buildDir [file join $baseDir _build]
set prefix [file join $buildDir local]

set baseInterp [file join $buildDir kitsh_$shell]

# ==== Build exclude set ====
set excludeSet [list]
foreach name [split $excludes ,] {
    set name [string trim $name]
    if {$name ne ""} {
        lappend excludeSet $name
    }
}

# ==== 1. Create staging dir ====
set tmpDir [file join $buildDir tmp]
file delete -force $tmpDir
file mkdir $tmpDir

# ==== 2. Copy Tcl/Tk library from installed prefix ====
set tclVer [info tclversion]
file copy [file join $prefix lib "tcl$tclVer"] [file join $tmpDir tcl_library]
if {$shell eq "wish"} {
    set tkDir [file join $prefix lib "tk$tclVer"]
    if {[file isdirectory $tkDir]} {
        file copy $tkDir [file join $tmpDir tk_library]
    }
}

# Tcl 9 standard-library Tcl Modules (tcltest, http, etc.) live under
# lib/tcl9/<ver>. ::tcl::tm::Defaults derives the search path from
# [file dirname [info library]], so they need to land at <root>/tcl9/<ver>/
# in the staged image to be discovered.
set tmMajor [lindex [split $tclVer .] 0]
set tmSrc [file join $prefix lib "tcl$tmMajor" $tclVer]
if {[file isdirectory $tmSrc]} {
    set tmDst [file join $tmpDir "tcl$tmMajor" $tclVer]
    file mkdir [file dirname $tmDst]
    file copy $tmSrc $tmDst
}

# ==== 2b. Patch init.tcl to strip non-zipfs paths from auto_path ====
set initFile [file join $tmpDir tcl_library init.tcl]
if {[file exists $initFile]} {
    set fd [open $initFile a]
    puts $fd {
	# Added by zippy build: restrict auto_path to zipfs paths
	set auto_path [lsearch -all -inline $auto_path //zipfs:*]
	lappend auto_path //zipfs:/app/lib
    }
    close $fd
}

# ==== 3. Copy extension libraries ====
# Pass 1: for each libDir, copy it into the staging tree, strip the binary
# libs (they're not loadable from a zipfs and just bloat the image), and
# patch its pkgIndex.tcl to route `load` through Tcl_StaticPackage.
set patchedDirs [list]
if {[llength $libDirs] > 0} {
    file mkdir [file join $tmpDir lib]
    foreach dir $libDirs {
        if {![file isdirectory $dir]} continue
        set destDir [file join $tmpDir lib [file tail $dir]]
        file copy -force $dir $destDir
        foreach binFile [glob -nocomplain -directory $destDir *.so *.dll *.dylib *.a] {
            file delete $binFile
        }
        set pkgIndex [file join $destDir pkgIndex.tcl]
        if {[file exists $pkgIndex] && [patchPkgIndexLoadPaths $pkgIndex]} {
            lappend patchedDirs [string tolower [file tail $dir]]
        }
    }
}

# Pass 2: synthesize a pkgIndex.tcl for any static package whose own lib dir
# wasn't copied+patched above (fallback for packages with no on-disk index).
set staticList [list]
foreach spec [split $staticPkgs ,] {
    set spec [string trim $spec]
    if {$spec eq ""} continue
    set pkg [lindex [split $spec :] 0]
    set covered 0
    foreach tail $patchedDirs {
        if {[string match "[string tolower $pkg]*" $tail]} {
            set covered 1
            break
        }
    }
    if {!$covered} {
        lappend staticList $spec
    }
}
if {[llength $staticList] > 0} {
    set staticDir [file join $tmpDir lib zippy_statics]
    file mkdir $staticDir
    set entries [list]
    foreach spec $staticList {
        lassign [split $spec :] pkg loadName version
        lappend entries [list package ifneeded $pkg $version [list load {} $loadName]]
    }
    writeFile [file join $staticDir pkgIndex.tcl] [join $entries \n]\n
}

# ==== 4. Copy app files ====
# Each SOURCES entry: if its basename is `.` or empty (e.g. "./"), glob its
# contents into the zipfs root (drop-in default for single-dir projects).
# Otherwise copy the entry preserving its basename. Top-level excludes apply
# in both modes (to the immediate children in glob mode, or to the entry
# itself in basename mode).
set sourceList [list]
foreach s [split $sources ,] {
    set s [string trim $s]
    if {$s ne ""} { lappend sourceList $s }
}
foreach src $sourceList {
    set tail [file tail $src]
    if {$tail eq "" || $tail eq "."} {
        # Glob-contents mode.
        foreach f [glob -nocomplain -directory $src *] {
            set ftail [file tail $f]
            if {$ftail in $excludeSet} continue
            file copy -force $f [file join $tmpDir $ftail]
        }
    } else {
        # Basename-preserved mode.
        if {$tail in $excludeSet} continue
        if {![file exists $src]} {
            error "SOURCES entry not found: $src"
        }
        set dst [file join $tmpDir $tail]
        if {[file exists $dst]} {
            puts "warning: SOURCES basename collision on '$tail' — last write wins"
            file delete -force $dst
        }
        file copy -force $src $dst
    }
}

# Synthesize a main.tcl at the zipfs root if the entry script lives elsewhere.
# Kitsh registers //zipfs:/app/main.tcl as the startup script unconditionally,
# so the synthetic stub just sources the real entry.
if {$entryScript ne "" && $entryScript ne "main.tcl"} {
    set entryPath [file join $tmpDir $entryScript]
    if {![file exists $entryPath]} {
        error "ENTRY_SCRIPT not found in bundled tree: $entryScript"
    }
    writeFile [file join $tmpDir main.tcl] \
        "source \[file join //zipfs:/app $entryScript\]\n"
}

# ==== 5. Build the zipfs image ====
zipfs mkimg $outFile $tmpDir $tmpDir "" $baseInterp

# ==== 6. Clean up ====
file delete -force $tmpDir

puts "Created: $outFile"
puts "Size: [file size $outFile] bytes"
