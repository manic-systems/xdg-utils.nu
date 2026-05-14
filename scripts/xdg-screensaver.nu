#!/usr/bin/env nu
# xdg-screensaver - Control screensaver

use xdg-utils-common.nu *

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

# Suspend loop for screen savers that need periodic refresh
def screensaver_suspend_loop [screensaver_file: string, ...cmd_args: string] {
    let mv_cmd = get_mv_cmd
    do_lockfile $screensaver_file
    let tmpfile = (^mktemp | complete | get stdout | str trim)
    ^awk '
BEGIN { FS=":" }
/^[0-9a-f]+:[0-9]+$/ {
    wid=$1; pid=$2
    if (system("ps -p " pid " 2>/dev/null | grep xprop > /dev/null") == 0) {
        print wid ":" pid
    }
}
' $screensaver_file | save --force $tmpfile
    if $mv_cmd == "mv -T" {
        ^mv -T $tmpfile $screensaver_file
    } else {
        ^mv $tmpfile $screensaver_file
    }
    if ($screensaver_file | path type) == "file" {
        let filesize = (try { ^stat -c%s $screensaver_file | complete | get stdout | str trim | into int } catch { -1 })
        if $filesize > 0 {
            do_unlockfile $screensaver_file
            return
        }
    }
    do_unlockfile $screensaver_file
    # Detach a poll loop that keeps re-running the keep-alive command while the
    # marker file exists. We feed both values to the shell as positional args.
    ^sh -c 'sf="$1"; shift; while [ -f "$sf" ]; do "$@" 2>/dev/null; sleep 50; done &' -- $screensaver_file ...$cmd_args
}

