#!/usr/bin/env nu
# xdg-realpath - Canonicalize filepaths

export-env {
    $env.XDG_UTILS_ENABLE_DOUBLE_HYPEN = "y"
}

use xdg-utils-common.nu *

export def run_realpath [path: string] {
    if ($path | path exists) {
        let result = xdg_realpath $path
        if not ($result | is-empty) {
            print ($result | str trim)
        }
    } else {
        print --stderr $"xdg-realpath: ($path): No such file or directory"
        return 1
    }
    0
}

# xdg-realpath - command line tool for resolving file paths
# Synopsis: xdg-realpath path
# Synopsis: xdg-realpath { --help | --manual | --version }
def main [...args] {
    handle_standard_options "xdg-realpath" $args [
        "xdg-realpath - command line tool for resolving file paths"
        ""
        "Synopsis"
        ""
        "xdg-realpath path"
        ""
        "xdg-realpath { --help | --manual | --version }"
    ]

    if ($args | is-empty) {
        exit_failure_syntax
    }

    mut past_double_hyphen = false
    mut exit_with_missing = false

    mut iter_args = $args
    while not ($iter_args | is-empty) {
        let parm = ($iter_args | get 0)
        $iter_args = ($iter_args | skip 1)

        if $past_double_hyphen {
            let code = (run_realpath $parm)
            if $code != 0 {
                $exit_with_missing = true
            }
        } else {
            match $parm {
                "--" => { $past_double_hyphen = true }
                "--get-backend" => {
                    xdg_realpath "/" | ignore
                    print $env.XDG_UTILS_REALPATH_BACKEND
                }
                _ => {
                    let code = (run_realpath $parm)
                    if $code != 0 {
                        $exit_with_missing = true
                    }
                }
            }
        }
    }

    if $exit_with_missing {
        exit 2
    }
}
