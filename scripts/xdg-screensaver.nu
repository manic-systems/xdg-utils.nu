#!/usr/bin/env nu
# xdg-screensaver - Control screensaver

use xdg-utils-common.nu *

# Walk /proc looking for an xss-lock invocation bound to this session.
def xss_lock_running [xdg_sid: string]: nothing -> bool {
    if ($"/proc" | path type) != "dir" { return false }
    let candidates = (ls /proc | where {|f| ($f.name | path basename) =~ '^\d+$' })
    for p in $candidates {
        let cmdline_path = ($p.name | path join "cmdline")
        let argv = try {
            open --raw $cmdline_path
            | into binary
            | bytes split 0x[00]
            | each { decode }
            | where { $in != "" }
        } catch { [] }
        if ($argv | is-empty) { continue }
        let exe = ($argv | get 0 | path basename)
        if $exe != "xss-lock" { continue }
        if ($xdg_sid | is-empty) { return true }
        for i in 1..<(($argv | length)) {
            let a = ($argv | get $i)
            if $a == $"--session=($xdg_sid)" { return true }
            if $a == "-s" and (($argv | get ($i + 1) | default "") == $xdg_sid) { return true }
        }
    }
    false
}

# Extract a bool from a gdbus method-call reply like `(true,)` or `(false,)`.
def parse_gdbus_bool [reply: string]: nothing -> string {
    $reply
    | parse --regex '\((?P<v>true|false),?\)'
    | get v?
    | get 0?
    | default ""
}

# Detect whether mv supports -T (GNU mv)
def get_mv_cmd []: nothing -> string {
    if (^mv --help | complete | get stdout | ^grep -qF -- "-T" | complete).exit_code == 0 {
        "mv -T"
    } else {
        "mv"
    }
}

# Compute screensaver state file path
def get_screensaver_file []: nothing -> string {
    let display = ($env.DISPLAY? | default "" | str replace --all ":" "-")
    if (get_mv_cmd) == "mv -T" {
        let user = ($env.USER? | default "unknown")
        $"/tmp/xdg-screensaver-($user)-($display)"
    } else {
        let host = (sys host | get hostname)
        $"/tmp/.xdg-screensaver-($host)-($display)"
    }
}

def do_lockfile [screensaver_file: string] {
    let lockfile_cmd = (which lockfile | get 0?.path | default "")
    if not ($lockfile_cmd | is-empty) {
        ^$lockfile_cmd -1 -l 10 -s 3 $"($screensaver_file).lock" | complete | ignore
    } else {
        mut tries = 0
        while (^ln -s $"($screensaver_file).lock" $"($screensaver_file).lock" | complete).exit_code != 0 {
            sleep 1sec
            $tries = $tries + 1
            if $tries >= 3 {
                rm --force $"($screensaver_file).lock"
                $tries = 0
            }
        }
    }
}

def do_unlockfile [screensaver_file: string] {
    rm --force $"($screensaver_file).lock"
}

# Perform action (called from screensaver implementations for DPMS handling)
def --env perform_action [action: string, screensaver_file: string] {
    if (which xset | is-empty) { return }
    if $action == "resume" {
        if ($"($screensaver_file).dpms" | path type) == "file" {
            rm --force $"($screensaver_file).dpms"
            ^xset +dpms | complete | ignore
        }
    }

    if $action == "reset" {
        if (^xset -q | complete | get stdout | str contains "DPMS is Enabled") {
            ^xset -dpms | complete | ignore
            ^xset +dpms | complete | ignore
            ^xset dpms force on | complete | ignore
        }
    }
}

# Register a window-id suspend in the marker file. On the first suspend we
# also disable the X11 screensaver via xset; resume undoes both.
def --env do_suspend [window_id: string, screensaver_file: string] {
    do_lockfile $screensaver_file
    let is_first = not ($screensaver_file | path exists)
    $"($window_id)\n" | save --append $screensaver_file
    do_unlockfile $screensaver_file
    if $is_first {
        screensaver_xserver "suspend" $screensaver_file | ignore
    }
}

