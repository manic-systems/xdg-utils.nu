#!/usr/bin/env nu
# xdg-email - Open email client with RFC 2368 mailto: URI

use xdg-utils-common.nu *

# Run Thunderbird compose
def --env run_thunderbird [thunderbird: string, mailto: string, attach: string] {
    let mailto_clean = ($mailto | str replace --all "^mailto:" "" | str trim)

    let has_query = ($mailto_clean | str starts-with "?")

    let mailto_parsed = if $has_query {
        $mailto_clean | str replace --regex "^\\?" ""
    } else {
        $"to=($mailto_clean)" | str replace --all "?" "&"
    }

    let parts = ($mailto_parsed | split row "&")

    # Helper: extract values for a key, percent-decode, and join with comma
    let extract_and_decode = {|key|
        let values = ($parts | where {|p| $p | str starts-with $key} | each {|p| $p | str replace $"^($key)" ""})
        if ($values | is-empty) {
            ""
        } else {
            let decoded = ($values | each {|v| $v | url decode } | str join ",")
            $decoded
        }
    }

    let to = (do $extract_and_decode "to=")
    let cc = (do $extract_and_decode "cc=")
    let bcc = (do $extract_and_decode "bcc=")

    # Subject and body don't need percent-decoding for thunderbird - just extract them
    let subject = ($parts | where {|p| $p | str starts-with "subject="} | get 0? | default "" | str replace "^subject=" "")
    let body = ($parts | where {|p| $p | str starts-with "body="} | get 0? | default "" | str replace "^body=" "")

    mut newmailto = ""
    if not ($to | is-empty) {
        $newmailto = $"to='($to)'"
    }
    if not ($cc | is-empty) {
        $newmailto = $"($newmailto),cc='($cc)'"
    }
    if not ($bcc | is-empty) {
        $newmailto = $"($newmailto),bcc='($bcc)'"
    }
    if not ($subject | is-empty) {
        $newmailto = $"($newmailto),($subject)"
    }
    if not ($body | is-empty) {
        $newmailto = $"($newmailto),($body)"
    }

    $newmailto = ($newmailto | str replace --regex "^," "")

    if not ($attach | is-empty) {
        $newmailto = $"($newmailto),attachment='($attach)'"
    }

    DEBUG 1 $"Running ($thunderbird) -compose \"($newmailto)\""
    let result = (^$thunderbird -compose $newmailto | complete)
    if ($result.exit_code) == 0 {
        exit_success
    }
    exit_failure_operation_failed
}

# Open email on KDE
def --env open_kde [mailto: string, attach: string] {
    let kreadconfig = if (not ($env.KDE_SESSION_VERSION? | default "" | is-empty)) and (($env.KDE_SESSION_VERSION | into int) >= 5) {
        $"kreadconfig($env.KDE_SESSION_VERSION)"
    } else {
        "kreadconfig"
    }

    if (which $kreadconfig | is-not-empty) {
        let profile = (^$kreadconfig --file emaildefaults --group Defaults --key Profile | complete | get stdout | str trim)
        if not ($profile | is-empty) {
            let client = (^$kreadconfig --file emaildefaults --group $"PROFILE_($profile)" --key EmailClient | complete | get stdout | split row " " | get 0?)
            if not ($client | default "" | is-empty) and ($client | str ends-with ".desktop") {
                if (which $client | is-empty) {
                    let client = (desktop_file_to_binary $client)
                }
            }

            if not ($client | default "" | is-empty) and (($client | str contains "thunderbird") or ($client | str contains "icedove")) {
                run_thunderbird $client $mailto $attach
            }
        }
    }

    let kde_ver = ($env.KDE_SESSION_VERSION? | default "")
    let command = if ($kde_ver | is-empty) {
        "kmailservice"
    } else if ($kde_ver == "4") {
        "kde-open"
    } else {
        $"kde-open($kde_ver)"
    }

    let result = if (which $command | is-not-empty) {
        DEBUG 1 $"Running ($command) \"($mailto)\""
        # KDE3 uses locale's encoding when decoding the URI, so set it to UTF-8
        if $kde_ver == "3" {
            (with-env { LC_ALL: "C.UTF-8" } { ^$command $mailto } | complete)
        } else {
            (^$command $mailto | complete)
        }
    } else {
        DEBUG 1 "$command missing; trying generic mode instead."
        open_generic $mailto $attach
        return
    }

    if ($result.exit_code) == 0 {
        exit_success
    }
    exit_failure_operation_failed
}

# Open email on GNOME 3
def --env open_gnome3 [mailto: string, attach: string] {
    let desktop = (^xdg-mime query default "x-scheme-handler/mailto" | complete | get stdout | str trim)
    let client = (desktop_file_to_binary $desktop)
    if not ($client | default "" | is-empty) and (($client | str contains "thunderbird") or ($client | str contains "icedove")) {
        run_thunderbird $client $mailto $attach
    }

    let result = if (^gio help open | complete).exit_code == 0 {
        ^gio open $mailto | complete
    } else if (^gvfs-open --help | complete).exit_code == 0 {
        ^gvfs-open $mailto | complete
    } else {
        ^gnome-open $mailto | complete
    }

    if ($result.exit_code) == 0 {
        exit_success
    }
    exit_failure_operation_failed
}

