<#
.SYNOPSIS
    Single source of truth for the DELTA Windows Docker Installer's own
    version (the installer, not the DELTA application it deploys, and not
    the images it pins).

.DESCRIPTION
    A plain dot-sourced variable file, deliberately standalone: it defines
    one literal and nothing else, so anything that needs the installer's
    version can dot-source THIS file by itself - no $Script:DeltaScriptRoot,
    no Delta.Common.ps1, no library table - and get an answer. release.ps1
    reads it that way, and so does .github\workflows\release.yml's
    "Verify installer version matches Git tag" step, which dot-sources this
    file on the runner to compare it against the pushed tag.

    That standalone property is the whole design. Deriving this value from
    .env, from the install-state file, or from any Delta.*.ps1 library would
    make it unreadable to a caller that has only the repository checked out,
    which is exactly the caller that needs it most.

    Not registered in setup.ps1's $Script:DeltaLibraries table. That table
    pairs each library with a function the library must define once loaded,
    as a guard against a half-loaded lib\ - and this file defines no
    functions. Nothing in the installer's runtime path reads it today; it
    exists for release tooling, and for whatever later chooses to display
    the installer's version.

    Maintained by hand, not derived from Git. release.ps1 is what bumps it,
    in the same commit that prepares a release, so it matches the "vX.Y.Z"
    tag that commit is tagged with. That agreement is enforced twice: once
    locally by release.ps1, which reads this file to decide the tag, and
    again on the runner by .github\workflows\release.yml, which refuses to
    publish a release whose tag disagrees with the value below.
    tools\build-release.ps1 is the one exception - it takes the version as
    a parameter and does not cross-check it against this file, because the
    workflow has already done so before invoking it (see README, "Cutting
    a release").

    This file lives in lib\, which tools\build-release.ps1 copies whole,
    so the installer's version ships inside every release package
    automatically with no packaging change required to keep it there.
#>

$Script:DeltaInstallerVersion = '1.0.0'
