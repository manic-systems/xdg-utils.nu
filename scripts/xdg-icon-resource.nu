#!/usr/bin/env nu
# xdg-icon-resource - Install icons on Linux desktop

use xdg-utils-common.nu *

# Set GTK_UPDATE_ICON_CACHE to gtk-update-icon-cache executable path or
# to "-" if not found.
def find_gtk_update_icon_cache []: nothing -> string {
    for dir in ($env.PATH | split row ":") {
        let updater = ($dir | path join "gtk-update-icon-cache")
        if (is-executable $updater) {
            DEBUG 1 $"Found ($updater)"
            return $updater
        }
    }
    "-"  # "-" means not found
}

# Start GNOME legacy workaround section
def need_dot_icon_path []: nothing -> bool {
  # GTK < 2.6 uses ~/.icons but not XDG_DATA_HOME/icons
  # The availability of gtk-update-icon-cache is used as indication
  # of whether the system is using GTK 2.6 or later
    (find_gtk_update_icon_cache) == "-"
}

# KDE legacy: check if we need to create KDE icon paths
def need_kde_icon_path [path: string] {
    let path = (xdg_realpath $path | str trim)
    DEBUG 2 $"need_kde_icon_path ($path)"
    if ($path | is-empty) {
        DEBUG 2 "need_kde_icon_path RETURN 1 (not needed, no xdg icon dir)"
        return false
    }

    # if kde-config not found... return false
    let kde_version = ($env.KDE_SESSION_VERSION? | default "4")
    let kde_icon_dirs = (try { ^$"kde($kde_version)-config" --path icon | complete | get stdout } catch { "" } | split row ":" | each { |x| $x | str trim } | where { not ($in | is-empty) })
    DEBUG 3 $"kde_icon_dirs: ($kde_icon_dirs)"
    if ($kde_icon_dirs | is-empty) {
        DEBUG 3 $"no result from kde($kde_version)-config --path icon"
        DEBUG 2 "need_kde_icon_path RETURN 1 (not needed, no kde icon path)"
        return false
    }

    mut needed = false
    mut kde_global_prefix = ""
    for y in $kde_icon_dirs {
        let x = (xdg_realpath $y | str trim)
        DEBUG 3 $"Normalize ($y) --> ($x)"
        if not ($x | is-empty) {
            if $x == $path {
                $needed = true
            }
            if (($x | path type) == "dir" and (is-writable $x)) {
                $kde_global_prefix = $x
            }
        }
    }
    DEBUG 2 $"kde_global_prefix: ($kde_global_prefix)"
    # Return true when we DON'T need fallback (path found in kde dirs)
    # Return false when we DO need fallback (path not found in kde dirs)
    if $needed {
        DEBUG 2 "need_kde_icon_path RETURN false (not needed, found in kde dirs)"
        return false
    } else {
        DEBUG 2 "need_kde_icon_path RETURN true (needed, not found in kde dirs)"
        return true
    }
}

def update_icon_database [dir: string] {
    ^touch ($dir | path join "xdg-utils-dummy")
    rm --force ($dir | path join "xdg-utils-dummy")

   # Don't create a cache if there wan't one already
    if ($dir | path join "icon-theme.cache" | path type) == "file" {
        let updater = find_gtk_update_icon_cache
        if $updater != "-" {
            DEBUG 1 $"Running ($updater) -f -t \"($dir)\""
            ^$updater -f -t $dir | complete | ignore
        }
    }
}

