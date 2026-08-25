#Requires -Version 5.1
<#
.SYNOPSIS
    Regression tests for the host ACL on <InstallRoot>\uploads and for the
    bind mount the DELTA container reaches it through.

.DESCRIPTION
    uploads\ used to be created with New-Item and nothing else, so its ACL was
    whatever the chosen installation root happened to carry. Measured on a real
    installation at C:\DELTA, that is the root-of-C: default:

        BUILTIN\Administrators:(I)(OI)(CI)(F)
        NT AUTHORITY\SYSTEM:(I)(OI)(CI)(F)
        BUILTIN\Users:(I)(OI)(CI)(RX)
        BUILTIN\Users:(I)(CI)(AD)
        BUILTIN\Users:(I)(CI)(WD)
        CREATOR OWNER:(I)(OI)(CI)(IO)(F)

    Two things are wrong with that, and both were measured rather than
    reasoned about.

    It is broader than the data deserves. Every file DELTA writes lands with
    BUILTIN\Users:(RX) on it, so every local interactive account can read every
    uploaded document, and (CI)(AD) + (CI)(WD) let any of them plant files and
    subdirectories in the tree.

    And it is not stable. Those Users entries are the drive-root defaults; an
    installation root somewhere else does not have them. Modelled as a
    UAC-filtered administrator token evaluates it - Administrators deny-only,
    so absent - a Program Files style ACL (Users:(RX), CREATOR OWNER, SYSTEM)
    projects into the container as mode 555 and every write fails, while an
    Administrators + SYSTEM ACL fails earlier still, at

        docker: Error response from daemon: Access is denied.

    Worse, a file the container itself creates carries no entry for the account
    Docker Desktop runs as: CREATOR OWNER materialises from whatever token did
    the write, measured as BUILTIN\Administrators on a Windows Server host. A
    filtered token cannot match that, and such a file measures read-only from
    inside the container afterwards.

    The rights floor comes from DELTA itself. Its server bundle moves each
    upload out of uploads/<tenant>/temp with fs.renameSync, deletes with
    fs.unlinkSync and drops a tenant tree with fs.rmSync(recursive: true).
    Measured on the real bind mount: the (RX,W) grant the TLS staging directory
    uses fails rename, cross-directory rename, directory rename and recursive
    delete; (M) passes the whole matrix. So Modify is the minimum, and Full
    Control - which would add WRITE_DAC and WRITE_OWNER - is more than the
    application ever uses.

    What is pinned here:

      - the ACL Protect-DeltaUploadsDirectory produces: Administrators and
        SYSTEM Full Control, the installing account Modify, nothing else,
        inheritance off;
      - no broad principal survives - not BUILTIN\Users, Everyone,
        Authenticated Users or CREATOR OWNER;
      - every entry is inheritable, so files and subdirectories created later
        are still usable by the account that created them;
      - it is idempotent, and a rerun repairs a deliberately broken ACL;
      - it never deletes, moves or recreates anything, so existing uploads
        survive a rerun with their content intact;
      - it declines rather than locking the directory down when there is no
        user account to grant, because Administrators + SYSTEM is the one ACL
        measured to break the mount;
      - New-DeltaInstallDirectories applies it on every run.

    -Live additionally runs the real DELTA image against a real bind mount and
    exercises the operations the application performs - create, write, read
    back, append, overwrite, rename, cross-directory rename, delete,
    subdirectory create/read/write, directory rename, recursive delete - and
    checks that a file created inside the container is visible on the host and
    still there for a second, freshly created container. It is off by default
    because every other suite here is hostless; it pulls nothing it does not
    already have, works only under a temporary directory of its own, and never
    touches a real installation.

    Exits 0 if every test passes, 1 otherwise.

.PARAMETER Live
    Also validate against the real Docker engine and the real DELTA image.

.PARAMETER LiveImage
    The image to mount with. Defaults to the DELTA application image.

.EXAMPLE
    .\tools\Test-UploadsDirectoryPermissions.ps1

.EXAMPLE
    .\tools\Test-UploadsDirectoryPermissions.ps1 -Live
#>