# DBus process for freedesktop/gnome screensaver suspend (runs in background)
def screensaver_dbus_process [window_id: string, screensaver_file: string, dbus_service: string, dbus_path: string] {
    let perl_script = '
use strict;
use warnings;
use Encode qw(decode);
use IO::File;
use Net::DBus;
use X11::Protocol;

my ($window_id, $screensaver_file, $dbus_service, $dbus_path) = @ARGV;

my $x = X11::Protocol->new();
my $named_window_id = hex($window_id);
my $window_name;
while (1) {
  eval { ($window_name) = $x->GetProperty($named_window_id, $x->atom("WM_NAME"),
                                   $x->atom("STRING"), 0, 1000, 0); };
  $window_name = "?" if $@;
  last if defined($window_name) && $window_name ne "";
  (undef, $named_window_id) = $x->QueryTree($named_window_id);
  if (!defined($named_window_id)) {
    $window_name = "?";
    last;
  }
}

$window_name = decode("utf8", $window_name, Encode::FB_DEFAULT);

my $bus = Net::DBus->session();
my $sm_svc = $bus->get_service($dbus_service);
my $sm = $sm_svc->get_object($dbus_path, $dbus_service);
if ($dbus_service eq "org.gnome.SessionManager") {
  $sm->Inhibit($window_name, hex($window_id), $window_name, 8);
} elsif ($dbus_service eq "org.freedesktop.ScreenSaver") {
  $sm->Inhibit($window_name, $window_name);
} else {
  print STDERR "ERROR: internal error, unknown D-Bus service $dbus_service\n";
  exit 1;
}

while (1) {
  sleep(10);
  my $status = new IO::File($screensaver_file, "r")
    or exit 0;
  my $found;
  while (<$status>) {
    if (/^$window_id:/) {
      $found = 1;
      last;
    }
  }
  exit 0 unless $found;
}
'
    # Script and identifiers come in as positional args, never interpolated.
    ^sh -c 'perl -e "$1" "$2" "$3" "$4" "$5" </dev/null >/dev/null 2>&1 &' -- $perl_script $window_id $screensaver_file $dbus_service $dbus_path
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

# Cleanup on suspend
def --env cleanup_suspend [window_id: string, screensaver_file: string] {
    let mv_cmd = get_mv_cmd
    do_lockfile $screensaver_file
    let tmpfile = (^mktemp | complete | get stdout | str trim)
    let xprop_pid = (^grep $"($window_id):" $screensaver_file | complete | get stdout | str trim | split row ":" | get 1? | default "")
    ^grep -v $"($window_id):($xprop_pid)" $screensaver_file | save --force $tmpfile
    if $mv_cmd == "mv -T" { ^mv -T $tmpfile $screensaver_file } else { ^mv $tmpfile $screensaver_file }
    let filesize = (try { ^stat -c%s $screensaver_file | complete | get stdout | str trim | into int } catch { 1 })
    if ($screensaver_file | path type) == "file" and $filesize == 0 {
        rm --force $screensaver_file
        do_unlockfile $screensaver_file
        perform_action "resume" $screensaver_file
    } else {
        do_unlockfile $screensaver_file
    }
}

# Resume
def --env do_resume [window_id: string, screensaver_file: string] {
    do_lockfile $screensaver_file
    let xprop_pid = (^grep $"($window_id):" $screensaver_file | complete | get stdout | str trim | split row ":" | get 1? | default "")
    do_unlockfile $screensaver_file
    if not ($xprop_pid | is-empty) {
        if (^ps -p $xprop_pid | complete | get stdout | ^grep -F xprop | complete).exit_code == 0 {
            ^kill -s TERM $xprop_pid | complete | ignore
        }
    }
    cleanup_suspend $window_id $screensaver_file
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

# Track window
def --env track_window [window_id: string, screensaver_file: string] {
    let xprop = (which xprop | get 0?.path | default "")
    if ($xprop | is-empty) { return }
    let mv_cmd = get_mv_cmd

    do_lockfile $screensaver_file
    let tmpfile = (^mktemp | complete | get stdout | str trim)
    let track_result = (^awk $"-v target=($window_id)" '
BEGIN { already_tracked=1; FS=":" }
{
    wid=$1; pid=$2
    if (system("ps -p " pid " 2>/dev/null | grep xprop > /dev/null") == 0) {
        print wid ":" pid
        if (wid == target) already_tracked=0
    }
}
END { exit already_tracked }
' $screensaver_file | save --force $tmpfile; ^mv $tmpfile $screensaver_file | complete)

    if $track_result.exit_code == 0 {
        do_unlockfile $screensaver_file
        return
    }

    # Spawn xprop in the background through sh so we can capture its PID,
    # passing the values through positional args.
    let xprop_pid = (^sh -c '"$1" -id "$2" -spy </dev/null >/dev/null 2>&1 & echo $!' -- $xprop $window_id | complete | get stdout | str trim)
    $"($window_id):($xprop_pid)\n" | save --append $tmpfile
    if $mv_cmd == "mv -T" { ^mv -T $tmpfile $screensaver_file } else { ^mv $tmpfile $screensaver_file }
    do_unlockfile $screensaver_file
    # `wait` only works on the parent shell's children, and ours is already gone,
    # so poll the PID directly.
    while (^kill -0 $xprop_pid o+e>| complete | get exit_code) == 0 {
        sleep 1sec
    }
    cleanup_suspend $window_id $screensaver_file
}

# Freedesktop screensaver — returns exit code int
def --env screensaver_freedesktop [action: string, window_id: string, screensaver_file: string]: nothing -> int {
    match $action {
        "suspend" => { screensaver_dbus_process $window_id $screensaver_file "org.freedesktop.ScreenSaver" "/ScreenSaver"; 0 }
        "resume" => { 0 }
        "activate" => { (^dbus-send --session --dest=org.freedesktop.ScreenSaver --type=method_call /ScreenSaver org.freedesktop.ScreenSaver.SetActive boolean:true | complete).exit_code }
        "lock" => { (^dbus-send --session --dest=org.freedesktop.ScreenSaver --type=method_call /ScreenSaver org.freedesktop.ScreenSaver.Lock | complete).exit_code }
        "reset" => { (^dbus-send --session --dest=org.freedesktop.ScreenSaver --type=method_call /ScreenSaver org.freedesktop.ScreenSaver.SimulateUserActivity | complete).exit_code }
        "status" => {
            let raw = (^dbus-send --session --dest=org.freedesktop.ScreenSaver --type=method_call --print-reply --reply-timeout=2000 /ScreenSaver org.freedesktop.ScreenSaver.GetActive | complete)
            let status = ($raw.stdout | ^grep -F "boolean" | complete | get stdout | split row " " | get 4? | default "")
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

# GNOME screensaver — returns exit code int
def --env screensaver_gnome_screensaver [action: string, window_id: string, screensaver_file: string]: nothing -> int {
    # DBUS interface for gnome-screensaver
    # https://gitlab.gnome.org/Archive/gnome-screensaver/-/blob/master/doc/dbus-interface.xml
    # as well as gnome-shell
    # https://gitlab.gnome.org/GNOME/gnome-shell/-/blob/main/data/dbus-interfaces/org.gnome.ScreenSaver.xml
    # Documentation:
    # https://gnome.pages.gitlab.gnome.org/gnome-session/re04.html
    match $action {
        "suspend" => { screensaver_dbus_process $window_id $screensaver_file "org.gnome.SessionManager" "/org/gnome/SessionManager"; 0 }
        "resume" => { 0 }
        "activate" => { (^dbus-send --session --dest=org.gnome.ScreenSaver --type=method_call /org/gnome/ScreenSaver org.gnome.ScreenSaver.SetActive boolean:true | complete).exit_code }
        "lock" => { (^dbus-send --session --dest=org.gnome.ScreenSaver --type=method_call /org/gnome/ScreenSaver org.gnome.ScreenSaver.Lock | complete).exit_code }
        "reset" => { (^dbus-send --session --dest=org.gnome.ScreenSaver --type=method_call /org/gnome/ScreenSaver org.gnome.ScreenSaver.SetActive boolean:false | complete).exit_code }
        "status" => {
            let raw = (^dbus-send --session --dest=org.gnome.ScreenSaver --type=method_call --print-reply --reply-timeout=2000 /org/gnome/ScreenSaver org.gnome.ScreenSaver.GetActive | complete)
            let status = ($raw.stdout | ^grep -F "boolean" | complete | get stdout | split row " " | get 4? | default "")
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

# MATE screensaver — returns exit code int
def --env screensaver_mate_screensaver [action: string, window_id: string, screensaver_file: string]: nothing -> int {
    # DBUS interface for mate-screensaver
    # This is same as gnome's for now but may change in the future as MATE
    # does not follow gnome's development necessarily.
    match $action {
        "suspend" => { screensaver_suspend_loop $screensaver_file "dbus-send" "--session" "--dest=org.mate.ScreenSaver" "--type=method_call" "/org/mate/ScreenSaver" "org.mate.ScreenSaver.SimulateUserActivity"; 0 }
        "resume" => { 0 }
        "activate" => { (^dbus-send --session --dest=org.mate.ScreenSaver --type=method_call /org/mate/ScreenSaver org.mate.ScreenSaver.SetActive boolean:true | complete).exit_code }
        "lock" => { (^mate-screensaver-command --lock | complete).exit_code }
        "reset" => { (^dbus-send --session --dest=org.mate.ScreenSaver --type=method_call /org/mate/ScreenSaver org.mate.ScreenSaver.SimulateUserActivity | complete).exit_code }
        "status" => {
            let raw = (^dbus-send --session --dest=org.mate.ScreenSaver --type=method_call --print-reply --reply-timeout=2000 /org/mate/ScreenSaver org.mate.ScreenSaver.GetActive | complete)
            let status = ($raw.stdout | ^grep -F "boolean" | complete | get stdout | split row " " | get 4? | default "")
            if $status == "true" or $status == "false" { print "enabled" } else { print "disabled" }
            $raw.exit_code
        }
        _ => { 1 }
    }
}

# Cinnamon screensaver — returns exit code int
def --env screensaver_cinnamon_screensaver [action: string, window_id: string, screensaver_file: string]: nothing -> int {
    # DBUS interface for cinnamon-screensaver
    # https://raw.githubusercontent.com/linuxmint/cinnamon-screensaver/master/doc/dbus-interface.html
    match $action {
        "suspend" => { screensaver_suspend_loop $screensaver_file "dbus-send" "--session" "--dest=org.cinnamon.ScreenSaver" "--type=method_call" "/org/cinnamon/ScreenSaver" "org.cinnamon.ScreenSaver.SimulateUserActivity"; 0 }
        "resume" => { 0 }
        "activate" => { (^dbus-send --session --dest=org.cinnamon.ScreenSaver --type=method_call /org/cinnamon/ScreenSaver org.cinnamon.ScreenSaver.SetActive boolean:true | complete).exit_code }
        "lock" => { (^dbus-send --session --dest=org.cinnamon.ScreenSaver --type=method_call /org/cinnamon/ScreenSaver org.cinnamon.ScreenSaver.Lock string:"" | complete).exit_code }
        "reset" => { (^dbus-send --session --dest=org.cinnamon.ScreenSaver --type=method_call /org/cinnamon/ScreenSaver org.cinnamon.ScreenSaver.SimulateUserActivity | complete).exit_code }
        "status" => {
            let raw = (^dbus-send --session --dest=org.cinnamon.ScreenSaver --type=method_call --print-reply --reply-timeout=2000 /org/cinnamon/ScreenSaver org.cinnamon.ScreenSaver.GetActive | complete)
            let status = ($raw.stdout | ^grep -F "boolean" | complete | get stdout | split row " " | get 4? | default "")
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

# XScreenSaver — returns exit code int
def --env screensaver_xscreensaver [action: string, screensaver_file: string]: nothing -> int {
    match $action {
        "suspend" => { screensaver_suspend_loop $screensaver_file "xscreensaver-command" "-deactivate"; 0 }
        "resume" => { 0 }
        "activate" => { (^xscreensaver-command -activate | complete).exit_code }
        "lock" => { (^xscreensaver-command -lock | complete).exit_code }
        "reset" => { (^xscreensaver-command -deactivate | complete).exit_code }
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

    # The suspend branch re-enters here as a detached process to run the xprop tracker
    if $cmd == "__track-window" {
        if ($rest | length) < 2 {
            exit 1
        }
        track_window (($rest | get 0) | into string) (($rest | get 1) | into string)
        exit 0
    }

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
    let has_dbus_send = (which dbus-send | is-not-empty)
    let dbus_owner_exists = {|name|
        (^dbus-send --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.GetNameOwner $"string:($name)" | complete).exit_code == 0
    }

    # Consider "xscreensaver" a separate DE
    if (which xscreensaver-command | is-not-empty) and (^xscreensaver-command -version | complete | get stdout | str contains "XScreenSaver") {
        $env.DE = "xscreensaver"
    }
    # Consider "freedesktop-screensaver" a separate DE
    if $has_dbus_send and (do $dbus_owner_exists "org.freedesktop.ScreenSaver") {
        $env.DE = "freedesktop_screensaver"
    }
    # Consider "gnome-screensaver" a separate DE
    if $has_dbus_send and (do $dbus_owner_exists "org.gnome.ScreenSaver") {
        $env.DE = "gnome_screensaver"
    }
    # Consider "mate-screensaver" a separate DE
    if $has_dbus_send and (do $dbus_owner_exists "org.mate.ScreenSaver") {
        $env.DE = "mate_screensaver"
    }
    # Consider "cinnamon-screensaver" a separate DE
    if $has_dbus_send and (do $dbus_owner_exists "org.cinnamon.ScreenSaver") {
        $env.DE = "cinnamon"
    }
    # Consider "xautolock" a separate DE, and probe with `which` rather than `xautolock -enable`,
    # which would otherwise enable the autolocker as a side effect just by detecting it.
    if (which xautolock | is-not-empty) {
        $env.DE = "xautolock_screensaver"
    }
    # Consider "xss-lock" a separate DE
    if (which xss-lock | is-not-empty) and (which ps | is-not-empty) {
        let xdg_sid = ($env.XDG_SESSION_ID? | default "")
        let ps_out = (^ps x -o cmd | complete | get stdout)
        let xss_lines = ($ps_out | lines | where { $in | str starts-with "xss-lock" })
        let matches = ($xss_lines | where {|l| ($l | str contains $"-s ($xdg_sid)") or ($l | str contains $"--session=($xdg_sid)") })
        if not ($matches | is-empty) {
            $env.DE = "xss-lock_screensaver"
        }
    }

    if $action == "resume" {
        do_resume $window_id $screensaver_file
        exit_success
    }

    let de = ($env.DE? | default "")
    let result = match $de {
        "kde" => {
            if not ($env.KDE_SESSION_VERSION? == null) {
                screensaver_freedesktop $action $window_id $screensaver_file
            } else {
                screensaver_kde3 $action
            }
        }
        "freedesktop_screensaver" => { screensaver_freedesktop $action $window_id $screensaver_file }
        "gnome3" => { screensaver_freedesktop $action $window_id $screensaver_file }
        "gnome_screensaver" => { screensaver_gnome_screensaver $action $window_id $screensaver_file }
        "mate_screensaver" => { screensaver_mate_screensaver $action $window_id $screensaver_file }
        "cinnamon" => { screensaver_cinnamon_screensaver $action $window_id $screensaver_file }
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
                screensaver_gnome_screensaver $action $window_id $screensaver_file
            } else { 1 }
        }
        "generic" | "" => {
            if not ($env.DISPLAY? | default "" | is-empty) {
                screensaver_xserver $action $screensaver_file
            } else { 0 }
        }
        _ => { 1 }
    }

    if $action == "suspend" {
        # Re-invoke ourselves detached, passing values through sh positional
        # args so window_id and screensaver_file never enter the shell string
        ^sh -c 'setsid "$1" __track-window "$2" "$3" </dev/null >/dev/null 2>&1 &' -- (which xdg-screensaver | get 0?.path | default "xdg-screensaver") $window_id $screensaver_file | complete | ignore
    }

    # Handle DPMS on suspend
    if not ($env.DISPLAY? | default "" | is-empty) and $action == "suspend" and (which xset | is-not-empty) {
        if (^xset -q | complete | get stdout | str contains "DPMS is Enabled") {
            let tmpfile = (^mktemp | complete | get stdout | str trim)
            let mv_cmd = get_mv_cmd
            if $mv_cmd == "mv -T" { ^mv -T $tmpfile $"($screensaver_file).dpms" } else { ^mv $tmpfile $"($screensaver_file).dpms" }
            ^xset -dpms | complete | ignore
        }
    }

    if $result == 0 {
        exit_success
    }
    exit_failure_operation_failed
}
