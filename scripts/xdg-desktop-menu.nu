#!/usr/bin/env nu
# xdg-desktop-menu - Install menu items on Linux desktop

use xdg-utils-common.nu *

# Update desktop database
def --env update_desktop_database [mode: string] {
    if $mode == "system" {
        for dir in (($env.PATH | split row ":") | append "/opt/gnome/bin") {
            let updater = ($dir | path join "update-desktop-database")
            if (is-executable $updater) {
                DEBUG 1 $"Running ($updater)"
                let _result = (^$updater | complete)
                return
            }
        }
    }
}

# Make application the default for all the mimetypes it supports,
# iff such mimetype didn't already have a default application.
# dir: Install directory for the desktop file
# basefile: Base name of the desktop file
# mode: Installation mode (user or system)
def --env make_lazy_default [dir: string, basefile: string, mode: string] {
    DEBUG 1 $"make_lazy_default ($dir)/($basefile)"
    let mimetypes = (
        open --raw ($dir | path join $basefile)
        | lines
        | each {|l|
            let idx = ($l | str index-of "MimeType=")
            if $idx < 0 { return [] }
            $l | str substring (($idx + 9)..) | split row ";" | where { not ($in | is-empty) }
        }
        | flatten
    )

    for MIME in $mimetypes {
        mut xdg_default_dirs = if (not ($env.XDG_DATA_DIRS? == null) and not ($env.XDG_DATA_DIRS | is-empty)) { $env.XDG_DATA_DIRS } else { "/usr/local/share/:/usr/share/" }
        if $mode == "user" {
            let xdg_user_dir = if (not ($env.XDG_DATA_HOME? == null) and not ($env.XDG_DATA_HOME | is-empty)) { $env.XDG_DATA_HOME } else { $env.HOME | path join ".local" "share" }
            $xdg_default_dirs = $"($xdg_user_dir):($xdg_default_dirs)"
        }

        mut default_app = ""
        for x in ($xdg_default_dirs | split row ":") {
            DEBUG 2 $"Checking ($x)/applications/defaults.list"
            let defaults_path = ($x | path join "applications" "defaults.list")
            let needle = $"($MIME)="
            let match = if ($defaults_path | path type) == "file" {
                open --raw $defaults_path | lines | where {|l| $l | str contains $needle } | get 0? | default ""
            } else { "" }
            let entry = if ($match | is-empty) { "" } else {
                $match | str trim | split row "=" | skip 1 | str join "="
            }
            if not ($entry | is-empty) {
                DEBUG 2 $"Found default apps for ($MIME): ($entry)"
                $default_app = $"($entry);"
                break
            }
        }

        DEBUG 2 $"Current default apps for ($MIME): ($default_app)"
        if not ($default_app | str contains $basefile) {
            let default_file = (xdg_realpath ($dir | path join "defaults.list"))
            if not ($default_file | is-empty) and ($default_file | path type) == "file" {
                DEBUG 1 $"Updating ($default_file)"
                let new_file = $"($default_file).new"
                let needle = $"($MIME)="
                open --raw $default_file | lines | where {|l| not ($l | str contains $needle) } | str join "\n" | save --force $new_file
                let has_header = (open --raw $new_file | str contains "[Default Applications]")
                if not $has_header {
                    "[Default Applications]\n" | save --append $new_file
                }
                $"($MIME)=($default_app)($basefile)\n" | save --append $new_file
                mv $new_file $default_file
            }
        }
    }
}