# xdg-icon-resource - command line tool for (un)installing icon resources
# Synopsis: xdg-icon-resource install [--noupdate] [--novendor] [--theme theme] [--context context] [--mode mode] --size size icon-file [icon-name]
# Synopsis: xdg-icon-resource uninstall [--noupdate] [--theme theme] [--context context] [--mode mode] --size size icon-name
# Synopsis: xdg-icon-resource forceupdate [--theme theme] [--mode mode]
# Synopsis: xdg-icon-resource { --help | --manual | --version }
def --wrapped main [...args] {
    handle_standard_options "xdg-icon-resource" $args [
        "xdg-icon-resource - command line tool for (un)installing icon resources"
        ""
        "Synopsis"
        ""
        "xdg-icon-resource install [--noupdate] [--novendor] [--theme theme] [--context context] [--mode mode] --size size icon-file [icon-name]"
        "xdg-icon-resource uninstall [--noupdate] [--theme theme] [--context context] [--mode mode] --size size icon-name"
        "xdg-icon-resource forceupdate [--theme theme] [--mode mode]"
        ""
        "xdg-icon-resource { --help | --manual | --version }"
    ]

    if ($args | is-empty) {
        exit_failure_syntax
    }

    mut mode = ""
    mut action = ""
    mut update = "yes"
    mut size = ""
    mut theme = "hicolor"
    mut context = "apps"
    mut icon_file = ""
    mut icon_name = ""
    mut vendor = true

    let cmd = ($args | get 0)
    let args = ($args | skip 1)

    match $cmd {
        "install" => { $action = "install" }
        "uninstall" => { $action = "uninstall" }
        "forceupdate" => { $action = "forceupdate" }
    }

    mut args = $args
    while not ($args | is-empty) {
        let parm = ($args | get 0)
        $args = ($args | skip 1)

        match $parm {
            "--noupdate" => { $update = "no" }
            "--mode" => {
                if ($args | is-empty) {
                    exit_failure_syntax "mode argument missing for --mode"
                }
                let val = ($args | get 0)
                $args = ($args | skip 1)
                match $val {
                    "user" => { $mode = "user" }
                    "system" => { $mode = "system" }
                    _ => { exit_failure_syntax $"unknown mode '($val)'" }
                }
            }
            "--theme" => {
                if ($args | is-empty) {
                    exit_failure_syntax "theme argument missing for --theme"
                }
                $theme = ($args | get 0)
                $args = ($args | skip 1)
            }
            "--size" => {
                if ($args | is-empty) {
                    exit_failure_syntax "size argument missing for --size"
                }
                let val = ($args | get 0)
                $args = ($args | skip 1)
                let is_valid_size = ($val == "scalable") or (try { $val | into int; true } catch { false })
                if not $is_valid_size {
                    exit_failure_syntax "size argument must be numeric or the word 'scalable'"
                }
                $size = $val
            }
            "--context" => {
                if ($args | is-empty) {
                    exit_failure_syntax "context argument missing for --context"
                }
                $context = ($args | get 0)
                $args = ($args | skip 1)
            }
            "--novendor" => { $vendor = false }
            _ => {
                if ($parm | str starts-with "-") {
                    exit_failure_syntax $"unexpected option '($parm)'"
                }
                if $action == "install" {
                    if ($icon_file | is-empty) {
                        check_input_file $parm
                        $icon_file = $parm
                    } else if ($icon_name | is-empty) {
                        $icon_name = $parm
                    } else {
                        exit_failure_syntax $"unexpected argument '($parm)'"
                    }
                } else {
                    if ($icon_name | is-empty) {
                        $icon_name = $parm
                    } else {
                        exit_failure_syntax $"unexpected argument '($parm)'"
                    }
                }
            }
        }
    }

    if ($action | is-empty) {
        exit_failure_syntax "command argument missing"
    }

    if not ($env.XDG_UTILS_INSTALL_MODE? | default "" | is-empty) {
        match $env.XDG_UTILS_INSTALL_MODE {
            "system" => { $mode = "system" }
            "user" => { $mode = "user" }
        }
    }

    if ($mode | is-empty) {
        if (^whoami | complete | get stdout | str trim) == "root" {
            $mode = "system"
        } else {
            $mode = "user"
        }
    }

    let xdg_dir_name = $"icons/($theme)"
    let xdg_user_dir = ($env.XDG_DATA_HOME? | default ($env.HOME | path join ".local" "share") | path join $xdg_dir_name)
    let xdg_user_prefix = ($env.XDG_DATA_HOME? | default ($env.HOME | path join ".local" "share") | path join "icons")
    let xdg_system_dirs = ($env.XDG_DATA_DIRS? | default "/usr/local/share/:/usr/share/")
    mut xdg_global_dir = ""
    for dir in ($xdg_system_dirs | split row ":") {
        if (is-writable ($dir | path join $xdg_dir_name)) {
            $xdg_global_dir = ($dir | path join $xdg_dir_name)
            break
        }
    }

    let xdg_global_prefix = ($env.XDG_DATA_DIRS? | default "/usr/local/share/:/usr/share/" | split row ":" | where { not ($in | is-empty) } | get 0? | default "" | path join "icons")

    mut dot_icon_dir = ""
    mut dot_base_dir = ""
    mut xdg_base_dir = if $mode == "user" { $xdg_user_dir } else { $xdg_global_dir }

    if $action == "forceupdate" {
        if not ($icon_file | is-empty) {
            exit_failure_syntax $"unexpected argument '($icon_file)'"
        }
        update_icon_database $xdg_base_dir
        if not ($dot_icon_dir | is-empty) {
            if (($dot_icon_dir | path type) == "dir" and not ($dot_icon_dir | path type) == "symlink") {
                update_icon_database $dot_base_dir
            }
        }
        exit_success
    }

    if ($icon_file | is-empty) {
        if $action == "install" {
            exit_failure_syntax "icon-file argument missing"
        } else {
            exit_failure_syntax "icon-name argument missing"
        }
    }

    if ($size | is-empty) {
        exit_failure_syntax "the icon size must be specified with --size"
    }

    let xdg_size_name = if $size == "scalable" { $size } else { $"($size)x($size)" }

    mut kde_dir = ""
    if $mode == "user" {
        $xdg_base_dir = $xdg_user_dir
        # KDE 3.x doesn't support XDG_DATA_HOME for icons
        # Check if xdg_dir prefix is listed by kde-config --path icon
        # If not, install additional symlink to kdedir
        if (need_kde_icon_path $xdg_user_prefix) {
            let kde_version = ($env.KDE_SESSION_VERSION? | default "4")
            let kde_user_icon_dir = (try { ^$"kde($kde_version)-config" --path icon | complete | get stdout | str trim } catch { "" } | split row ":" | get 0? | default "" | str trim)
            let kde_user_dir = ($kde_user_icon_dir | path join $theme)
            $kde_dir = ($kde_user_dir | path join $xdg_size_name | path join $context)
        }
        # GNOME 2.8 supports ~/.icons but not XDG_DATA_HOME
        if (need_dot_icon_path) {
            $dot_icon_dir = ($env.HOME | path join ".icons")
            $dot_base_dir = ($dot_icon_dir | path join $theme)
            if ($dot_icon_dir | path type) == "symlink" {
                # Don't do anything
                $dot_icon_dir = ""
            } else if not (($dot_icon_dir | path type) == "dir") {
                # Symlink if it doesn't exist
                try { ^ln -s ".local/share/icons" $dot_icon_dir }
                $dot_icon_dir = ""
            } else {
                $dot_icon_dir = ($dot_icon_dir | path join $theme | path join $xdg_size_name | path join $context)
            }
        }
    } else {
        $xdg_base_dir = $xdg_global_dir
        if ($xdg_base_dir | is-empty) {
            exit_failure_operation_impossible "No writable system icon directory found."
        }
        # KDE 3.x doesn't support XDG_DATA_DIRS for icons
        # Check if xdg_dir prefix is listed by kde-config --path icon
        # If not, install additional symlink to kdedir
        if (need_kde_icon_path $xdg_global_prefix) {
            let kde_version = ($env.KDE_SESSION_VERSION? | default "4")
            let kde_global_icon_dir = (try { ^$"kde($kde_version)-config" --path icon | complete | get stdout | str trim } catch { "" } | split row ":" | get 0? | default "" | str trim)
            let kde_global_dir = ($kde_global_icon_dir | path join $theme)
            $kde_dir = ($kde_global_dir | path join $xdg_size_name | path join $context)
        }
    }
# End KDE legacy workaround section

    # GNOME legacy: check if context is mimetypes
    let need_gnome_mime = if $context == "mimetypes" { true } else { false }

    let extension = if $action == "install" {
        match ($icon_file | path parse | get extension) {
            "xpm" => { "xpm" }
            "png" => { "png" }
            "svg" => { "svg" }
            _ => { "" }
        }
    } else { "" }

    if $xdg_size_name == "scalable" {
        if $extension == "png" {
            exit_failure_syntax "png icons cannot be scalable"
        }
        if $extension == "xpm" {
            exit_failure_syntax "xpm icons cannot be scalable"
        }
    }

    if ($icon_name | is-empty) {
        $icon_name = ($icon_file | path parse | get stem | split row "." | get 0)
    } else {
        if ($icon_name | str ends-with ".png") or ($icon_name | str ends-with ".svg") or ($icon_name | str ends-with ".xpm") {
            exit_failure_syntax "icon name should not include an extension"
        }
    }

    if $vendor and $action == "install" and $context == "apps" {
        check_vendor_prefix $icon_name
    }

    # Compute .icon file path by replacing extension
    let icon_icon_file = ($icon_file | str replace --regex '\.[a-z]{3}$' ".icon")
    let icon_icon_name = $"($icon_name).icon"

    let xdg_dir = ($xdg_base_dir | path join $xdg_size_name | path join $context)

    DEBUG 1 $"($action) icon in ($xdg_dir)"
    if $action == "install" and ($icon_icon_file | path type) == "file" {
        DEBUG 1 $"install ($icon_icon_name) meta file in ($xdg_dir)"
    }
    if not ($kde_dir | is-empty) {
        DEBUG 1 $"($action) symlink in ($kde_dir) (KDE 3.x support)"
    }
    if $need_gnome_mime {
        DEBUG 1 $"($action) gnome-mime-($icon_name) symlink (GNOME 2.x support)"
    }
    if $action == "install" and not ($dot_icon_dir | is-empty) {
        DEBUG 1 $"($action) ~/.icons symlink (GNOME 2.8 support)"
    }

    let my_umask = if $mode == "user" { "077" } else { "022" }

    if $action == "install" {

        # Loop over xdg_dir and dot_icon_dir
        for icon_dir in [$xdg_dir, $dot_icon_dir] {
            if ($icon_dir | is-empty) { continue }
            mkdir $icon_dir
            try { cp $icon_file ($icon_dir | path join $"($icon_name).($extension)") }
            if ($icon_icon_file | path type) == "file" {
                try { cp $icon_icon_file ($icon_dir | path join $icon_icon_name) }
            }
            if $need_gnome_mime {
                try { ^ln -s $"($icon_name).($extension)" ($icon_dir | path join $"gnome-mime-($icon_name).($extension)") }
            }
        }

        # KDE symlinks for KDE 3.x compatibility
        if not ($kde_dir | is-empty) {
            mkdir $kde_dir
            try { ^ln -s $"($xdg_dir)/($icon_name).($extension)" ($kde_dir | path join $"($icon_name).($extension)") }
        }

    } else if $action == "uninstall" {
        # Loop over xdg_dir and dot_icon_dir
        for icon_dir in [$xdg_dir, $dot_icon_dir] {
            if ($icon_dir | is-empty) { continue }
            rm --force ($icon_dir | path join $"($icon_name).xpm")
            rm --force ($icon_dir | path join $"($icon_name).png")
            rm --force ($icon_dir | path join $"($icon_name).svg")
            rm --force ($icon_dir | path join $icon_icon_name)
            if $need_gnome_mime {
                rm --force ($icon_dir | path join $"gnome-mime-($icon_name).xpm")
                rm --force ($icon_dir | path join $"gnome-mime-($icon_name).png")
                rm --force ($icon_dir | path join $"gnome-mime-($icon_name).svg")
            }
        }

        # KDE symlinks cleanup
        if not ($kde_dir | is-empty) {
            rm --force ($kde_dir | path join $"($icon_name).xpm")
            rm --force ($kde_dir | path join $"($icon_name).png")
            rm --force ($kde_dir | path join $"($icon_name).svg")
        }
    }

    if $update == "yes" {
        update_icon_database $xdg_base_dir
    }

    exit_success
}
