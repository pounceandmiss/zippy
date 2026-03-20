#!/usr/bin/env tclsh9.0
#
# Usage: build.tcl <shell> <basedir> <outfile> <appdir> <excludes> [libdir ...]
#
#   shell    - "wish" or "tclsh" (selects base interpreter)
#   basedir  - project root (contains _build/, app files, output)
#   outfile  - full path to output binary
#   appdir   - directory containing app source files (empty string for standalone)
#   excludes - comma-separated names to skip when copying app files
#   libdirs  - lib directories to copy into the image

# ==== Parse args ====
lassign $argv shell baseDir outFile appDir excludes
set libDirs [lrange $argv 5 end]

# ==== Resolve paths ====
set buildDir [file join $baseDir _build]
set prefix [file join $buildDir local]

if {$shell eq "tclsh"} {
    set baseInterp [file join $prefix bin tclsh9.0]
} else {
    set baseInterp [file join $prefix bin wish9.0]
}

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

# ==== 2. Extract base interpreter's zipfs libraries ====
zipfs mount $baseInterp /mnt/static
foreach f [zipfs find //zipfs:/mnt/static] {
    if {[file isfile $f]} {
        set rel [string range $f [string length //zipfs:/mnt/static/] end]
        set dest [file join $tmpDir $rel]
        file mkdir [file dirname $dest]
        file copy -force $f $dest
    }
}
zipfs unmount /mnt/static

# ==== 2b. Patch init.tcl to strip non-zipfs paths from auto_path ====
set initFile [file join $tmpDir tcl_library init.tcl]
if {[file exists $initFile]} {
    set fd [open $initFile a]
    puts $fd {
# Added by zippy build: portable auto_path + self-extracting compiled extensions
set auto_path [lsearch -all -inline $auto_path //zipfs:*]
lappend auto_path //zipfs:/app/lib
set _zippy_exe [info nameofexecutable]
set _zippy_key [file mtime $_zippy_exe]
set _zippy_cache [file join /tmp "zippy-$_zippy_key" lib]
if {![file isdirectory $_zippy_cache]} {
    foreach _zippy_old [glob -nocomplain -directory /tmp zippy-*] {
        catch {file delete -force $_zippy_old}
    }
    file mkdir $_zippy_cache
    foreach _zippy_dir [glob -nocomplain -directory //zipfs:/app/lib */] {
        set _zippy_has_native 0
        foreach _zippy_f [glob -nocomplain -directory $_zippy_dir *] {
            if {[string match *.so $_zippy_f] || [string match *.dll $_zippy_f] || [string match *.dylib $_zippy_f]} {
                set _zippy_has_native 1
                break
            }
        }
        if {$_zippy_has_native} {
            file copy -force $_zippy_dir [file join $_zippy_cache [file tail $_zippy_dir]]
        }
    }
}
if {[file isdirectory $_zippy_cache]} {
    lappend auto_path $_zippy_cache
}
unset -nocomplain _zippy_exe _zippy_key _zippy_cache _zippy_old _zippy_dir _zippy_has_native _zippy_f
    }
    close $fd
}

# ==== 3. Copy extension libraries ====
if {[llength $libDirs] > 0} {
    file mkdir [file join $tmpDir lib]
    foreach dir $libDirs {
        if {[file isdirectory $dir]} {
            file copy -force $dir [file join $tmpDir lib [file tail $dir]]
        }
    }
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
