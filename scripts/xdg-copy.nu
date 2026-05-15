#!/usr/bin/env nu
# xdg-copy - Copy files via URL (download/upload)
use xdg-utils-common.nu *
# Copy on KDE
def --env copy_kde [source: string, dest: string] {
    let result = (^kfmclient copy $source $dest | complete)
    if ($result.exit_code) == 0 {
        exit_success
    }
    exit_failure_operation_failed
}
# Copy on GNOME
def --env copy_gnome [source: string, dest: string] {
    if (which gio | is-empty) {
        exit_failure_operation_impossible $"no method available for copying '($source)' to '($dest)'"
    }
    let result = (^gio copy $source $dest | complete)
    if ($result.exit_code) == 0 {
        exit_success
    }
    exit_failure_operation_failed
}
# xdg-copy - command line tool for transferring files using desktop integration backends
# Synopsis: xdg-copy [source] [destination]
# Synopsis: xdg-copy { --help | --manual | --version }
def --wrapped main [...args] {
    let args = ($args | each { into string })
    handle_standard_options "xdg-copy" $args [
        "xdg-copy - command line tool for transferring files using desktop integration backends"
        ""
        "Synopsis"
        ""
        "xdg-copy [--help] source [destination]"
        ""
        "xdg-copy { --help | --manual | --version }"
    ]
    if ($args | is-empty) {
        exit_failure_syntax
    }
    mut source = ""
    mut dest = ""
    mut args = $args
    while not ($args | is-empty) {
        let parm = ($args | get 0)
        $args = ($args | skip 1)
        if ($parm | str starts-with "-") {
            exit_failure_syntax $"unexpected option '($parm)'"
        } else if not ($dest | is-empty) {
            exit_failure_syntax $"unexpected argument '($parm)'"
        } else if ($source | is-empty) {
            $source = $parm
        } else {
            $dest = $parm
        }
    }
    if ($source | is-empty) {
        exit_failure_syntax "source argument missing"
    }
    if ($dest | is-empty) {
        exit_failure_syntax "destination argument missing"
    }
    detectDE
    match ($env.DE? | default "") {
        "kde" => { copy_kde $source $dest }
        "gnome" => { copy_gnome $source $dest }
        "cinnamon" => { copy_gnome $source $dest }
        "lxde" => { copy_gnome $source $dest }
        "mate" => { copy_gnome $source $dest }
        "xfce" => { copy_gnome $source $dest }
        "budgie" => { copy_gnome $source $dest }
    }
    exit_failure_operation_impossible $"no method available for copying '($source)' to '($dest)'"
}