# Remove a window-id from the marker file. If the marker becomes empty,
# re-enable the X11 screensaver and restore DPMS.
def --env do_resume [window_id: string, screensaver_file: string] {
    if not ($screensaver_file | path exists) { return }
    do_lockfile $screensaver_file
    let lines = (open --raw $screensaver_file | lines | where { ($in | is-not-empty) and $in != $window_id })
    if ($lines | is-empty) {
        rm --force $screensaver_file
        do_unlockfile $screensaver_file
        screensaver_xserver "resume" $screensaver_file | ignore
        perform_action "resume" $screensaver_file
    } else {
        ($lines | str join "\n") + "\n" | save --force $screensaver_file
        do_unlockfile $screensaver_file
    }
}

# Check window ID
def check_window_id [window_id: string] {
    let xprop = (which xprop | get 0?.path | default "")
    if ($xprop | is-empty) {
        DEBUG 3 "xprop not found"
        return
    }
    DEBUG 2 $"Running ($xprop) -id ($window_id)"
    let result = (^$xprop -id $window_id | complete)
    if ($result.exit_code) == 0 {
        DEBUG 3 $"Window ($window_id) exists"
    } else {
        DEBUG 3 $"Window ($window_id) does not exist"
        exit_failure_operation_failed $"Window ($window_id) does not exist"
    }
}

# Freedesktop screensaver — returns exit code int.
# Suspend/resume are handled in main; only one-shot actions live here.
def --env screensaver_freedesktop [action: string]: nothing -> int {
    match $action {
        "activate" => { (^gdbus call --session --dest org.freedesktop.ScreenSaver --object-path /ScreenSaver --method org.freedesktop.ScreenSaver.SetActive true | complete).exit_code }
        "lock" => { (^gdbus call --session --dest org.freedesktop.ScreenSaver --object-path /ScreenSaver --method org.freedesktop.ScreenSaver.Lock | complete).exit_code }
        "reset" => { (^gdbus call --session --dest org.freedesktop.ScreenSaver --object-path /ScreenSaver --method org.freedesktop.ScreenSaver.SimulateUserActivity | complete).exit_code }
        "status" => {
            let raw = (^gdbus call --session --dest org.freedesktop.ScreenSaver --object-path /ScreenSaver --method org.freedesktop.ScreenSaver.GetActive --timeout 2 | complete)
            let status = (parse_gdbus_bool $raw.stdout)
            if $status == "true" {
                print "enabled"
            } else if $status == "false" {
                print "disabled"
            } else {
                print --stderr $"ERROR: dbus org.freedesktop.ScreenSaver.GetActive returned '($status)'"
            }
            $raw.exit_code
        }
        _ => { 1 }
    }
}

# KDE 3 screensaver — returns exit code int
def --env screensaver_kde3 [action: string]: nothing -> int {
    match $action {
        "suspend" => { (^dcop kdesktop KScreensaverIface enable false | complete).exit_code }
        "resume" => { (^dcop kdesktop KScreensaverIface configure | complete).exit_code }
        "activate" => { (^dcop kdesktop KScreensaverIface save | complete).exit_code }
        "lock" => { (^dcop kdesktop KScreensaverIface lock | complete).exit_code }
        "reset" => { (^dcop kdesktop KScreensaverIface quit | complete).exit_code }
        "status" => {
            let raw = (^dcop kdesktop KScreensaverIface isEnabled | complete)
            let status = ($raw.stdout | str trim)
            if $status == "true" {
                print "enabled"
            } else if $status == "false" {
                print "disabled"
            } else {
                print --stderr $"ERROR: kdesktop KScreensaverIface isEnabled returned '($status)'"
            }
            $raw.exit_code
        }
        _ => { 1 }
    }
}

# XServer screensaver timeout query
def xset_screensaver_timeout []: nothing -> int {
    if (which xset | is-empty) { return (-1) }
    let output = (^xset q | complete | get stdout)
    let line = ($output | lines | where { $in | str contains "timeout:" } | get 0? | default "")
    if ($line | is-empty) { return (-1) }
    let parsed = ($line | parse --regex 'timeout:\s+(?P<n>\d+)' | get n? | get 0? | default "")
    if ($parsed | is-empty) { -1 } else { try { $parsed | into int } catch { -1 } }
}