# Update submenu
def --env update_submenu [menu_file: string, mode: string, action: string, desktop_files: list<string>, directory_files: list<string>, my_umask: string] {
    DEBUG 1 $"update_submenu ($menu_file)"
    let xdg_dir_name = "menus"
    let xdg_user_dir = ($env.XDG_CONFIG_HOME? | default ($env.HOME | path join ".config") | path join $xdg_dir_name)
    let xdg_user_dir = ($xdg_user_dir | path join "applications-merged")

    let xdg_system_dirs = ($env.XDG_CONFIG_DIRS? | default "/etc/xdg")
    mut xdg_global_dir = ""
    for x in ($xdg_system_dirs | split row ":") {
        if (is-writable ($x | path join $xdg_dir_name)) {
            $xdg_global_dir = ($x | path join $xdg_dir_name | path join "applications-merged")
            break
        }
    }

    DEBUG 3 $"xdg_user_dir: ($xdg_user_dir)"
    DEBUG 3 $"xdg_global_dir: ($xdg_global_dir)"

    mut xdg_dir = ""
    if $mode == "user" {
        $xdg_dir = $xdg_user_dir
    } else {
        $xdg_dir = $xdg_global_dir
    }

    if ($xdg_dir | is-empty) {
        exit_failure_operation_impossible "No writable system menu directory found."
    }

    if ($menu_file | is-empty) {
        mkdir $xdg_dir
        touch ($xdg_dir | path join "xdg-utils-dummy.menu")
        return
    }

    # Mandriva workaround
    if $action == "install" and (("/etc/mandrake-release" | path type) == "file") {
        let mandrake_xdg_dir = ($xdg_dir | str replace --all "applications-merged" "applications-mdk-merged")
        if ($mandrake_xdg_dir | path type) != "dir" {
            DEBUG 1 $"Mandriva Workaround: Link '($xdg_dir)' to '($mandrake_xdg_dir)'"
            mkdir ($mandrake_xdg_dir | path dirname)
            try { ^ln -s "applications-merged" $mandrake_xdg_dir }
        }
    }

    # Fedora Core 5 + patched KDE workaround (user mode)
    if $action == "install" and $mode == "user" and (("/etc/xdg/menus/kde-applications-merged" | path type) == "dir") {
        let kde_xdg_dir = ($xdg_dir | str replace --all "applications-merged" "kde-applications-merged")
        if ($kde_xdg_dir | path type) != "dir" {
            DEBUG 1 $"Fedora Workaround: Link '($xdg_dir)' to '($kde_xdg_dir)'"
            mkdir ($kde_xdg_dir | path dirname)
            try { ^ln -s "applications-merged" $kde_xdg_dir }
        }
    }

    # Kubuntu 6.06 workaround (system mode)
    if $action == "install" and $mode == "system" and (("/etc/xdg/menus/kde-applications-merged" | path type) == "dir") and not (("/etc/xdg/menus/applications-merged" | path type) == "dir") {
        DEBUG 1 $"Kubuntu Workaround: Link '($xdg_dir)' to 'kde-applications-merged'"
        try { ^ln -s "kde-applications-merged" $xdg_dir }
    }

    let orig_menu_file = ($xdg_dir | path join $menu_file)
    DEBUG 1 $"Updating ($orig_menu_file)"

    let tmpfile = (mktemp)
    if ($orig_menu_file | path type) == "file" {
        extract_xml_tag_contents $orig_menu_file "Filename" | save --force $tmpfile
    }

    let orig_desktop_files = (open --raw $tmpfile | split row "\n" | where { not ($in | is-empty) })
    mut new_desktop_files: list<string> = []

    if $action == "install" {
        for desktop_file in $desktop_files {
            let basefile = ($desktop_file | path basename)
            let already_listed = (open --raw $tmpfile | lines | any {|l| $l == $basefile })
            if not $already_listed {
                $"($basefile)\n" | save --append $tmpfile
            }
        }
        $new_desktop_files = (open --raw $tmpfile | split row "\n" | where { not ($in | is-empty) })
    }

    if $action == "uninstall" {
        touch $tmpfile
        for desktop_file in $desktop_files {
            $"($desktop_file | path basename)\n" | save --append $tmpfile
        }
        let removed_set = (open --raw $tmpfile | lines)
        for desktop_file in $orig_desktop_files {
            let is_removed = ($removed_set | any {|l| $l == $desktop_file })
            if not $is_removed {
                $new_desktop_files = ($new_desktop_files | append $desktop_file)
            }
        }
    }

    rm --force $tmpfile

    DEBUG 3 $"Files to list in ($menu_file): ($new_desktop_files)"

    if not ($new_desktop_files | is-empty) {
        let tmpfile = (mktemp)
        mkdir $xdg_dir

        let menu_header = "<!DOCTYPE Menu PUBLIC \"-//freedesktop//DTD Menu 1.0//EN\"\n    \"http://www.freedesktop.org/standards/menu-spec/menu-1.0.dtd\">\n<Menu>\n    <Name>Applications</Name>"
        $"($menu_header)\n" | save --force $tmpfile

        for desktop_file in $directory_files {
            let basefile = ($desktop_file | path basename)
            let basefilename = ($basefile | path parse | get stem)
            $"<Menu>\n" | save --append $tmpfile
            $"    <Name>($basefilename)</Name>\n" | save --append $tmpfile
            $"    <Directory>($basefile)</Directory>\n" | save --append $tmpfile
        }

        $"    <Include>\n" | save --append $tmpfile
        for desktop_file in $new_desktop_files {
            $"        <Filename>($desktop_file)</Filename>\n" | save --append $tmpfile
        }
        $"    </Include>\n" | save --append $tmpfile

        for _desktop_file in $directory_files {
            $"</Menu>\n" | save --append $tmpfile
        }
        $"</Menu>\n" | save --append $tmpfile

        let my_chmod = if $mode == "user" { "600" } else { "644" }
        ^chmod $my_chmod $tmpfile
        try { cp $tmpfile ($xdg_dir | path join $menu_file) }
        rm --force $tmpfile
    } else {
        rm --force ($xdg_dir | path join $menu_file)
    }

    # Uninstall .directory files only if no longer referenced
    if $action == "uninstall" {
        let tmpfile = (mktemp)
        for mf in (glob ($xdg_dir | path join "*")) {
            let referenced = (open --raw $mf | str contains "xdg-utils")
            if $referenced {
                extract_xml_tag_contents $mf "Directory" | save --append $tmpfile
            }
        }
        let referenced_set = (open --raw $tmpfile | lines)
        mut remaining_directory_files: list<string> = []
        for desktop_file in $directory_files {
            let still_referenced = ($referenced_set | any {|l| $l == $desktop_file })
            if not $still_referenced {
                # No longer in use, safe to delete
                $remaining_directory_files = ($remaining_directory_files | append $desktop_file)
            }
        }
        rm --force $tmpfile
        # Return remaining_directory_files implicitly (caller can ignore)
    }
}

