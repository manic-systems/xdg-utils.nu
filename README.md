# xdg-utils

```txt
The xdg-utils package is a set of scripts that provide basic desktop integration
functions for any Free Desktop on Linux, the BSDs and even partially on MacOS
and WSL.

They are intended to provide a set of defacto standards. This means that:

- Third party software developers can rely on these xdg-utils for all of their
  simple integration needs.

- Developers of desktop environments can make sure that their environments are
  well supported

  If a desktop developer wants to be certain that their environment functions
  with all third party software, then can simply make sure that these utilities
  work properly in their environment.

  This will hopefully mean that 'third tier' window managers such as XFCE and
  Blackbox can reach full parity with Gnome and KDE in terms of third party ISV
  support.

- Distribution vendors can provide custom versions of these utilities

  If a distribution vendor wishes to have unusual systems, they can provide
  custom scripts, and the third party software should still continue to work.
```

## Motivation

xdg-utils is part of the basic glue that makes desktop applications work across
Linux environments, but its current implementation is difficult to reason about,
test, and extend. The project is largely written as portable shell, which has
helped it survive across many systems, but that portability comes at the cost of
fragile control flow, inconsistent data handling, implicit string parsing, and
behavior that is hard to validate automatically. A rewrite in Nushell would make
the codebase more structured without abandoning the role of xdg-utils as a
lightweight command-line compatibility layer. Nushell's typed values, tables,
records, explicit error handling, and pipeline semantics are a good fit for
utilities that spend most of their time detecting environments, dispatching to
backends, parsing configuration, and handling command output. These are exactly
the places where traditional shell tends to accumulate subtle bugs.

The goal of this project is **not** to make xdg-utils more complex, like a Rust
rewrite would. The goal itself is to make its existing complexity _visible and
manageable_. The Nushell implementation can cleanly separate desktop-environment
detection, MIME lookup, browser launching, portal integration, and fallback
behavior into clearer units with testable inputs and outputs. This would make it
easier to preserve compatibility while improving correctness. Nushell offers a
cleaner foundation for describing that logic directly, rather than encoding it
through layers of string manipulation and process side effects.

Last but not least, Nushell makes xdg-utils more approachable. Indeed,
contributors should be able to understand why a command chose a backend, what
data it inspected, and how a fallback was reached. Making those decisions
explicit would reduce regressions, improve diagnostics, and give downstream
distributions a more reliable base to patch, test, and package. Thus, we port
xdg-utils to **Nushell** to modernize the project around today’s Linux desktop
stack. xdg-utils now has to coexist with Flatpak, portals, Wayland sessions,
containerized applications, nontraditional desktop environments, and
increasingly declarative systems such as NixOS. These environments expose
weaknesses in ad hoc shell logic.

## Caveats

This project is a compatibility-oriented rewrite, not a redesign of the
xdg-utils interface itself. Existing behavior, edge cases, and historical quirks
may need to be preserved even when they appear inelegant. Correctness and
compatibility take priority over aesthetic cleanup. The choice of Nushell,
however, is deliberate. This project does not attempt to compete with low-level
systems languages on raw performance, startup latency, or static distribution
simplicity. xdg-utils spends most of its time orchestrating other programs,
inspecting environment state, parsing desktop metadata, and selecting backends.
These are workflow and dataflow problems, not compute-heavy ones.

Portability also has practical limits. The original xdg-utils achieved broad
compatibility partly by targeting the lowest common denominator of POSIX shell
behavior. Nushell introduces a stronger runtime dependency and may not be
available in extremely minimal environments. This tradeoff is accepted in
exchange for improved maintainability, clearer semantics, and more reliable
behavior.

Finally, this project does not assume that desktop integration on Linux is fully
standardized or internally consistent. Different desktop environments, portal
implementations, distributions, and container systems continue to expose
different assumptions and behaviors. Some complexity in xdg-utils is therefore
structural rather than accidental, and no rewrite can eliminate that entirely.
We'll be damned if we don't try, though.