# Open email on GNOME
def --env open_gnome [mailto: string, attach: string] {
    let client = (^gconftool-2 --get /desktop/gnome/url-handlers/mailto/command | complete | get stdout | split row " " | get 0?)
    if not ($client | default "" | is-empty) and (($client | str contains "thunderbird") or ($client | str contains "icedove")) {
        run_thunderbird $client $mailto $attach
    }

    let result = if (^gio help open | complete).exit_code == 0 {
        ^gio open $mailto | complete
    } else if (^gvfs-open --help | complete).exit_code == 0 {
        ^gvfs-open $mailto | complete
    } else {
        ^gnome-open $mailto | complete
    }

    if ($result.exit_code) == 0 {
        exit_success
    }
    exit_failure_operation_failed
}

# Open email on LXQt
def --env open_lxqt [mailto: string, attach: string] {
    let desktop = (^qtxdg-mat def-email-client | complete | get stdout | str trim)
    let client = (desktop_file_to_binary $desktop)
    if not ($client | default "" | is-empty) and (($client | str contains "thunderbird") or ($client | str contains "icedove")) {
        run_thunderbird $client $mailto $attach
    }

    let result = if (^qtxdg-mat open --help | complete).exit_code == 0 {
        (^qtxdg-mat open $mailto | complete)
    } else {
        exit_failure_operation_impossible $"no method available for opening '($mailto)'"
    }

    if ($result.exit_code) == 0 {
        exit_success
    }
    exit_failure_operation_failed
}

# Open email on XFCE
def --env open_xfce [mailto: string] {
    DEBUG 1 $"Running exo-open \"($mailto)\""
    let result = (^exo-open $mailto | complete)
    if ($result.exit_code) == 0 {
        exit_success
    }
    exit_failure_operation_failed
}

# Open email using MAILER env var
def --env open_envvar [mailto: string] {
    for i in ($env.MAILER | split row ":") {
        let result = (^$i $mailto | complete)
        if ($result.exit_code) == 0 {
            exit_success
        }
    }
    exit_failure_operation_failed
}

# Open email using D-Bus portal
def --env open_gdbus [mailto: string] {
    let result = (^gdbus call --session
        --dest org.freedesktop.portal.Desktop
        --object-path /org/freedesktop/portal/desktop
        --method org.freedesktop.portal.OpenURI.OpenURI
        "" $mailto {} | complete)

    if ($result.exit_code) == 0 {
        exit_success
    }
    exit_failure_operation_failed
}

# Generic email open
def --env open_generic [mailto: string, attach: string] {
    let desktop = (^xdg-mime query default "x-scheme-handler/mailto" | complete | get stdout | str trim)
    let client = (desktop_file_to_binary $desktop)
    if not ($client | default "" | is-empty) and (($client | str contains "thunderbird") or ($client | str contains "icedove")) {
        run_thunderbird $client $mailto $attach
    }

    ^xdg-open $mailto | complete
}