# xdg-desktop-menu - command line tool for (un)installing desktop menu items
# Synopsis: xdg-desktop-menu install [--noupdate] [--novendor] [--mode mode] directory-file(s) desktop-file(s)
# Synopsis: xdg-desktop-menu uninstall [--noupdate] [--mode mode] directory-file(s) desktop-file(s)
# Synopsis: xdg-desktop-menu forceupdate [--mode mode]
# Synopsis: xdg-desktop-menu { --help | --manual | --version }
def --wrapped main [...args] {
    let args = ($args | each { into string })
    handle_standard_options "xdg-desktop-menu" $args [
        "xdg-desktop-menu - command line tool for (un)installing desktop menu items"
        ""
        "Synopsis"
        ""
        "xdg-desktop-menu install [--noupdate] [--novendor] [--mode mode] directory-file(s) desktop-file(s)"
        "xdg-desktop-menu uninstall [--noupdate] [--mode mode] directory-file(s) desktop-file(s)"
        "xdg-desktop-menu forceupdate [--mode mode]"
        ""
        "xdg-desktop-menu { --help | --manual | --version }"
    ]

    if ($args | is-empty) {
        exit_failure_syntax
    }

    mut mode = ""
    mut action = ""
    mut update = "yes"
    mut desktop_files: list<string> = []
    mut directory_files: list<string> = []

    let cmd = ($args | get 0)
    let args = ($args | skip 1)

    match $cmd {
        "install" => { $action = "install" }
        "uninstall" => { $action = "uninstall" }
        "forceupdate" => { $action = "forceupdate" }
    }

    mut vendor = true
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
            "--novendor" => { $vendor = false }
            _ => {
                if ($parm | str starts-with "-") {
                    exit_failure_syntax $"unexpected option '($parm)'"
                }
                if $action == "install" {
                    check_input_file $parm
                }
                if ($parm | str ends-with ".directory") {
                    $directory_files = ($directory_files | append $parm)
                } else {
                    $desktop_files = ($desktop_files | append $parm)
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
        if ((^id -u | complete | get stdout | str trim | into int) == 0) {
            $mode = "system"
        } else {
            $mode = "user"
        }
    }

    if $action == "forceupdate" {
        update_desktop_database $mode
        exit_success
    }

    if ($desktop_files | is-empty) {
        exit_failure_syntax "desktop-file argument missing"
    }

    if $vendor and $action == "install" {
        for f in $desktop_files {
            check_vendor_prefix $f
        }
    }

    mut menu_name = ""
    for desktop_file in $directory_files {
        if $vendor and $action == "install" {
            check_vendor_prefix $desktop_file
        }
        let basefilename = ($desktop_file | path parse | get stem)
        if ($menu_name | is-empty) {
            $menu_name = $basefilename
        } else {
            $menu_name = $"($menu_name)-($basefilename)"
        }
    }

    let my_umask = if $mode == "user" { "077" } else { "022" }

    if not ($menu_name | is-empty) {
        if $mode == "user" {
            update_submenu $"user-($menu_name).menu" $mode $action $desktop_files $directory_files $my_umask
        } else {
            update_submenu $"($menu_name).menu" $mode $action $desktop_files $directory_files $my_umask
        }
    } else if $mode == "user" {
        update_submenu "" $mode $action $desktop_files $directory_files $my_umask
    }

    # Install .directory files
    let xdg_dir_name = "desktop-directories"
    let xdg_user_dir = ($env.XDG_DATA_HOME? | default ($env.HOME | path join ".local" "share") | path join $xdg_dir_name)
    let xdg_system_dirs = ($env.XDG_DATA_DIRS? | default "/usr/local/share/:/usr/share/")
    mut xdg_global_dir = ""
    for x in ($xdg_system_dirs | split row ":") {
        if (is-writable ($x | path join $xdg_dir_name)) {
            $xdg_global_dir = ($x | path join $xdg_dir_name)
            break
        }
    }

    mut xdg_dir = ""
    if $mode == "user" {
        $xdg_dir = $xdg_user_dir
    } else {
        $xdg_dir = $xdg_global_dir
        if ($xdg_dir | is-empty) {
            exit_failure_operation_impossible "No writable system menu directory found."
        }
    }

    for desktop_file in $directory_files {
        let basefile = ($desktop_file | path basename)
        DEBUG 1 $"($action) ($desktop_file) in ($xdg_dir)"

        if $action == "install" {
            mkdir $xdg_dir
            try { cp $desktop_file ($xdg_dir | path join $basefile) }
        } else if $action == "uninstall" {
            rm --force ($xdg_dir | path join $basefile)
        }
    }

    # Install .desktop files
    let xdg_dir_name2 = "applications"
    let xdg_user_dir2 = ($env.XDG_DATA_HOME? | default ($env.HOME | path join ".local" "share") | path join $xdg_dir_name2)
    let xdg_system_dirs2 = ($env.XDG_DATA_DIRS? | default "/usr/local/share/:/usr/share/")
    mut xdg_global_dir2 = ""
    for x in ($xdg_system_dirs2 | split row ":") {
        if (is-writable ($x | path join $xdg_dir_name2)) {
            $xdg_global_dir2 = ($x | path join $xdg_dir_name2)
            break
        }
    }

    let kde_ver = ($env.KDE_SESSION_VERSION? | default "")
    let kde_user_dir = if not ($kde_ver | is-empty) {
        try { ^$"kde($kde_ver)-config" --path apps | complete | get stdout | str trim | split row ":" | get 0? | default "" } catch { "" }
    } else { "" }
    mut kde_global_dir = if not ($kde_ver | is-empty) {
        try { ^$"kde($kde_ver)-config" --path apps | complete | get stdout | str trim | split row ":" | get 1? | default "" } catch { "" }
    } else { "" }
    if not ($kde_global_dir | is-empty) and not (is-writable $kde_global_dir) {
        $kde_global_dir = ""
    }

    mut xdg_dir2 = ""
    mut kde_dir = ""
    if $mode == "user" {
        $xdg_dir2 = $xdg_user_dir2
        $kde_dir = $kde_user_dir
    } else {
        $xdg_dir2 = $xdg_global_dir2
        $kde_dir = $kde_global_dir
        if ($xdg_dir2 | is-empty) {
            exit_failure_operation_impossible "No writable system menu directory found."
        }
    }

    for desktop_file in $desktop_files {
        if $vendor and $action == "install" {
            check_vendor_prefix $desktop_file
        }
        let basefile = ($desktop_file | path basename)
        DEBUG 1 $"($action) ($desktop_file) in ($xdg_dir2)"

        if $action == "install" {
            mkdir $xdg_dir2
            if not ($kde_dir | is-empty) {
                mkdir $kde_dir
            }
            try { cp $desktop_file ($xdg_dir2 | path join $basefile) }
            if not ($kde_dir | is-empty) {
                try { cp $desktop_file ($kde_dir | path join $basefile) }
            }

            if not ($kde_dir | is-empty) and ($kde_dir | path join $basefile | path type) == "file" {
                $"OnlyShowIn=Old;\n" | save --append ($kde_dir | path join $basefile)
            }
            make_lazy_default $xdg_dir2 $basefile $mode
        } else if $action == "uninstall" {
            rm --force ($xdg_dir2 | path join $basefile)
            if not ($kde_dir | is-empty) {
                rm --force ($kde_dir | path join $basefile)
            }
        }
    }

    if $update == "yes" {
        # Work around for SUSE/gnome 2.12 to pick up new ~/.local/share/applications
        update_desktop_database $mode
    }

    exit_success
}