def --env screensaver_xserver [action: string, screensaver_file: string]: nothing -> int {
    if (which xset | is-empty) { return 1 }
    let mv_cmd = get_mv_cmd
    match $action {
        "suspend" => {
            let timeout = xset_screensaver_timeout
            if $timeout > 0 {
                $"($timeout)\n" | save --force $"($screensaver_file).xset"
                (^xset s off | complete).exit_code
            } else { 0 }
        }
        "resume" => {
            if ($"($screensaver_file).xset" | path type) == "file" {
                let value = (open --raw $"($screensaver_file).xset" | str trim)
                let r = (^xset s $value | complete).exit_code
                rm --force $"($screensaver_file).xset"
                $r
            } else { 0 }
        }
        "activate" => { (^xset s activate | complete).exit_code }
        "reset" => { (^xset s reset | complete).exit_code }
        "status" => {
            let timeout = xset_screensaver_timeout
            if $timeout > 0 {
                print "enabled"
                0
            } else if $timeout == 0 {
                print "disabled"
                0
            } else {
                print --stderr "ERROR: xset q did not report the screensaver timeout"
                1
            }
        }
        _ => { 1 }
    }
}

# GNOME screensaver — returns exit code int.
# Suspend/resume are handled in main.
def --env screensaver_gnome_screensaver [action: string]: nothing -> int {
    match $action {
        "activate" => { (^gdbus call --session --dest org.gnome.ScreenSaver --object-path /org/gnome/ScreenSaver --method org.gnome.ScreenSaver.SetActive true | complete).exit_code }
        "lock" => { (^gdbus call --session --dest org.gnome.ScreenSaver --object-path /org/gnome/ScreenSaver --method org.gnome.ScreenSaver.Lock | complete).exit_code }
        "reset" => { (^gdbus call --session --dest org.gnome.ScreenSaver --object-path /org/gnome/ScreenSaver --method org.gnome.ScreenSaver.SetActive false | complete).exit_code }
        "status" => {
            let raw = (^gdbus call --session --dest org.gnome.ScreenSaver --object-path /org/gnome/ScreenSaver --method org.gnome.ScreenSaver.GetActive --timeout 2 | complete)
            let status = (parse_gdbus_bool $raw.stdout)
            if $status == "true" or $status == "false" {
                print "enabled"
            } else {
                print "disabled"
            }
            $raw.exit_code
        }
        _ => { 1 }
    }
}

# MATE screensaver — returns exit code int.
# Suspend nudges the screensaver once; sustained inhibition isn't supported
# without a long-running daemon.
def --env screensaver_mate_screensaver [action: string]: nothing -> int {
    match $action {
        "suspend" | "reset" => { (^gdbus call --session --dest org.mate.ScreenSaver --object-path /org/mate/ScreenSaver --method org.mate.ScreenSaver.SimulateUserActivity | complete).exit_code }
        "activate" => { (^gdbus call --session --dest org.mate.ScreenSaver --object-path /org/mate/ScreenSaver --method org.mate.ScreenSaver.SetActive true | complete).exit_code }
        "lock" => { (^mate-screensaver-command --lock | complete).exit_code }
        "status" => {
            let raw = (^gdbus call --session --dest org.mate.ScreenSaver --object-path /org/mate/ScreenSaver --method org.mate.ScreenSaver.GetActive --timeout 2 | complete)
            let status = (parse_gdbus_bool $raw.stdout)
            if $status == "true" or $status == "false" { print "enabled" } else { print "disabled" }
            $raw.exit_code
        }
        _ => { 1 }
    }
}

