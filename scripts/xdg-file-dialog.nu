#!/usr/bin/env nu
# xdg-file-dialog - File selection dialogs

use xdg-utils-common.nu *

# Open on KDE
def --env open_kde [filename: string] {
    let dialog = (which kdialog | get 0?.path | default "")
    if not ($dialog | is-empty) {
        let title = ($env.TITLE? | default "")
        let result = if not ($title | is-empty) {
            ^$dialog --title $title --getopenfilename $filename "" | complete
        } else {
            ^$dialog --getopenfilename $filename "" | complete
        }
        if ($result.exit_code) == 0 {
            exit_success
        }
        exit_failure_operation_failed
    }
    exit_failure_operation_impossible
}

# Open on Zenity
def --env open_zenity [filename: string] {
    let dialog = (which zenity | get 0?.path | default "")
    if not ($dialog | is-empty) {
        let title = ($env.TITLE? | default "")
        let filename_arg = if not ($filename | is-empty) {
            [$"--filename=($filename)"]
        } else {
            []
        }

        if not ($filename_arg | is-empty) {
            let result = if not ($title | is-empty) {
                ^$dialog --title $title --file-selection ...$filename_arg | complete
            } else {
                ^$dialog --file-selection ...$filename_arg | complete
            }
            if ($result.exit_code) == 0 {
                exit_success
            }
            exit_failure_operation_failed
        } else {
            let result = if not ($title | is-empty) {
                ^$dialog --title $title --file-selection | complete
            } else {
                ^$dialog --file-selection | complete
            }
            if ($result.exit_code) == 0 {
                exit_success
            }
            exit_failure_operation_failed
        }
    }
    exit_failure_operation_impossible
}

# Open multiple files on KDE
def --env open_multi_kde [filename: string] {
    let dialog = (which kdialog | get 0?.path | default "")
    if not ($dialog | is-empty) {
        let title = ($env.TITLE? | default "")
        let result = if not ($title | is-empty) {
            ^$dialog --title $title --multiple --separate-output --getopenfilename $filename "" | complete
        } else {
            ^$dialog --multiple --separate-output --getopenfilename $filename "" | complete
        }
        if ($result.exit_code) == 0 {
            exit_success
        }
        exit_failure_operation_failed
    }
    exit_failure_operation_impossible
}

# Open multiple files on Zenity
def --env open_multi_zenity [filename: string] {
    let dialog = (which zenity | get 0?.path | default "")
    if not ($dialog | is-empty) {
        let title = ($env.TITLE? | default "")
        let filename_arg = if not ($filename | is-empty) {
            [$"--filename=($filename)"]
        } else {
            []
        }

        if not ($filename_arg | is-empty) {
            let result = if not ($title | is-empty) {
                ^$dialog --title $title --multiple --file-selection ...$filename_arg | complete
            } else {
                ^$dialog --multiple --file-selection ...$filename_arg | complete
            }
            if ($result.exit_code) == 0 {
                print (($result.stdout) | str replace --all "|" "\n")
                exit_success
            }
            exit_failure_operation_failed
        } else {
            let result = if not ($title | is-empty) {
                ^$dialog --title $title --multiple --file-selection | complete
            } else {
                ^$dialog --multiple --file-selection | complete
            }
            if ($result.exit_code) == 0 {
                print (($result.stdout) | str replace --all "|" "\n")
                exit_success
            }
            exit_failure_operation_failed
        }
    }
    exit_failure_operation_impossible
}

# Save on KDE
def --env save_kde [filename: string] {
    let dialog = (which kdialog | get 0?.path | default "")
    if not ($dialog | is-empty) {
        let title = ($env.TITLE? | default "")
        let result = if not ($title | is-empty) {
            ^$dialog --title $title --getsavefilename $filename "" | complete
        } else {
            ^$dialog --getsavefilename $filename "" | complete
        }
        if ($result.exit_code) == 0 {
            exit_success
        }
        exit_failure_operation_failed
    }
    exit_failure_operation_impossible
}

# Save on Zenity
def --env save_zenity [filename: string] {
    let dialog = (which zenity | get 0?.path | default "")
    if not ($dialog | is-empty) {
        let title = ($env.TITLE? | default "")
        let filename_arg = if not ($filename | is-empty) {
            [$"--filename=($filename)"]
        } else {
            []
        }

        if not ($filename_arg | is-empty) {
            let result = if not ($title | is-empty) {
                ^$dialog --title $title --save --file-selection ...$filename_arg | complete
            } else {
                ^$dialog --save --file-selection ...$filename_arg | complete
            }
            if ($result.exit_code) == 0 {
                exit_success
            }
            exit_failure_operation_failed
        } else {
            let result = if not ($title | is-empty) {
                ^$dialog --title $title --save --file-selection | complete
            } else {
                ^$dialog --save --file-selection | complete
            }
            if ($result.exit_code) == 0 {
                exit_success
            }
            exit_failure_operation_failed
        }
    }
    exit_failure_operation_impossible
}

# Directory on KDE
def --env directory_kde [filename: string] {
    let dialog = (which kdialog | get 0?.path | default "")
    if not ($dialog | is-empty) {
        let title = ($env.TITLE? | default "")
        let result = if not ($title | is-empty) {
            ^$dialog --title $title --getexistingdirectory $filename "" | complete
        } else {
            ^$dialog --getexistingdirectory $filename "" | complete
        }
        if ($result.exit_code) == 0 {
            exit_success
        }
        exit_failure_operation_failed
    }
    exit_failure_operation_impossible
}