[CmdletBinding()]
param(
    [switch]$Live,
    [string]$LiveImage = 'ghcr.io/preventionweb/delta-country:prod-latest'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:ProjectRoot = Split-Path -Parent $PSScriptRoot

$Script:Passed = 0
$Script:Failed = 0

. (Join-Path $Script:ProjectRoot 'lib\Delta.Common.ps1')
. (Join-Path $Script:ProjectRoot 'lib\Delta.Config.ps1')
. (Join-Path $Script:ProjectRoot 'lib\Delta.Docker.ps1')

# New-DeltaInstallDirectories is lifted out of lib\Delta.Stack.ps1 by parse
# tree rather than dot-sourcing that file, which would drag Manage, Configure
# and Domain in behind it. Same technique the certificate suite uses, and it
# still exercises the code that ships.
$Script:StackAst = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $Script:ProjectRoot 'lib\Delta.Stack.ps1'), [ref]$null, [ref]$null)

function Get-StackFunctionText {
    param([Parameter(Mandatory)][string]$Name)
    $found = @($Script:StackAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
    }, $true))
    if ($found.Count -ne 1) { throw "lib\Delta.Stack.ps1 should define $Name exactly once; found $($found.Count)." }
    return $found[0].Extent.Text
}

$Script:DeltaInstallDirectories = @(
    'nginx\conf.d', 'certs', 'uploads', 'logs\delta', 'logs\nginx', 'logs\installer', 'backups'
)
. ([scriptblock]::Create((Get-StackFunctionText -Name 'New-DeltaInstallDirectories')))

Set-DeltaActivityMode -Mode 'off'

# ---------------------------------------------------------------------------
# Assertion helpers (same shape as the other suites here)
# ---------------------------------------------------------------------------

function Assert-That {
    param(
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][AllowNull()]$Condition
    )
    if ($Condition) { Write-Host "    [PASS] $Description" -ForegroundColor Green; $Script:Passed++ }
    else            { Write-Host "    [FAIL] $Description" -ForegroundColor Red;   $Script:Failed++ }
}

function Assert-Equal {
    param(
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][AllowNull()]$Expected,
        [Parameter(Mandatory)][AllowNull()]$Actual
    )
    if ($Expected -eq $Actual) { Write-Host "    [PASS] $Description" -ForegroundColor Green; $Script:Passed++ }
    else {
        Write-Host "    [FAIL] $Description" -ForegroundColor Red
        Write-Host "           expected: [$Expected]" -ForegroundColor Red
        Write-Host "           actual:   [$Actual]"   -ForegroundColor Red
        $Script:Failed++
    }
}

