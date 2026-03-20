#!/usr/bin/env tclsh9.0
#
# Usage: build.tcl <shell> <basedir> <outfile> <appdir> <excludes> <static_pkgs> [libdir ...]
#
#   shell       - "wish" or "tclsh" (selects base interpreter)
#   basedir     - project root (contains _build/, app files, output)
#   outfile     - full path to output binary
#   appdir      - directory containing app source files (empty string for standalone)
#   excludes    - comma-separated names to skip when copying app files
#   static_pkgs - comma-separated pkg:loadname:version triples for statically
#                 linked packages registered via Tcl_StaticPackage in kitsh.c
#   libdirs     - lib directories to copy into the image

# ==== Parse args ====
lassign $argv shell baseDir outFile appDir excludes staticPkgs
set libDirs [lrange $argv 6 end]

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
# Pass 1: copy each libDir, strip native libs, patch its pkgIndex.tcl so
# `load [file join $dir foo.so] Foo` becomes `load {} Foo` — which resolves
# through Tcl_StaticPackage entries registered in kitsh.c.
set patchedDirs [list]
if {[llength $libDirs] > 0} {
    file mkdir [file join $tmpDir lib]
    foreach dir $libDirs {
        if {[file isdirectory $dir]} {
            set destDir [file join $tmpDir lib [file tail $dir]]
            file copy -force $dir $destDir
            foreach soFile [glob -nocomplain -directory $destDir *.so *.dll *.dylib] {
                file delete $soFile
            }
            set idx [file join $destDir pkgIndex.tcl]
            if {[file exists $idx]} {
                set fd [open $idx r]
                set content [read $fd]
                close $fd
                if {[regsub -all {\[file join \$dir [^\]]+\.(?:so|dll|dylib)\]} \
                        $content {{}} content]} {
                    set fd [open $idx w]
                    puts -nonewline $fd $content
                    close $fd
                    lappend patchedDirs [string tolower [file tail $dir]]
                }
            }
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
    set fd [open [file join $staticDir pkgIndex.tcl] w]
    foreach spec $staticList {
        lassign [split $spec :] pkg loadName version
        puts $fd [list package ifneeded $pkg $version [list load {} $loadName]]
    }
    close $fd
}

# ==== 4. Copy app files (main.tcl goes in the root) ====
if {$appDir ne ""} {
    foreach f [glob -directory $appDir *] {
        set tail [file tail $f]
        if {$tail in $excludeSet} {
            continue
        }
        file copy -force $f [file join $tmpDir $tail]
    }
}

# ==== 5. Build the zipfs image ====
zipfs mkimg $outFile $tmpDir $tmpDir "" $baseInterp

# ==== 6. Clean up ====
file delete -force $tmpDir

puts "Created: $outFile"
puts "Size: [file size $outFile] bytes"