# Cinnamon screensaver — returns exit code int. Suspend is one-shot.
def --env screensaver_cinnamon_screensaver [action: string]: nothing -> int {
    match $action {
        "suspend" | "reset" => { (^gdbus call --session --dest org.cinnamon.ScreenSaver --object-path /org/cinnamon/ScreenSaver --method org.cinnamon.ScreenSaver.SimulateUserActivity | complete).exit_code }
        "activate" => { (^gdbus call --session --dest org.cinnamon.ScreenSaver --object-path /org/cinnamon/ScreenSaver --method org.cinnamon.ScreenSaver.SetActive true | complete).exit_code }
        "lock" => { (^gdbus call --session --dest org.cinnamon.ScreenSaver --object-path /org/cinnamon/ScreenSaver --method org.cinnamon.ScreenSaver.Lock '""' | complete).exit_code }
        "status" => {
            let raw = (^gdbus call --session --dest org.cinnamon.ScreenSaver --object-path /org/cinnamon/ScreenSaver --method org.cinnamon.ScreenSaver.GetActive --timeout 2 | complete)
            let status = (parse_gdbus_bool $raw.stdout)
            if $status == "true" {
                print "enabled"
            } else if $status == "false" {
                print "disabled"
            } else {
                print --stderr $"ERROR: dbus org.cinnamon.ScreenSaver.GetActive returned '($status)'"
            }
            $raw.exit_code
        }
        _ => { 1 }
    }
}

# XScreenSaver — returns exit code int. Suspend is one-shot.
def --env screensaver_xscreensaver [action: string, screensaver_file: string]: nothing -> int {
    match $action {
        "suspend" | "reset" => { (^xscreensaver-command -deactivate | complete).exit_code }
        "activate" => { (^xscreensaver-command -activate | complete).exit_code }
        "lock" => { (^xscreensaver-command -lock | complete).exit_code }
        "status" => {
            if ($screensaver_file | path type) == "file" { print "disabled" } else { print "enabled" }
            0
        }
        _ => { 1 }
    }
}

# xautolock — returns exit code int
def --env xautolock_screensaver [action: string]: nothing -> int {
    match $action {
        "suspend" => {
            ^xset s off | complete | ignore
            (^xautolock -disable | complete).exit_code
        }
        "resume" => {
            ^xset s default | complete | ignore
            (^xautolock -enable | complete).exit_code
        }
        "activate" => { (^xautolock -enable | complete).exit_code }
        "lock" => { (^xautolock -locknow | complete).exit_code }
        "reset" => { (^xautolock -restart | complete).exit_code }
        "status" => {
            let r = (^xautolock -unlocknow | complete).exit_code
            if $r == 0 { print "enabled" } else { print "disabled" }
            $r
        }
        _ => { 1 }
    }
}

