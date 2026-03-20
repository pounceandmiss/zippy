#!/usr/bin/env tclsh9.0
#
# Usage: build.tcl <shell> <basedir> [appname] [libdir ...]
#
#   shell    - "wish" or "tclsh" (selects base interpreter)
#   basedir  - project root (contains local/, app dir, output)
#   appname  - app directory name to bundle (empty string for standalone interpreter)
#   libdirs  - lib directories to copy into the image

# ==== Parse args ====
lassign $argv shell baseDir appName
set libDirs [lrange $argv 3 end]

# ==== Resolve paths ====
set buildDir [file join $baseDir _build]
set prefix [file join $buildDir local]

if {$shell eq "tclsh"} {
    set baseInterp [file join $prefix bin tclsh9.0]
} else {
    set baseInterp [file join $prefix bin wish9.0]
}

if {$appName ne ""} {
    set appDir  [file join $baseDir $appName]
    set outFile [file join $baseDir bin $appName]
} else {
    set outFile [file join $baseDir bin $shell]
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
if {$appName ne ""} {
    foreach f [glob -directory $appDir *] {
        file copy -force $f [file join $tmpDir [file tail $f]]
    }
}

# ==== 5. Build the zipfs image ====
zipfs mkimg $outFile $tmpDir $tmpDir "" $baseInterp

# ==== 6. Clean up ====
file delete -force $tmpDir

puts "Created: $outFile"
puts "Size: [file size $outFile] bytes"
