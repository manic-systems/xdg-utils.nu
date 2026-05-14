#!/usr/bin/env nu
# xdg-terminal - Open terminal emulator

use xdg-utils-common.nu *

# Open terminal on KDE
def --env terminal_kde [command: string] {
    let kreadconfig = if (($env.KDE_SESSION_VERSION? | default "0" | into int) >= 5) {
        $"kreadconfig($env.KDE_SESSION_VERSION)"
    } else {
        "kreadconfig"
    }

    if (which $kreadconfig | is-empty) {
        exit_failure_operation_impossible $"($kreadconfig) was not found or is not executable"
    }

    let terminal = (^$kreadconfig --file kdeglobals --group General --key TerminalApplication --default konsole | complete | get stdout | str trim)
    let terminal_exec = (which $terminal | get 0?.path | default "")

    if not ($terminal_exec | is-empty) and (is-executable $terminal_exec) {
        let result = if ($command | is-empty) {
            ^$terminal_exec | complete
        } else {
            ^$terminal_exec -e $command | complete
        }
        if ($result.exit_code) == 0 {
            exit_success
        }
        exit_failure_operation_failed
    }
    exit_failure_operation_impossible $"configured terminal program '($terminal)' not found or not executable"
}

# Open terminal on GNOME
def --env terminal_gnome [command: string] {
    let term_exec = (^gconftool-2 --get /desktop/gnome/applications/terminal/exec | complete | get stdout | str trim)
    let term_exec_arg = (^gconftool-2 --get /desktop/gnome/applications/terminal/exec_arg | complete | get stdout | str trim)
    let terminal_exec = (which $term_exec | get 0?.path | default "")

    if not ($terminal_exec | is-empty) and (is-executable $terminal_exec) {
        let result = if ($command | is-empty) {
            ^$terminal_exec | complete
        } else if ($term_exec_arg | is-empty) {
            ^$terminal_exec $command | complete
        } else if ($term_exec_arg | str contains "-x") {
            ^$terminal_exec $term_exec_arg $"sh -c '($command)'" | complete
        } else {
            ^$terminal_exec $term_exec_arg $command | complete
        }
        if ($result.exit_code) == 0 {
            exit_success
        }
        exit_failure_operation_failed
    }
    exit_failure_operation_impossible $"configured terminal program '($term_exec)' not found or not executable"
}

# Open terminal using gsettings
def --env terminal_gsettings [schema: string, command: string] {
    let term_exec_raw = (^gsettings get $schema exec | complete | get stdout | str trim)
    let term_exec = ($term_exec_raw | str replace --regex "^'(.*)'$" "$1")
    let term_exec_arg_raw = (^gsettings get $schema exec-arg | complete | get stdout | str trim)
    let term_exec_arg = ($term_exec_arg_raw | str replace --regex "^'(.*)'$" "$1")
    let terminal_exec = (which $term_exec | get 0?.path | default "")

    if not ($terminal_exec | is-empty) and (is-executable $terminal_exec) {
        let result = if ($command | is-empty) {
            ^$terminal_exec | complete
        } else if ($term_exec_arg | is-empty) {
            ^$terminal_exec $command | complete
        } else if ($term_exec_arg | str contains "-x") {
            ^$terminal_exec $term_exec_arg $"sh -c '($command)'" | complete
        } else {
            ^$terminal_exec $term_exec_arg $command | complete
        }
        if ($result.exit_code) == 0 {
            exit_success
        }
        exit_failure_operation_failed
    }
    exit_failure_operation_impossible $"configured terminal program '($term_exec)' not found or not executable"
}

# Open terminal on XFCE
def --env terminal_xfce [command: string] {
    let result = if ($command | is-empty) {
        ^exo-open --launch TerminalEmulator | complete
    } else {
        ^exo-open --launch TerminalEmulator $command | complete
    }
    if ($result.exit_code) == 0 {
        exit_success
    }
    exit_failure_operation_failed
}

# Generic terminal
def --env terminal_generic [command: string] {
    # if $TERM is a known non-command, use hard-coded fallbacks
    let term = if ($env.TERM | is-empty) or ($env.TERM == "linux") or ($env.TERM == "vt100") {
        "xterm"
    } else {
        $env.TERM
    }

    let terminal_exec = (which $term | get 0?.path | default "")

    if not ($terminal_exec | is-empty) and (is-executable $terminal_exec) {
        let result = if ($command | is-empty) {
            ^$terminal_exec | complete
        # screen and urxvt won't do their own parsing of quoted arguments
        } else if $term == "screen" {
            # screen has an incompatible meaning for -e
            ^sh -c $"exec ($terminal_exec) ($command)" | complete
        } else if ($term == "urxvt") or ($term == "rxvt-unicode") or ($term == "rxvt") {
            ^sh -c $"exec ($terminal_exec) -e ($command)" | complete
        } else {
            ^$terminal_exec -e $command | complete
        }
        if ($result.exit_code) == 0 {
            exit_success
        }
        exit_failure_operation_failed
    }
    exit_failure_operation_impossible $"configured terminal program '($term)' not found or not executable"
}

# Open terminal on LXDE
def --env terminal_lxde [command: string] {
    if (which lxterminal | is-not-empty) {
        let result = if ($command | is-empty) {
            ^lxterminal | complete
        } else {
            ^lxterminal -e $command | complete
        }
        if ($result.exit_code) == 0 {
            exit_success
        }
    }
    terminal_generic $command
}

# Open terminal on LXQt
def --env terminal_lxqt [command: string] {
    if (which qterminal | is-not-empty) {
        let result = if ($command | is-empty) {
            ^qterminal | complete
        } else {
            ^qterminal -e $command | complete
        }
        if ($result.exit_code) == 0 {
            exit_success
        }
    }
    terminal_generic $command
}

# Open terminal on Enlightenment
def --env terminal_enlightenment [command: string] {
    if (which terminology | is-not-empty) {
        let result = if ($command | is-empty) {
            ^terminology | complete
        } else {
            ^terminology -e $command | complete
        }
        if ($result.exit_code) == 0 {
            exit_success
        }
    }
    terminal_generic $command
}

# Main entry point
def main [...args] {
    mut command = ""

    mut args = $args
    while not ($args | is-empty) {
        let parm = ($args | get 0)
        let args = ($args | skip 1)

        if ($parm | str starts-with "-") {
            exit_failure_syntax $"unexpected option '($parm)'"
        } else if not ($command | is-empty) {
            exit_failure_syntax $"unexpected argument '($parm)'"
        } else {
            $command = $parm
        }
    }

    detectDE
    if ($env.DE? == null) or ($env.DE | is-empty) {
        $env.DE = "generic"
    }

    match $env.DE {
        "kde" => { terminal_kde $command }
        "gnome" => { terminal_gnome $command }
        "gnome3" => { terminal_gsettings "org.gnome.desktop.default-applications.terminal" $command }
        "budgie" => { terminal_gsettings "org.gnome.desktop.default-applications.terminal" $command }
        "cinnamon" => { terminal_gsettings "org.cinnamon.desktop.default-applications.terminal" $command }
        "mate" => { terminal_gsettings "org.mate.applications-terminal" $command }
        "xfce" => { terminal_xfce $command }
        "lxde" => { terminal_lxde $command }
        "lxqt" => { terminal_lxqt $command }
        "enlightenment" => { terminal_enlightenment $command }
        "generic" => { terminal_generic $command }
    }

    exit_failure_operation_impossible "no terminal emulator available"
}