# URL encode string
def --env url_encode [input: string] {
    # Save original locale settings
    let orig_lang = ($env.LANG? | default "")
    let orig_lc_all = ($env.LC_ALL? | default "")

    $env.LANG = "C"
    $env.LC_ALL = "C"

    let input_str = if ($env.utf8? | default "") == "cat" {
        $input
    } else {
        ($input | ^iconv -t utf8 | complete | get stdout)
    }

    let encoded = ($input_str | ^awk '
BEGIN {
    for ( i=1; i<=255; ++i ) ord [ sprintf ("%c", i) "" ] = i + 0
    e = ""
    linenr = 1
}
{
    if ( linenr++ != 1 ) {
        e = e "%0D%0A"
    }
    for ( i=1; i<=length ($0); ++i ) {
        c = substr ($0, i, 1)
        if ( ord [c] > 127 ) {
            e = e "%" sprintf("%02X", ord [c])
        } else if ( c ~ /[@a-zA-Z0-9.\-\\\/]/ ) {
            e = e c
        } else {
            e = e "%" sprintf("%02X", ord [c])
        }
    }
}
END {
    print e
}
' | complete | get stdout | str trim)

    # Restore original locale settings
    $env.LANG = $orig_lang
    $env.LC_ALL = $orig_lc_all

    $encoded
}

# Main entry point
def main [...args] {
    if ($args | is-empty) {
        exit_failure_syntax
    }

    mut options = ""
    mut mailto = ""
    # attach is a comma seperated list of url encoded filenames
    mut attach = ""

    mut i_args = $args
    while not ($i_args | is-empty) {
        let parm = ($i_args | get 0)
        $i_args = ($i_args | skip 1)

        match $parm {
            "--utf8" => { $env.utf8 = "cat" }
            "--to" => {
                if ($i_args | is-empty) {
                    exit_failure_syntax "email address argument missing for --to"
                }
                let val = url_encode ($i_args | get 0)
                $i_args = ($i_args | skip 1)
                $options = $"($options)to=($val)&"
            }
            "--cc" => {
                if ($i_args | is-empty) {
                    exit_failure_syntax "email address argument missing for --cc"
                }
                let val = url_encode ($i_args | get 0)
                $i_args = ($i_args | skip 1)
                $options = $"($options)cc=($val)&"
            }
            "--bcc" => {
                if ($i_args | is-empty) {
                    exit_failure_syntax "email address argument missing for --bcc"
                }
                let val = url_encode ($i_args | get 0)
                $i_args = ($i_args | skip 1)
                $options = $"($options)bcc=($val)&"
            }
            "--subject" => {
                if ($i_args | is-empty) {
                    exit_failure_syntax "text argument missing for --subject option"
                }
                let val = url_encode ($i_args | get 0)
                $i_args = ($i_args | skip 1)
                $options = $"($options)subject=($val)&"
            }
            "--body" => {
                if ($i_args | is-empty) {
                    exit_failure_syntax "text argument missing for --body option"
                }
                let val = url_encode ($i_args | get 0)
                $i_args = ($i_args | skip 1)
                $options = $"($options)body=($val)&"
            }
            "--attach" => {
                if ($i_args | is-empty) {
                    exit_failure_syntax "file argument missing for --attach option"
                }
                let file = ($i_args | get 0)
                $i_args = ($i_args | skip 1)
                check_input_file $file
                let file_path = xdg_realpath $file
                if ($file_path | default "" | is-empty) or not ($file_path | path type) == "file" {
                    exit_failure_file_missing $"file '($file)' does not exist"
                }
                let val = url_encode $file_path
                $attach = if ($attach | is-empty) { $val } else { $"($attach),($val)" }
            }
            _ => {
                # Positional argument: the mailto URI
                if ($mailto | is-empty) {
                    $mailto = $parm
                }
            }
        }
    }

    if ($mailto | is-empty) {
        $mailto = "mailto:?"
    }

    # Combine mailto with options
    if not ($options | is-empty) {
        if ($mailto | str contains "?") {
            $mailto = $"($mailto)&($options)"
        } else {
            $mailto = $"($mailto)?($options)"
        }
    }

    # Remove trailing ? and &
    $mailto = ($mailto | str replace --regex "[?&]$" "")

    let script_name = "xdg-email"
    let hook_cmd = $"($script_name)-hook"
    if (which $hook_cmd | is-not-empty) {
        if ($attach | is-empty) {
            let result = (^$hook_cmd $mailto | complete)
            if ($result.exit_code) == 0 {
                exit_success
            }
            exit_failure_operation_failed
        } else {
            let result = (^$hook_cmd $mailto --attach-files $attach | complete)
            if ($result.exit_code) == 0 {
                exit_success
            }
            exit_failure_operation_failed
        }
    }

    detectDE
    if ($env.DE? | default "" | is-empty) {
        $env.DE = "generic"
    }

    if not ($env.MAILER? | default "" | is-empty) {
        $env.DE = "envvar"
    }

    match $env.DE {
        "envvar" => {
            if not ($attach | is-empty) {
                exit_failure_operation_impossible "Unable to use --attach with the MAILER environment variable"
            }
            open_envvar $mailto
        }
        "kde" => { open_kde $mailto $attach }
        "gnome" => { open_gnome $mailto $attach }
        "gnome3" => { open_gnome3 $mailto $attach }
        "cinnamon" => { open_gnome3 $mailto $attach }
        "lxde" => { open_gnome3 $mailto $attach }
        "mate" => { open_gnome3 $mailto $attach }
        "deepin" => { open_gnome3 $mailto $attach }
        "budgie" => { open_gnome3 $mailto $attach }
        "lxqt" => { open_lxqt $mailto $attach }
        "xfce" => {
            if not ($attach | is-empty) {
                exit_failure_operation_impossible "Unable to use --attach with the Xfce opener"
            }
            open_xfce $mailto
        }
        "flatpak" => {
            if not ($attach | is-empty) {
                exit_failure_operation_impossible "Unable to use --attach from inside a flatpak"
            }
            open_gdbus $mailto
        }
        "toolbx" => {
            if not ($attach | is-empty) {
                exit_failure_operation_impossible "Unable to use --attach from inside a flatpak"
            }
            open_gdbus $mailto
        }
        "generic" => { open_generic $mailto $attach }
        "enlightenment" => { open_generic $mailto $attach }
    }

    exit_failure_operation_impossible $"no method available for opening '($mailto)'"
}