# Directory on Zenity
def --env directory_zenity [filename: string] {
    let dialog = (which zenity | get 0?.path | default "")
    if not ($dialog | is-empty) {
        let title = ($env.TITLE? | default "")
        let filename_arg = if not ($filename | is-empty) {
            [$"--filename=($filename)/"]
        } else {
            []
        }

        let result = if not ($title | is-empty) {
            ^$dialog --title $title --directory --file-selection ...$filename_arg | complete
        } else {
            ^$dialog --directory --file-selection ...$filename_arg | complete
        }

        if ($result.exit_code) == 0 {
            exit_success
        }
        exit_failure_operation_failed
    }
    exit_failure_operation_impossible
}

# Main entry point
def main [...args] {
    if ($args | is-empty) {
        exit_failure_syntax
    }

    mut action = ""
    mut filename = ""

    let cmd = ($args | get 0)
    let rest = ($args | skip 1)

    match $cmd {
        "openfilename" => { $action = "openfilename" }
        "openfilenamelist" => { $action = "openfilenamelist" }
        "savefilename" => { $action = "savefilename" }
        "directory" => { $action = "directory" }
    }

    mut i_args = $rest
    while not ($i_args | is-empty) {
        let parm = ($i_args | get 0)
        $i_args = ($i_args | skip 1)

        match $parm {
            "--title" => {
                if ($i_args | is-empty) {
                    exit_failure_syntax "TITLE argument missing for --title"
                }
                $env.TITLE = ($i_args | get 0)
                $i_args = ($i_args | skip 1)
            }
            _ => {
                # Positional argument: filename
                if ($filename | is-empty) {
                    $filename = $parm
                }
            }
        }
    }

    # Shouldn't happen
    if ($action | is-empty) {
        exit_failure_syntax "command argument missing"
    }

    detectDE

    match $action {
        "openfilename" => {
            match ($env.DE? | default "") {
                "kde" => { open_kde $filename }
                "gnome" => { open_zenity $filename }
                "cinnamon" => { open_zenity $filename }
                "lxde" => { open_zenity $filename }
                "lxqt" => { open_zenity $filename }
                "mate" => { open_zenity $filename }
                "xfce" => { open_zenity $filename }
                "budgie" => {
                    if ($env.BUDGIE_SESSION_VERSION? | default "" | str starts-with "10.9") {
                        open_zenity $filename
                    } else {
                        exit_failure_operation_impossible $"xdg-file-dialog is unsupported for Budgie ($env.BUDGIE_SESSION_VERSION? | default '')"
                    }
                }
            }
            exit_failure_operation_impossible "no method available for opening a filename dialog"
        }
        "openfilenamelist" => {
            match ($env.DE? | default "") {
                "kde" => { open_multi_kde $filename }
                "gnome" => { open_multi_zenity $filename }
                "cinnamon" => { open_multi_zenity $filename }
                "lxde" => { open_multi_zenity $filename }
                "lxqt" => { open_multi_zenity $filename }
                "mate" => { open_multi_zenity $filename }
                "xfce" => { open_multi_zenity $filename }
                "budgie" => {
                    if ($env.BUDGIE_SESSION_VERSION? | default "" | str starts-with "10.9") {
                        open_multi_zenity $filename
                    } else {
                        exit_failure_operation_impossible $"xdg-file-dialog is unsupported for Budgie ($env.BUDGIE_SESSION_VERSION? | default '')"
                    }
                }
            }
            exit_failure_operation_impossible "no method available for opening a filename dialog"
        }
        "savefilename" => {
            match ($env.DE? | default "") {
                "kde" => { save_kde $filename }
                "gnome" => { save_zenity $filename }
                "cinnamon" => { save_zenity $filename }
                "lxde" => { save_zenity $filename }
                "lxqt" => { save_zenity $filename }
                "mate" => { save_zenity $filename }
                "xfce" => { save_zenity $filename }
                "budgie" => {
                    if ($env.BUDGIE_SESSION_VERSION? | default "" | str starts-with "10.9") {
                        save_zenity $filename
                    } else {
                        exit_failure_operation_impossible $"xdg-file-dialog is unsupported for Budgie ($env.BUDGIE_SESSION_VERSION? | default '')"
                    }
                }
            }
            exit_failure_operation_impossible "no method available for opening a filename dialog"
        }
        "directory" => {
            match ($env.DE? | default "") {
                "kde" => { directory_kde $filename }
                "gnome" => { directory_zenity $filename }
                "cinnamon" => { directory_zenity $filename }
                "lxde" => { directory_zenity $filename }
                "lxqt" => { directory_zenity $filename }
                "mate" => { directory_zenity $filename }
                "xfce" => { directory_zenity $filename }
                "budgie" => {
                    if ($env.BUDGIE_SESSION_VERSION? | default "" | str starts-with "10.9") {
                        directory_zenity $filename
                    } else {
                        exit_failure_operation_impossible $"xdg-file-dialog is unsupported for Budgie ($env.BUDGIE_SESSION_VERSION? | default '')"
                    }
                }
            }
            exit_failure_operation_impossible "no method available for opening a directory dialog"
        }
    }
}