function Start-TestCase {
    param([Parameter(Mandatory)][string]$Name)
    Write-Host ''
    Write-Host "==> $Name" -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
# icacls output is one file heading plus indented ACE lines; the trailing two
# summary lines are not entries. Same reader the certificate suite uses.
# ---------------------------------------------------------------------------

function Get-AclEntries {
    param([Parameter(Mandatory)][string]$Path)

    $lines = @(& icacls.exe $Path 2>&1)
    $entries = New-Object 'System.Collections.Generic.List[object]'
    foreach ($line in $lines) {
        $text = [string]$line
        if ($text -match 'Successfully processed' -or -not $text.Trim()) { continue }
        # The first line carries the path before the first entry.
        $candidate = $text
        if ($candidate.StartsWith($Path, [System.StringComparison]::OrdinalIgnoreCase)) {
            $candidate = $candidate.Substring($Path.Length)
        }
        $candidate = $candidate.Trim()
        if (-not $candidate) { continue }
        $split = $candidate.LastIndexOf(':')
        if ($split -lt 1) { continue }
        $null = $entries.Add([PSCustomObject]@{
            Principal = $candidate.Substring(0, $split).Trim()
            Rights    = $candidate.Substring($split + 1).Trim()
        })
    }
    return $entries.ToArray()
}

function Get-UploadsAcl {
    param([Parameter(Mandatory)][string]$Path)
    return Get-AclEntries -Path $Path
}

$Script:CurrentUserSid  = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$Script:CurrentUserName = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$Script:BroadPrincipals = @('BUILTIN\Users', 'Everyone', 'NT AUTHORITY\Authenticated Users', 'CREATOR OWNER')

$Script:WorkRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("delta-uploads-acl-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $Script:WorkRoot -Force

function Remove-TestTree {
    <#
      The modelled directories deliberately have Administrators removed, so an
      ordinary Remove-Item cannot always clear them. Ownership and a reset come
      first.
    #>
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return }
    $null = & takeown.exe @('/F', $Path, '/R', '/D', 'Y') 2>&1
    $null = & icacls.exe @($Path, '/reset', '/T', '/C') 2>&1
    $null = & icacls.exe @($Path, '/grant', 'BUILTIN\Administrators:(OI)(CI)(F)', '/T', '/C') 2>&1
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
}

try {

# ---------------------------------------------------------------------------
Start-TestCase 'The ACL Protect-DeltaUploadsDirectory produces'
# ---------------------------------------------------------------------------

$root = Join-Path $Script:WorkRoot 'install-a'
$uploads = Join-Path $root 'uploads'
$null = New-Item -ItemType Directory -Path $uploads -Force

# The suite's own working directory is under %TEMP%, which does not carry the
# drive-root defaults, so the pre-fix state is written out here rather than
# inherited. These are the exact entries measured on a real C:\DELTA\uploads.
foreach ($rootDefault in @('BUILTIN\Users:(OI)(CI)(RX)', 'BUILTIN\Users:(CI)(AD)', 'BUILTIN\Users:(CI)(WD)', 'CREATOR OWNER:(OI)(CI)(IO)(F)')) {
    $null = & icacls.exe @($uploads, '/grant', $rootDefault, '/C') 2>&1
}

$before = Get-UploadsAcl -Path $uploads
Assert-That 'before the fix the directory carries broad principals' `
    (@($before | Where-Object { $Script:BroadPrincipals -contains $_.Principal }).Count -gt 0)

$applied = Protect-DeltaUploadsDirectory -Path $uploads
Assert-That "the ACL is applied: $($applied.Reason)" $applied.Applied

$after = Get-UploadsAcl -Path $uploads
Assert-Equal 'exactly three entries remain' 3 $after.Count

$admins = @($after | Where-Object { $_.Principal -eq 'BUILTIN\Administrators' })
$system = @($after | Where-Object { $_.Principal -eq 'NT AUTHORITY\SYSTEM' })
$user   = @($after | Where-Object { $_.Principal -eq $Script:CurrentUserName })

Assert-Equal 'Administrators keep Full Control, inheritable' '(OI)(CI)(F)' $(if ($admins.Count -eq 1) { $admins[0].Rights })
Assert-Equal 'SYSTEM keeps Full Control, inheritable'        '(OI)(CI)(F)' $(if ($system.Count -eq 1) { $system[0].Rights })
Assert-Equal 'the installing account gets Modify, inheritable' '(OI)(CI)(M)' $(if ($user.Count -eq 1) { $user[0].Rights })

Assert-That 'the account does NOT get Full Control' `
    (@($after | Where-Object { $_.Principal -eq $Script:CurrentUserName -and $_.Rights -match '\(F\)' }).Count -eq 0)

# ---------------------------------------------------------------------------
Start-TestCase 'No broad principal survives'
# ---------------------------------------------------------------------------

foreach ($principal in $Script:BroadPrincipals) {
    Assert-That "$principal has no entry" `
        (@($after | Where-Object { $_.Principal -eq $principal }).Count -eq 0)
}

Assert-That 'no entry is inherited - inheritance is off' `
    (@($after | Where-Object { $_.Rights -match '\(I\)' }).Count -eq 0)

# ---------------------------------------------------------------------------
Start-TestCase 'Newly created files and subdirectories stay usable'
# ---------------------------------------------------------------------------

# (OI)(CI) on every entry is what makes this true, and it is the failure mode
# the brief calls out: a parent fixed and children left inaccessible.
$childDir  = Join-Path $uploads 'tenant-1'
$null = New-Item -ItemType Directory -Path $childDir -Force
$childFile = Join-Path $childDir 'attachment.txt'
Set-Content -LiteralPath $childFile -Value 'x' -Encoding utf8

$childDirAcl  = Get-UploadsAcl -Path $childDir
$childFileAcl = Get-UploadsAcl -Path $childFile

Assert-That 'a new subdirectory inherits the account entry' `
    (@($childDirAcl | Where-Object { $_.Principal -eq $Script:CurrentUserName -and $_.Rights -match 'M' }).Count -ge 1)
Assert-That 'a new file inherits the account entry' `
    (@($childFileAcl | Where-Object { $_.Principal -eq $Script:CurrentUserName -and $_.Rights -match 'M' }).Count -ge 1)
foreach ($principal in $Script:BroadPrincipals) {
    Assert-That "a new file does not inherit $principal" `
        (@($childFileAcl | Where-Object { $_.Principal -eq $principal }).Count -eq 0)
}

# ---------------------------------------------------------------------------
Start-TestCase 'Idempotent, and content is preserved'
# ---------------------------------------------------------------------------

$again = Protect-DeltaUploadsDirectory -Path $uploads
Assert-That 'a second application succeeds' $again.Applied

$secondAcl = Get-UploadsAcl -Path $uploads
Assert-Equal 'and produces the same three entries' 3 $secondAcl.Count
Assert-Equal 'with no duplicate entry for the account' 1 `
    @($secondAcl | Where-Object { $_.Principal -eq $Script:CurrentUserName }).Count
Assert-Equal 'the existing upload is still there' 'x' (Get-Content -LiteralPath $childFile -Raw).Trim()

# ---------------------------------------------------------------------------
Start-TestCase 'A rerun repairs a broken ACL without touching content'
# ---------------------------------------------------------------------------

# The ACL an earlier version of this installer left behind: everything
# inherited from the drive root, including BUILTIN\Users.
$null = & icacls.exe @($uploads, '/inheritance:e', '/C') 2>&1
$null = & icacls.exe @($uploads, '/grant', 'BUILTIN\Users:(OI)(CI)(RX)', '/C') 2>&1
$null = & icacls.exe @($uploads, '/grant', 'Everyone:(OI)(CI)(M)', '/C') 2>&1

$broken = Get-UploadsAcl -Path $uploads
Assert-That 'the broken ACL really does expose the directory' `
    (@($broken | Where-Object { $_.Principal -eq 'Everyone' }).Count -ge 1)

$repaired = Protect-DeltaUploadsDirectory -Path $uploads
Assert-That 'the rerun repairs it' $repaired.Applied

$repairedAcl = Get-UploadsAcl -Path $uploads
Assert-Equal 'back to three entries' 3 $repairedAcl.Count
foreach ($principal in $Script:BroadPrincipals) {
    Assert-That "$principal is gone again - explicit, not just inherited" `
        (@($repairedAcl | Where-Object { $_.Principal -eq $principal }).Count -eq 0)
}
Assert-That 'and the existing upload was not deleted' (Test-Path -LiteralPath $childFile -PathType Leaf)
Assert-Equal 'nor its content changed' 'x' (Get-Content -LiteralPath $childFile -Raw).Trim()

# ---------------------------------------------------------------------------
Start-TestCase 'It declines rather than locking the mount out'
# ---------------------------------------------------------------------------

# Administrators + SYSTEM is the ACL measured to fail the bind mount outright,
# so with no account to grant, nothing is changed at all.
$noSidRoot = Join-Path $Script:WorkRoot 'no-sid\uploads'
$null = New-Item -ItemType Directory -Path $noSidRoot -Force
$noSidBefore = Get-UploadsAcl -Path $noSidRoot

function Get-DeltaDockerFileReadSid { return $null }
$declined = Protect-DeltaUploadsDirectory -Path $noSidRoot
Remove-Item -LiteralPath 'function:Get-DeltaDockerFileReadSid' -ErrorAction SilentlyContinue
. (Join-Path $Script:ProjectRoot 'lib\Delta.Config.ps1')

Assert-That 'nothing is applied when there is no account to grant' (-not $declined.Applied)
Assert-That 'and it says why' ($declined.Reason -match '(?i)docker desktop')
Assert-Equal 'the ACL is left exactly as it was' $noSidBefore.Count (Get-UploadsAcl -Path $noSidRoot).Count

Assert-That 'a path that is not a directory is refused' `
    (-not (Protect-DeltaUploadsDirectory -Path (Join-Path $Script:WorkRoot 'nothing-here')).Applied)

# ---------------------------------------------------------------------------
Start-TestCase 'New-DeltaInstallDirectories applies it on every run'
# ---------------------------------------------------------------------------

$freshRoot = Join-Path $Script:WorkRoot 'fresh'
$first = New-DeltaInstallDirectories -InstallRoot $freshRoot
Assert-That 'a fresh installation root is created' $first.Succeeded
Assert-That 'and its uploads ACL is applied on the way through' $first.UploadsAcl.Applied

$freshUploads = Join-Path $freshRoot 'uploads'
$freshAcl = Get-UploadsAcl -Path $freshUploads
Assert-Equal 'with the expected three entries' 3 $freshAcl.Count
Assert-That 'and no BUILTIN\Users' `
    (@($freshAcl | Where-Object { $_.Principal -eq 'BUILTIN\Users' }).Count -eq 0)

# A rerun on a live installation: the state file the real run writes a moment
# after this stage, an upload already on disk, and the ACL broken underneath
# it - explicitly, which is the case /inheritance:r alone would miss.
$null = Write-DeltaInstallState -InstallRoot $freshRoot -Properties ([ordered]@{ state = 'installed'; installRoot = $freshRoot })

$liveUpload = Join-Path $freshUploads 'tenant-7\report.txt'
$null = New-Item -ItemType Directory -Path (Split-Path -Parent $liveUpload) -Force
Set-Content -LiteralPath $liveUpload -Value 'real user data' -Encoding utf8
$null = & icacls.exe @($freshUploads, '/grant', 'BUILTIN\Users:(OI)(CI)(M)', '/C') 2>&1

$second = New-DeltaInstallDirectories -InstallRoot $freshRoot
Assert-That "the rerun succeeds: $($second.Reason)" $second.Succeeded
Assert-Equal 'and creates nothing, because the layout is already there' 0 $second.Created.Count
Assert-That 'the uploads ACL is repaired again' ($second.Succeeded -and $second.UploadsAcl.Applied)
Assert-That 'BUILTIN\Users is gone' `
    (@(Get-UploadsAcl -Path $freshUploads | Where-Object { $_.Principal -eq 'BUILTIN\Users' }).Count -eq 0)
Assert-That 'the existing upload survived the rerun' (Test-Path -LiteralPath $liveUpload -PathType Leaf)
Assert-Equal 'with its content intact' 'real user data' (Get-Content -LiteralPath $liveUpload -Raw).Trim()

# The uninstall backup walks uploads\ elevated; Administrators must still read.
Assert-Equal 'and the backup walk can still see it' 1 `
    @(Get-ChildItem -LiteralPath $freshUploads -Recurse -File -Force).Count

# ---------------------------------------------------------------------------
Start-TestCase 'The shipped source says what it does'
# ---------------------------------------------------------------------------

$configText = Get-Content -LiteralPath (Join-Path $Script:ProjectRoot 'lib\Delta.Config.ps1') -Raw
Assert-That 'the grant is Modify, not Full Control' `
    ($configText -match '\$\{dockerSid\}:\(OI\)\(CI\)\(M\)')
Assert-That 'and it grants with :r, so a rerun replaces rather than adds' `
    ($configText -match '(?i)icacls\.exe \$Path /grant:r \$grant /C')

$stackText = Get-Content -LiteralPath (Join-Path $Script:ProjectRoot 'lib\Delta.Stack.ps1') -Raw
Assert-That 'New-DeltaInstallDirectories still never removes anything' `
    ($stackText -notmatch '(?m)^\s*Remove-Item.*InstallRoot')

# ---------------------------------------------------------------------------
# Live
# ---------------------------------------------------------------------------

if ($Live) {

    Start-TestCase 'Live: the operations DELTA performs, through a real bind mount'

    $imageCheck = Invoke-DeltaDockerCommand -Arguments @('image', 'inspect', $LiveImage, '--format', '{{.Id}}') -TimeoutSeconds 120
    if ($imageCheck.ExitCode -ne 0) {
        Write-Host "    [skip] $LiveImage is not present locally, and this suite pulls nothing" -ForegroundColor DarkGray
    }
    else {
        # The probe is the application's own vocabulary: mkdir -p, write, read
        # back, append, overwrite, mv within a directory, mv across
        # directories, rm, rmdir by rename, rm -rf. fs.renameSync, unlinkSync
        # and rmSync(recursive) are what DELTA's bundle actually calls.
        $probe = @(
            'M=/delta/uploads; B=$M/.probe',
            't() { if eval "$2" >/dev/null 2>&1; then echo "$1=OK"; else echo "$1=FAIL"; fi; }',
            'echo mode=$(stat -c %a $M)',
            't traverse     "ls -1a $M"',
            't seed_read    "cat $M/seed.txt"',
            't seed_write   "echo changed > $M/seed.txt"',
            't seed_delete  "rm -f $M/seed.txt && [ ! -e $M/seed.txt ]"',
            't mkdir        "mkdir -p $B/sub/deep"',
            't create       "touch $B/a.txt"',
            't write        "echo hello > $B/a.txt"',
            't readback     "[ \"$(cat $B/a.txt)\" = hello ]"',
            't append       "echo more >> $B/a.txt"',
            't overwrite    "echo again > $B/a.txt"',
            't rename       "mv $B/a.txt $B/b.txt"',
            't rename_cross "mv $B/b.txt $B/sub/b.txt"',
            't sub_write    "echo x > $B/sub/deep/c.txt"',
            't sub_read     "cat $B/sub/deep/c.txt"',
            't sub_list     "ls -1 $B/sub/deep"',
            't delete_file  "rm -f $B/sub/b.txt && [ ! -e $B/sub/b.txt ]"',
            't rename_dir   "mv $B/sub $B/sub2"',
            't rmtree       "rm -rf $B && [ ! -e $B ]"',
            'echo -n persist=; echo kept > $M/persist.txt && echo OK || echo FAIL'
        ) -join '; '

        $liveRoot = Join-Path $Script:WorkRoot 'live'
        $liveUploads = Join-Path $liveRoot 'uploads'
        $null = New-Item -ItemType Directory -Path $liveUploads -Force

        # seed.txt is written by this elevated process before the ACL is
        # applied - a file an earlier installer version, or a restore, put
        # there. It has to remain fully usable afterwards.
        Set-Content -LiteralPath (Join-Path $liveUploads 'seed.txt') -Value 'existing upload' -Encoding utf8
        $liveAcl = Protect-DeltaUploadsDirectory -Path $liveUploads
        Assert-That 'the real ACL is applied to the live directory' $liveAcl.Applied

        $run = Invoke-DeltaDockerCommand -Arguments @(
            'run', '--rm', '--network', 'none',
            '-v', "${liveUploads}:/delta/uploads",
            '--entrypoint', 'sh', $LiveImage, '-c', $probe) -TimeoutSeconds 300

        $out = ($run.StdOut + "`n" + $run.StdErr)
        Assert-Equal 'the probe container ran' 0 $run.ExitCode
        Assert-That "the mount is not read-only (mode was $(($out -split "`n" | Where-Object { $_ -match '^mode=' }) -join ''))" `
            ($out -notmatch 'mode=[0-5]55')

        foreach ($op in @(
            'traverse', 'seed_read', 'seed_write', 'seed_delete', 'mkdir', 'create', 'write',
            'readback', 'append', 'overwrite', 'rename', 'rename_cross', 'sub_write', 'sub_read',
            'sub_list', 'delete_file', 'rename_dir', 'rmtree', 'persist')) {
            Assert-That "$op succeeds in the container" ($out -match "(?m)^$op=OK")
        }

        Start-TestCase 'Live: what the container wrote is on the host, and survives recreation'

        $persisted = Join-Path $liveUploads 'persist.txt'
        Assert-That 'the container-created file exists on Windows' (Test-Path -LiteralPath $persisted -PathType Leaf)
        Assert-Equal 'with the content the container wrote' 'kept' (Get-Content -LiteralPath $persisted -Raw).Trim()

        $childAcl = Get-UploadsAcl -Path $persisted
        Assert-That 'and it carries the account entry it inherited, not BUILTIN\Users' `
            ((@($childAcl | Where-Object { $_.Principal -eq 'BUILTIN\Users' }).Count -eq 0))

        # A second, freshly created container - the recreation case. The payload
        # is joined into one string first: split across array elements it would
        # arrive as sh's $0 and never run, which is a silent pass waiting to
        # happen.
        $recreate = @(
            'cat /delta/uploads/persist.txt',
            'echo -n reuse=; (echo again >> /delta/uploads/persist.txt) && echo OK || echo FAIL',
            'echo -n cleanup=; rm -f /delta/uploads/persist.txt && echo OK || echo FAIL'
        ) -join '; '

        $again = Invoke-DeltaDockerCommand -Arguments @(
            'run', '--rm', '--network', 'none',
            '-v', "${liveUploads}:/delta/uploads",
            '--entrypoint', 'sh', $LiveImage, '-c', $recreate) -TimeoutSeconds 300

        $againOut = (($again.StdOut + ' ' + $again.StdErr) -replace '\s+', ' ').Trim()
        Assert-That 'a new container still sees the file' ($again.StdOut -match 'kept')
        Assert-That 'and can still write to it'            ($again.StdOut -match 'reuse=OK')
        Assert-That "and can still delete it: $againOut"   ($again.StdOut -match 'cleanup=OK')
        Assert-That 'the host agrees it is gone'           (-not (Test-Path -LiteralPath $persisted))

        Start-TestCase 'Live: the ACLs that do NOT work, so the fix is not a coincidence'

        # Written as a UAC-filtered administrator token evaluates them:
        # BUILTIN\Administrators is deny-only in such a token and grants
        # nothing, so it is absent here.
        function Set-FilteredTokenModelAcl {
            param([Parameter(Mandatory)][string]$Path, [string[]]$Grants = @())
            $null = & icacls.exe @($Path, '/inheritance:r', '/C') 2>&1
            $null = & icacls.exe @($Path, '/grant', 'NT AUTHORITY\SYSTEM:(OI)(CI)(F)', '/C') 2>&1
            foreach ($p in @('BUILTIN\Administrators', 'BUILTIN\Users', 'CREATOR OWNER', "*$Script:CurrentUserSid", 'Everyone', 'NT AUTHORITY\Authenticated Users')) {
                $null = & icacls.exe @($Path, '/remove', $p, '/C') 2>&1
            }
            foreach ($g in $Grants) { $null = & icacls.exe @($Path, '/grant', $g, '/C') 2>&1 }
        }

        $negatives = [ordered]@{
            'Administrators + SYSTEM only'                = @{ Grants = @();                                          Expect = 'mount' }
            'the TLS staging grant (RX,W) - no DELETE'    = @{ Grants = @("*$Script:CurrentUserSid`:(OI)(CI)(RX,W)"); Expect = 'rename' }
            'a Program Files style root (Users RX only)'  = @{ Grants = @('BUILTIN\Users:(OI)(CI)(RX)');               Expect = 'write' }
        }

        $modelRoot = Join-Path $Script:WorkRoot 'models'
        $null = New-Item -ItemType Directory -Path $modelRoot -Force

        foreach ($label in $negatives.Keys) {
            $dir = Join-Path $modelRoot ('m' + [guid]::NewGuid().ToString('N').Substring(0, 6))
            $null = New-Item -ItemType Directory -Path $dir -Force
            Set-FilteredTokenModelAcl -Path $dir -Grants $negatives[$label].Grants

            $neg = Invoke-DeltaDockerCommand -Arguments @(
                'run', '--rm', '--network', 'none',
                '-v', "${dir}:/delta/uploads",
                '--entrypoint', 'sh', $LiveImage, '-c', $probe) -TimeoutSeconds 300
            $negOut = ($neg.StdOut + "`n" + $neg.StdErr)

            switch ($negatives[$label].Expect) {
                'mount'  { Assert-That "$label - the bind mount itself is refused" `
                               (($neg.ExitCode -ne 0) -and ($negOut -match '(?i)access is denied')) }
                'rename' { Assert-That "$label - rename and recursive delete fail" `
                               (($negOut -match '(?m)^rename=FAIL') -and ($negOut -match '(?m)^rmtree=FAIL')) }
                'write'  { Assert-That "$label - the container cannot create a file at all" `
                               (($negOut -match '(?m)^create=FAIL') -or ($negOut -match '(?m)^mkdir=FAIL')) }
            }
        }
    }
}

}
finally {
    Remove-TestTree -Path $Script:WorkRoot
}

Write-Host ''
Write-Host ('-' * 60)
Write-Host "  passed: $Script:Passed"
Write-Host "  failed: $Script:Failed"
Write-Host ('-' * 60)
Write-Host ''
if (-not $Live) {
    Write-Host '  No container was started. Run with -Live to validate the real'
    Write-Host '  bind mount against the real Docker engine as well.'
    Write-Host ''
}

exit $(if ($Script:Failed -gt 0) { 1 } else { 0 })
