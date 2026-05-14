#!/usr/bin/env nu
# xdg-su - Run command as alternate user (usually root)

use xdg-utils-common.nu *

# Run on KDE
def --env su_kde [user: string, cmd: string] {
    let kdesu = if $env.KDE_SESSION_VERSION == "4" {
        let path = (^kde4-config --locate kdesu --path exe | complete | get stdout | str trim)
        if ($path | is-empty) { "kdesu" } else { $path }
    } else {
        "kdesu"
    }

    if (which $kdesu | is-not-empty) {
        let result = if ($user | is-empty) {
            ^$kdesu -c $cmd | complete
        } else {
            ^$kdesu -u $user -c $cmd | complete
        }
        if ($result.exit_code) == 0 {
            exit_success
        }
    }
    su_generic $user $cmd
}

# Run on GNOME
def --env su_gnome [user: string, cmd: string] {
    let gsu = if (which gnomesu | is-not-empty) {
        "gnomesu"
    } else if (which xsu | is-not-empty) {
        "xsu"
    } else {
        ""
    }

    if not ($gsu | is-empty) {
        let result = if ($user | is-empty) {
            ^$gsu -c $cmd | complete
        } else {
            ^$gsu -u $user -c $cmd | complete
        }
        if ($result.exit_code) == 0 {
            exit_success
        }
    }
    su_generic $user $cmd
}

# Run on LXQt
def --env su_lxqt [user: string, cmd: string] {
    if (which lxqt-sudo | is-not-empty) {
        let result = if ($user | is-empty) {
            # -s option runs as su rather than sudo
            ^lxqt-sudo -s $cmd | complete
        } else {
            # lxqt-sudo does not support specifying a user
            su_generic $user $cmd
        }
        if ($result.exit_code) == 0 {
            exit_success
        }
    }
    su_generic $user $cmd
}

# Run on Enlightenment
def --env su_enlightenment [user: string, cmd: string] {
    # Enlightenment doesn't have any reasonably working su/sudo graphical interface
    # but terminology works as a drop in replacement for xterm and has a matching theme
    if (which terminology | is-not-empty) {
        let result = if ($user | is-empty) {
            ^terminology -g 60x5 -T $"xdg-su: ($cmd)" -e $"su -c '($cmd)'" | complete
        } else {
            ^terminology -g 60x5 -T $"xdg-su: ($cmd)" -e $"su -c '($cmd)' '($user)'" | complete
        }
        if ($result.exit_code) == 0 {
            exit_success
        }
    }
    su_generic $user $cmd
}

# Generic su fallback
def --env su_generic [user: string, cmd: string] {
    let result = if ($user | is-empty) {
        ^xterm -geom 60x5 -T $"xdg-su: ($cmd)" -e $"su -c '($cmd)'" | complete
    } else {
        ^xterm -geom 60x5 -T $"xdg-su: ($cmd)" -e $"su -c '($cmd)' '($user)'" | complete
    }
    if ($result.exit_code) == 0 {
        exit_success
    }
    exit_failure_operation_failed
}

# Run on XFCE
def --env su_xfce [user: string, cmd: string] {
    if (which gnomesu | is-not-empty) {
        su_gnome $user $cmd
    } else {
        su_generic $user $cmd
    }
}

# Main entry point
def main [...args] {
    if ($args | is-empty) {
        exit_failure_syntax
    }

    mut user = ""
    mut cmd = ""

    mut args = $args
    while not ($args | is-empty) {
        let parm = ($args | get 0)
        let args = ($args | skip 1)

        match $parm {
            "-u" => {
                if ($args | is-empty) {
                    exit_failure_syntax "user argument missing for -u"
                }
                $user = ($args | get 0)
                let args = ($args | skip 1)
            }
            "-c" => {
                if ($args | is-empty) {
                    exit_failure_syntax "command argument missing for -c"
                }
                $cmd = ($args | get 0)
                let args = ($args | skip 1)
            }
        }
    }

    if ($cmd | is-empty) {
        exit_failure_syntax "command missing"
    }

    detectDE
    if ($env.DE | is-empty) {
        if (which xterm | is-not-empty) {
            $env.DE = "generic"
        }
    }

    match $env.DE {
        "kde" => { su_kde $user $cmd }
        "gnome" => { su_gnome $user $cmd }
        "cinnamon" => { su_gnome $user $cmd }
        "lxde" => { su_gnome $user $cmd }
        "mate" => { su_gnome $user $cmd }
        "deepin" => { su_gnome $user $cmd }
        "budgie" => { su_gnome $user $cmd }
        "generic" => { su_generic $user $cmd }
        "xfce" => { su_xfce $user $cmd }
        "lxqt" => { su_lxqt $user $cmd }
        "enlightenment" => { su_enlightenment $user $cmd }
    }

    if ($user | is-empty) {
        $user = "root"
    }
    exit_failure_operation_impossible $"no graphical method available for invoking '($cmd)' as '($user)'"
}
