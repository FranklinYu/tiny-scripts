# tested executable scripts

[![Ruby](https://github.com/FranklinYu/tiny-scripts/actions/workflows/rspec.yaml/badge.svg)](https://github.com/FranklinYu/tiny-scripts/actions/workflows/rspec.yaml)

This repository contains scripts that can be black-box tested.

## user-tmpfiles

`libexec/user-tmpfiles [CONFIG_DIRECTORY]` creates user directories from configuration files.
The default configuration directory is `~/.config/user-tmpfiles.d`.
It reads top-level `*.conf` files in filename order.
An empty configuration directory succeeds.
A missing directory is an error.

```text
d$ %h/.cache/myapp 0700
d$ /tmp/myapp-%u 0700
d "%h/Library/Application Support/myapp" 0700 - - - -
```

Supported types are `d` and `d$`; `$` is ignored.
Paths must be absolute after expanding `%h` (home directory), `%u` (account name), and `%%` (literal `%`).
Single or double quotes may surround the entire path.
Modes are three or four octal digits, defaulting to `0755` when omitted or `-`.
User, group, age, and argument fields must be omitted or `-`.
Blank lines and whole-line `#` comments are ignored; backslash escapes, inline comments, and other tmpfiles syntax are rejected.

The script applies rules only after every `*.conf` file passes validation.
If any file is invalid, the script exits without creating directories or changing permissions, even for rules in earlier files.

Missing parents are created, and the requested mode is applied to each target, including existing directories.
Existing parents retain their permissions.
Filesystem errors stop execution; directories already processed remain in place.
All logs and diagnostics go to stdout.
The script does not clean or delete anything.
