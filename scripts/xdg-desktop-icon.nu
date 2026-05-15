#!/usr/bin/env nu
# xdg-desktop-icon - Install desktop items

use xdg-utils-common.nu *

# xdg-desktop-icon - command line tool for (un)installing icons to the desktop
# Synopsis: xdg-desktop-icon install [--novendor] FILE
# Synopsis: xdg-desktop-icon uninstall FILE
# Synopsis: xdg-desktop-icon { --help | --manual | --version }
def --wrapped main [...args] {
    let args = ($args | each { into string })
    handle_standard_options "xdg-desktop-icon" $args [
        "xdg-desktop-icon - command line tool for (un)installing icons to the desktop"
        ""
        "Synopsis"
        ""
        "xdg-desktop-icon install [--novendor] FILE"
        "xdg-desktop-icon uninstall FILE"
        ""
        "xdg-desktop-icon { --help | --manual | --version }"
    ]

    if ($args | is-empty) {
        exit_failure_syntax
    }

    mut action = ""
    mut desktop_file = ""
    mut vendor = true

    let cmd = ($args | get 0)
    let args = ($args | skip 1)

    match $cmd {
        "install" => { $action = "install" }
        "uninstall" => { $action = "uninstall" }
    }

    if ($action | is-empty) {
        exit_failure_syntax $"unknown command '($cmd)'"
    }

    mut args = $args
    while not ($args | is-empty) {
        let parm = ($args | get 0)
        $args = ($args | skip 1)

        match $parm {
            "--novendor" => { $vendor = false }
            _ => {
                if not ($desktop_file | is-empty) {
                    exit_failure_syntax $"unexpected argument '($parm)'"
                }
                if $action == "install" {
                    check_input_file $parm
                }
                $desktop_file = $parm
            }
        }
    }

    if ($action | is-empty) {
        exit_failure_syntax "command argument missing"
    }

    if ($desktop_file | is-empty) {
        exit_failure_syntax "FILE argument missing"
    }

    let filetype = if ($desktop_file | str ends-with ".desktop") {
        if $vendor and $action == "install" {
            check_vendor_prefix $desktop_file
        }
        "desktop"
    } else {
        "other"
    }

    mut desktop_dir = (xdg_user_dir "DESKTOP" ($env.HOME | path join "Desktop"))
    let kde_ver = ($env.KDE_SESSION_VERSION? | default "")
    mut desktop_dir_kde = if not ($kde_ver | is-empty) {
        (^$"kde($kde_ver)-config" --userpath desktop | complete | get stdout | str trim)
    } else {
        ""
    }
    mut desktop_dir_gnome = ""

    # GNOME desktop_is_home_dir check
    let gconf_result = (^gconftool-2 -g /apps/nautilus/preferences/desktop_is_home_dir | complete)
    if $gconf_result.exit_code == 0 and ($gconf_result.stdout | str contains "true") {
        $desktop_dir_gnome = $env.HOME
        # Don't create $HOME/Desktop if it doesn't exist
        if not (($desktop_dir | path type) == "dir" and (is-writable $desktop_dir)) {
            $desktop_dir = ""
        }
    }

    # KDE desktop path handling
    if not ($desktop_dir_kde | is-empty) {
        if not (($desktop_dir_kde | path type) == "dir") {
            mkdir $desktop_dir_kde
            ^chmod 700 $desktop_dir_kde
        }
        # Is the KDE desktop dir != $HOME/Desktop?
        let kde_realpath = (xdg_realpath $desktop_dir_kde)
        let dd_realpath = (xdg_realpath $desktop_dir)
        if not ($kde_realpath | is-empty) and not ($dd_realpath | is-empty) and ($kde_realpath != $dd_realpath) {
            # If so, don't create $HOME/Desktop if it doesn't exist
            if not (($desktop_dir | path type) == "dir" and (is-writable $desktop_dir)) {
                $desktop_dir = ""
            }
        } else {
            # Same path, don't use KDE desktop separately
            $desktop_dir_kde = ""
        }
    }

    let basefile = ($desktop_file | path basename)

    DEBUG 1 $"($action) ($desktop_file) in ($desktop_dir)"

    if $action == "install" {
        for dir in [$desktop_dir, $desktop_dir_kde, $desktop_dir_gnome] {
            if not ($dir | is-empty) {
                let target = ($dir | path join $basefile)
                mkdir $dir
                ^chmod 700 $dir
                cp $desktop_file $target
                ^chmod 700 $target
            }
        }
    } else if $action == "uninstall" {
        for dir in [$desktop_dir, $desktop_dir_kde, $desktop_dir_gnome] {
            if not ($dir | is-empty) {
                rm --force ($dir | path join $basefile)
            }
        }
    }

    exit_success
}