# xdg-screensaver - command line tool for controlling the screensaver
# Synopsis: xdg-screensaver suspend WindowID
# Synopsis: xdg-screensaver resume WindowID
# Synopsis: xdg-screensaver { activate | lock | reset | status }
# Synopsis: xdg-screensaver { --help | --manual | --version }
def --wrapped main [...args] {
    let args = ($args | each { into string })
    handle_standard_options "xdg-screensaver" $args [
        "xdg-screensaver - command line tool for controlling the screensaver"
        ""
        "Synopsis"
        ""
        "xdg-screensaver suspend WindowID"
        "xdg-screensaver resume WindowID"
        "xdg-screensaver { activate | lock | reset | status }"
        ""
        "xdg-screensaver { --help | --manual | --version }"
    ]

    if ($args | is-empty) {
        exit_failure_syntax
    }

    mut action = ""
    mut window_id = ""

    let cmd = ($args | get 0)
    let rest = ($args | skip 1)

    match $cmd {
        "suspend" | "resume" => {
            $action = $cmd
            if ($rest | is-empty) {
                exit_failure_syntax "WindowID argument missing"
            }
            $window_id = ($rest | get 0)
            check_window_id $window_id
        }
        "activate" | "lock" | "reset" | "status" => {
            $action = $cmd
        }
        _ => {
            exit_failure_syntax $"unknown command '($cmd)'"
        }
    }

    detectDE

    let screensaver_file = get_screensaver_file

    # Detect screensaver implementations
    let has_gdbus = (which gdbus | is-not-empty)
    let dbus_owner_exists = {|name|
        (^gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus --method org.freedesktop.DBus.GetNameOwner $'"($name)"' | complete).exit_code == 0
    }

    # Consider "xscreensaver" a separate DE
    if (which xscreensaver-command | is-not-empty) and (^xscreensaver-command -version | complete | get stdout | str contains "XScreenSaver") {
        $env.DE = "xscreensaver"
    }
    # Consider "freedesktop-screensaver" a separate DE
    if $has_gdbus and (do $dbus_owner_exists "org.freedesktop.ScreenSaver") {
        $env.DE = "freedesktop_screensaver"
    }
    # Consider "gnome-screensaver" a separate DE
    if $has_gdbus and (do $dbus_owner_exists "org.gnome.ScreenSaver") {
        $env.DE = "gnome_screensaver"
    }
    # Consider "mate-screensaver" a separate DE
    if $has_gdbus and (do $dbus_owner_exists "org.mate.ScreenSaver") {
        $env.DE = "mate_screensaver"
    }
    # Consider "cinnamon-screensaver" a separate DE
    if $has_gdbus and (do $dbus_owner_exists "org.cinnamon.ScreenSaver") {
        $env.DE = "cinnamon"
    }
    # Consider "xautolock" a separate DE
    # Probe with `which` rather than `xautolock -enable`, which would otherwise
    # enable the autolocker as a side effect just by detecting it.
    if (which xautolock | is-not-empty) {
        $env.DE = "xautolock_screensaver"
    }
    # Consider "xss-lock" a separate DE
    if (which xss-lock | is-not-empty) {
        let xdg_sid = ($env.XDG_SESSION_ID? | default "")
        if (xss_lock_running $xdg_sid) {
            $env.DE = "xss-lock_screensaver"
        }
    }

    # suspend/resume are DE-agnostic: track which windows have an outstanding
    # suspend in $screensaver_file and toggle the X11 screensaver on the first
    # suspend / last resume. Some DEs (KDE3, xautolock, xss-lock) keep their
    # own implementation; route those through the DE table below as before.
    let de = ($env.DE? | default "")
    let de_specific_suspend = $de in ["kde" "xautolock_screensaver" "xss-lock_screensaver"]
    if ($action == "suspend" or $action == "resume") and not $de_specific_suspend {
        if $action == "suspend" {
            do_suspend $window_id $screensaver_file
            # Save DPMS state so we can restore it on resume.
            if not ($env.DISPLAY? | default "" | is-empty) and (which xset | is-not-empty) {
                if (^xset -q | complete | get stdout | str contains "DPMS is Enabled") {
                    let tmpfile = (^mktemp | complete | get stdout | str trim)
                    let mv_cmd = get_mv_cmd
                    if $mv_cmd == "mv -T" { ^mv -T $tmpfile $"($screensaver_file).dpms" } else { ^mv $tmpfile $"($screensaver_file).dpms" }
                    ^xset -dpms | complete | ignore
                }
            }
        } else {
            do_resume $window_id $screensaver_file
        }
        exit_success
    }

    let result = match $de {
        "kde" => {
            if not ($env.KDE_SESSION_VERSION? == null) {
                screensaver_freedesktop $action
            } else {
                screensaver_kde3 $action
            }
        }
        "freedesktop_screensaver" => { screensaver_freedesktop $action }
        "gnome3" => { screensaver_freedesktop $action }
        "gnome_screensaver" => { screensaver_gnome_screensaver $action }
        "mate_screensaver" => { screensaver_mate_screensaver $action }
        "cinnamon" => { screensaver_cinnamon_screensaver $action }
        "xscreensaver" => { screensaver_xscreensaver $action $screensaver_file }
        "xautolock_screensaver" => { xautolock_screensaver $action }
        "xss-lock_screensaver" => {
            if $action == "lock" {
                screensaver_xserver "activate" $screensaver_file
            } else {
                screensaver_xserver $action $screensaver_file
            }
        }
        "xfce" => {
            if not ($env.DISPLAY? | default "" | is-empty) {
                screensaver_xserver $action $screensaver_file
            } else { 0 }
        }
        "budgie" => {
            if ($env.BUDGIE_SESSION_VERSION? | default "" | str starts-with "10.9") {
                screensaver_gnome_screensaver $action
            } else { 1 }
        }
        "generic" | "" => {
            if not ($env.DISPLAY? | default "" | is-empty) {
                screensaver_xserver $action $screensaver_file
            } else { 0 }
        }
        _ => { 1 }
    }

    if $result == 0 {
        exit_success
    }
    exit_failure_operation_failed
}
