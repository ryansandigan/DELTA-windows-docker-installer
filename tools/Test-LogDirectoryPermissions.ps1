#Requires -Version 5.1
<#
.SYNOPSIS
    Regression tests for the host ACLs on <InstallRoot>\logs\delta and
    <InstallRoot>\logs\nginx, and for the bind mounts the DELTA and NGINX
    containers reach them through - including the full NGINX rotation cycle.

.DESCRIPTION
    Both log directories used to be created with New-Item and nothing else, so
    each carried whatever the installation root inherited. Measured on a real
    installation at C:\DELTA, that is the root-of-C: default on the directory
    and, on every log file the containers had already written:

        NT AUTHORITY\SYSTEM:(I)(F)
        BUILTIN\Administrators:(I)(F)
        BUILTIN\Users:(I)(RX)

    owned by BUILTIN\Administrators, with no entry at all for the account
    Docker Desktop runs as. So any local account could read the NGINX access
    log - a record of who requested what - and DELTA's application log, and
    whether the installer could rotate them depended on that account's token
    still carrying BUILTIN\Administrators enabled, which a UAC-filtered
    administrator token does not.

    The rights floor was measured per directory rather than assumed, against
    the real engine on DACLs written as a filtered token evaluates them
    (Administrators deny-only, so absent):

      logs\delta, driven through the image's own winston +
      winston-daily-rotate-file transport with the options the application
      builds - zippedArchive, maxSize, maxFiles:

        Administrators + SYSTEM  ->  docker: Error response from daemon:
                                     Access is denied
        Users:(RX) only          ->  Error: EACCES: permission denied, open
                                     '/delta/logs/dts-<date>.log', raised as an
                                     unhandled 'error' event - Node exits
        <user>:(RX,W)            ->  logging works; rename and delete FAIL, 26
                                     rotated files and the audit file left
                                     behind, retention silently dead
        <user>:(M)               ->  everything, nothing left behind

      logs\nginx, driven through the real Invoke-DeltaNginxLogRotation against
      a real NGINX container, four rotations retaining two:

        Administrators + SYSTEM  ->  the container cannot be created
        Users:(RX) only          ->  nginx: [alert] could not open error log
                                     file ... (13: Permission denied); NGINX
                                     never starts
        <user>:(RX,W)            ->  NGINX starts and logs, then every rotation
                                     fails with mv: can't rename
                                     '/var/log/nginx/access.log':
                                     Permission denied
        <user>:(M)               ->  rotate, reopen, fresh access.log and
                                     retention delete, all four cycles

    They fail (RX,W) for different reasons - DELTA's own logger renames and
    unlinks; NGINX never renames anything, the installer's rotation does it
    inside the container so the open file moves with POSIX semantics, which
    crosses the 9p link as the Docker Desktop account - and they arrive at the
    same answer: Modify, which carries DELETE, and not Full Control, which
    would add WRITE_DAC and WRITE_OWNER that no container uses.

    What is pinned here:

      - the ACL Protect-DeltaLogDirectory produces on each directory:
        Administrators and SYSTEM Full Control, the installing account Modify,
        nothing else, inheritance off;
      - no broad principal survives, explicit or inherited;
      - every entry is inheritable, so log files written afterwards are still
        writable, renameable and deletable;
      - ownership is NOT changed - the fix must work with the directory still
        owned by whoever owned it;
      - it is idempotent, repairs a broken ACL on rerun, and never creates,
        truncates, moves or deletes a log file;
      - existing logs written before the repair keep their content and become
        usable again through re-inheritance;
      - it declines rather than locking the mount out when there is no account
        to grant;
      - New-DeltaInstallDirectories applies it to both directories, and to
        logs\installer - which nothing mounts - it does not.

    -Live additionally runs the real images: the DELTA image's own winston
    transport against a real /delta/logs mount, and a real NGINX container
    through the real rotation function - start, error log, access log,
    requests, rotate, reopen, replacement file, retention delete, and logging
    again afterwards. It also runs the ACLs that do NOT work, so a passing
    suite is evidence rather than coincidence. Off by default; it pulls
    nothing, works only under a temporary directory of its own, and never
    touches a real installation. No log content is printed - the assertions
    report names, sizes and outcomes.

    Exits 0 if every test passes, 1 otherwise.

.PARAMETER Live
    Also validate against the real Docker engine and the real images.

.PARAMETER LiveImage
    The DELTA application image, for the winston transport tests.

.PARAMETER LiveNginxImage
    The NGINX image, for the rotation lifecycle tests.

.EXAMPLE
    .\tools\Test-LogDirectoryPermissions.ps1

.EXAMPLE
    .\tools\Test-LogDirectoryPermissions.ps1 -Live
#>

[CmdletBinding()]
param(
    [switch]$Live,
    [string]$LiveImage = 'ghcr.io/preventionweb/delta-country:prod-latest',
    [string]$LiveNginxImage = 'nginx:1.29-alpine'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:ProjectRoot = Split-Path -Parent $PSScriptRoot

$Script:Passed = 0
$Script:Failed = 0

. (Join-Path $Script:ProjectRoot 'lib\Delta.Common.ps1')
. (Join-Path $Script:ProjectRoot 'lib\Delta.Config.ps1')
. (Join-Path $Script:ProjectRoot 'lib\Delta.Docker.ps1')
. (Join-Path $Script:ProjectRoot 'lib\Delta.Network.ps1')
. (Join-Path $Script:ProjectRoot 'lib\Delta.Stack.ps1')
. (Join-Path $Script:ProjectRoot 'lib\Delta.Manage.ps1')

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

function Get-AclEntries {
    param([Parameter(Mandatory)][string]$Path)

    $lines = @(& icacls.exe $Path 2>&1)
    $entries = New-Object 'System.Collections.Generic.List[object]'
    foreach ($line in $lines) {
        $text = [string]$line
        if ($text -match 'Successfully processed' -or -not $text.Trim()) { continue }
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

$Script:CurrentUserSid  = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$Script:CurrentUserName = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$Script:BroadPrincipals = @('BUILTIN\Users', 'Everyone', 'NT AUTHORITY\Authenticated Users', 'CREATOR OWNER')

# The entries a directory under the root of C: inherits. The suite's own work
# root is under %TEMP%, which does not carry them, so the pre-fix state is
# written out rather than inherited.
$Script:RootDefaults = @(
    'BUILTIN\Users:(OI)(CI)(RX)'
    'BUILTIN\Users:(CI)(AD)'
    'BUILTIN\Users:(CI)(WD)'
    'CREATOR OWNER:(OI)(CI)(IO)(F)'
)

$Script:WorkRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("delta-logs-acl-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $Script:WorkRoot -Force

function Remove-TestTree {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $null = & takeown.exe @('/F', $Path, '/R', '/D', 'Y') 2>&1
    $null = & icacls.exe @($Path, '/reset', '/T', '/C') 2>&1
    $null = & icacls.exe @($Path, '/grant', 'BUILTIN\Administrators:(OI)(CI)(F)', '/T', '/C') 2>&1
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
}

function New-InheritedLogDirectory {
    <#
      A log directory carrying the drive-root defaults and one log file already
      in it, written before the ACL is applied - an installation that has been
      running for a while.
    #>
    param([Parameter(Mandatory)][string]$Path, [string]$LogName = 'access.log')

    $null = New-Item -ItemType Directory -Path $Path -Force
    foreach ($grant in $Script:RootDefaults) {
        $null = & icacls.exe @($Path, '/grant', $grant, '/C') 2>&1
    }
    Set-Content -LiteralPath (Join-Path $Path $LogName) -Value 'existing log line' -Encoding utf8
    return $Path
}

try {

foreach ($which in @('delta', 'nginx')) {

    # -----------------------------------------------------------------------
    Start-TestCase "logs\$which - the ACL Protect-DeltaLogDirectory produces"
    # -----------------------------------------------------------------------

    $dir = New-InheritedLogDirectory -Path (Join-Path $Script:WorkRoot "a\logs\$which")
    $logFile = Join-Path $dir 'access.log'
    $ownerBefore = (Get-Acl -LiteralPath $dir).Owner

    $before = Get-AclEntries -Path $dir
    Assert-That "before the fix logs\$which carries broad principals" `
        (@($before | Where-Object { $Script:BroadPrincipals -contains $_.Principal }).Count -gt 0)
    Assert-That 'and the existing log is readable by BUILTIN\Users' `
        (@(Get-AclEntries -Path $logFile | Where-Object { $_.Principal -eq 'BUILTIN\Users' }).Count -ge 1)

    $applied = Protect-DeltaLogDirectory -Path $dir
    Assert-That "the ACL is applied: $($applied.Reason)" $applied.Applied

    $after = Get-AclEntries -Path $dir
    Assert-Equal 'exactly three entries remain' 3 $after.Count

    $admins = @($after | Where-Object { $_.Principal -eq 'BUILTIN\Administrators' })
    $system = @($after | Where-Object { $_.Principal -eq 'NT AUTHORITY\SYSTEM' })
    $user   = @($after | Where-Object { $_.Principal -eq $Script:CurrentUserName })

    Assert-Equal 'Administrators keep Full Control, inheritable'   '(OI)(CI)(F)' $(if ($admins.Count -eq 1) { $admins[0].Rights })
    Assert-Equal 'SYSTEM keeps Full Control, inheritable'          '(OI)(CI)(F)' $(if ($system.Count -eq 1) { $system[0].Rights })
    Assert-Equal 'the installing account gets Modify, inheritable' '(OI)(CI)(M)' $(if ($user.Count -eq 1) { $user[0].Rights })
    Assert-That  'and not Full Control' `
        (@($after | Where-Object { $_.Principal -eq $Script:CurrentUserName -and $_.Rights -match '\(F\)' }).Count -eq 0)

    # -----------------------------------------------------------------------
    Start-TestCase "logs\$which - no broad principal survives"
    # -----------------------------------------------------------------------

    foreach ($principal in $Script:BroadPrincipals) {
        Assert-That "$principal has no entry on the directory" `
            (@($after | Where-Object { $_.Principal -eq $principal }).Count -eq 0)
    }
    Assert-That 'inheritance is off' (@($after | Where-Object { $_.Rights -match '\(I\)' }).Count -eq 0)

    # -----------------------------------------------------------------------
    Start-TestCase "logs\$which - existing logs survive and become usable"
    # -----------------------------------------------------------------------

    Assert-That  'the existing log was not deleted' (Test-Path -LiteralPath $logFile -PathType Leaf)
    Assert-Equal 'nor truncated or rewritten' 'existing log line' (Get-Content -LiteralPath $logFile -Raw).Trim()

    $logAcl = Get-AclEntries -Path $logFile
    Assert-That 'it re-inherited the account entry, so rotation can move it' `
        (@($logAcl | Where-Object { $_.Principal -eq $Script:CurrentUserName -and $_.Rights -match 'M' }).Count -ge 1)
    foreach ($principal in $Script:BroadPrincipals) {
        Assert-That "and no longer carries $principal" `
            (@($logAcl | Where-Object { $_.Principal -eq $principal }).Count -eq 0)
    }

    # -----------------------------------------------------------------------
    Start-TestCase "logs\$which - files written afterwards are usable too"
    # -----------------------------------------------------------------------

    $newLog = Join-Path $dir 'error.log'
    Set-Content -LiteralPath $newLog -Value 'new line' -Encoding utf8
    $newAcl = Get-AclEntries -Path $newLog
    Assert-That 'a newly created log inherits the account entry' `
        (@($newAcl | Where-Object { $_.Principal -eq $Script:CurrentUserName -and $_.Rights -match 'M' }).Count -ge 1)
    Assert-That 'and no broad principal' `
        (@($newAcl | Where-Object { $Script:BroadPrincipals -contains $_.Principal }).Count -eq 0)

    $subDir = Join-Path $dir 'nested'
    $null = New-Item -ItemType Directory -Path $subDir -Force
    Assert-That 'a subdirectory inherits it as well' `
        (@(Get-AclEntries -Path $subDir | Where-Object { $_.Principal -eq $Script:CurrentUserName -and $_.Rights -match 'M' }).Count -ge 1)

    # -----------------------------------------------------------------------
    Start-TestCase "logs\$which - ownership is left alone"
    # -----------------------------------------------------------------------

    # Deliberate: the three entries are explicit and inheritable, so effective
    # access does not depend on who owns the directory. Changing the owner
    # would change a displayed value and no behaviour.
    Assert-Equal 'the directory owner is unchanged' $ownerBefore (Get-Acl -LiteralPath $dir).Owner

    # -----------------------------------------------------------------------
    Start-TestCase "logs\$which - idempotent, and a rerun repairs a broken ACL"
    # -----------------------------------------------------------------------

    $again = Protect-DeltaLogDirectory -Path $dir
    Assert-That  'a second application succeeds' $again.Applied
    Assert-Equal 'and produces the same three entries' 3 (Get-AclEntries -Path $dir).Count
    Assert-Equal 'with no duplicate entry for the account' 1 `
        @(Get-AclEntries -Path $dir | Where-Object { $_.Principal -eq $Script:CurrentUserName }).Count

    # Broken two ways at once: inheritance re-enabled, and a broad principal
    # granted explicitly - which /inheritance:r alone would not remove.
    $null = & icacls.exe @($dir, '/inheritance:e', '/C') 2>&1
    $null = & icacls.exe @($dir, '/grant', 'Everyone:(OI)(CI)(M)', '/C') 2>&1
    $null = & icacls.exe @($dir, '/grant', 'BUILTIN\Users:(OI)(CI)(RX)', '/C') 2>&1
    Assert-That 'the broken ACL really does expose the directory' `
        (@(Get-AclEntries -Path $dir | Where-Object { $_.Principal -eq 'Everyone' }).Count -ge 1)

    $repaired = Protect-DeltaLogDirectory -Path $dir
    Assert-That  'the rerun repairs it' $repaired.Applied
    Assert-Equal 'back to three entries' 3 (Get-AclEntries -Path $dir).Count
    foreach ($principal in $Script:BroadPrincipals) {
        Assert-That "$principal is gone again - explicit, not just inherited" `
            (@(Get-AclEntries -Path $dir | Where-Object { $_.Principal -eq $principal }).Count -eq 0)
    }
    Assert-Equal 'and the existing log still reads the same' 'existing log line' (Get-Content -LiteralPath $logFile -Raw).Trim()

    # -----------------------------------------------------------------------
    Start-TestCase "logs\$which - a restrictive parent cannot decide the result"
    # -----------------------------------------------------------------------

    # The Program Files case: a parent granting Users read and nothing else.
    # The directory must still come out with the account's Modify entry.
    $tightParent = Join-Path $Script:WorkRoot "tight-$which"
    $null = New-Item -ItemType Directory -Path $tightParent -Force
    $null = & icacls.exe @($tightParent, '/inheritance:r', '/C') 2>&1
    $null = & icacls.exe @($tightParent, '/grant', 'NT AUTHORITY\SYSTEM:(OI)(CI)(F)', '/C') 2>&1
    $null = & icacls.exe @($tightParent, '/grant', 'BUILTIN\Administrators:(OI)(CI)(F)', '/C') 2>&1
    $null = & icacls.exe @($tightParent, '/grant', 'BUILTIN\Users:(OI)(CI)(RX)', '/C') 2>&1
    $tightLogs = Join-Path $tightParent "logs\$which"
    $null = New-Item -ItemType Directory -Path $tightLogs -Force

    $tightApplied = Protect-DeltaLogDirectory -Path $tightLogs
    Assert-That  'it applies under a restrictive parent too' $tightApplied.Applied
    Assert-Equal 'and the result is the same three entries' 3 (Get-AclEntries -Path $tightLogs).Count
    Assert-That  'with the account holding Modify regardless of what the parent granted' `
        (@(Get-AclEntries -Path $tightLogs | Where-Object { $_.Principal -eq $Script:CurrentUserName -and $_.Rights -eq '(OI)(CI)(M)' }).Count -eq 1)
}

# ---------------------------------------------------------------------------
Start-TestCase 'It declines rather than locking the mount out'
# ---------------------------------------------------------------------------

$noSid = New-InheritedLogDirectory -Path (Join-Path $Script:WorkRoot 'no-sid\logs\delta')
$noSidBefore = (Get-AclEntries -Path $noSid).Count

function Get-DeltaDockerFileReadSid { return $null }
$declined = Protect-DeltaLogDirectory -Path $noSid
Remove-Item -LiteralPath 'function:Get-DeltaDockerFileReadSid' -ErrorAction SilentlyContinue
. (Join-Path $Script:ProjectRoot 'lib\Delta.Config.ps1')

Assert-That  'nothing is applied when there is no account to grant' (-not $declined.Applied)
Assert-That  'and it says why' ($declined.Reason -match '(?i)docker desktop')
Assert-Equal 'the ACL is left exactly as it was' $noSidBefore (Get-AclEntries -Path $noSid).Count
Assert-That  'a path that is not a directory is refused' `
    (-not (Protect-DeltaLogDirectory -Path (Join-Path $Script:WorkRoot 'nothing-here')).Applied)

# ---------------------------------------------------------------------------
Start-TestCase 'New-DeltaInstallDirectories applies it to both, on every run'
# ---------------------------------------------------------------------------

$freshRoot = Join-Path $Script:WorkRoot 'fresh'
$first = New-DeltaInstallDirectories -InstallRoot $freshRoot
Assert-That "a fresh installation root is created: $($first.Reason)" $first.Succeeded
Assert-That 'logs\delta is hardened on the way through' $first.LogAcls['logs\delta'].Applied
Assert-That 'logs\nginx is hardened on the way through' $first.LogAcls['logs\nginx'].Applied

foreach ($relative in @('logs\delta', 'logs\nginx')) {
    $path = Join-Path $freshRoot $relative
    Assert-Equal "$relative has the expected three entries" 3 (Get-AclEntries -Path $path).Count
    Assert-That  "$relative has no BUILTIN\Users" `
        (@(Get-AclEntries -Path $path | Where-Object { $_.Principal -eq 'BUILTIN\Users' }).Count -eq 0)
}

# logs\installer is not a bind mount, so it is deliberately not given this
# policy - a directory no container touches does not need a container's rights.
Assert-That 'logs\installer is left with its inherited ACL' `
    (@(Get-AclEntries -Path (Join-Path $freshRoot 'logs\installer') | Where-Object { $_.Rights -match '\(I\)' }).Count -gt 0)

# A rerun on a live installation: real log files on disk, ACLs broken beneath.
$null = Write-DeltaInstallState -InstallRoot $freshRoot -Properties ([ordered]@{ state = 'installed'; installRoot = $freshRoot })
$liveDeltaLog = Join-Path $freshRoot 'logs\delta\dts-2026-01-01.log'
$liveNginxLog = Join-Path $freshRoot 'logs\nginx\access.log'
Set-Content -LiteralPath $liveDeltaLog -Value 'delta log content' -Encoding utf8
Set-Content -LiteralPath $liveNginxLog -Value 'nginx log content' -Encoding utf8
foreach ($relative in @('logs\delta', 'logs\nginx')) {
    $null = & icacls.exe @((Join-Path $freshRoot $relative), '/grant', 'BUILTIN\Users:(OI)(CI)(M)', '/C') 2>&1
}

$second = New-DeltaInstallDirectories -InstallRoot $freshRoot
Assert-That  "the rerun succeeds: $($second.Reason)" $second.Succeeded
Assert-Equal 'and creates nothing, because the layout is already there' 0 $second.Created.Count
foreach ($relative in @('logs\delta', 'logs\nginx')) {
    Assert-That "$relative is repaired again" ($second.Succeeded -and $second.LogAcls[$relative].Applied)
    Assert-That "$relative has no BUILTIN\Users after the rerun" `
        (@(Get-AclEntries -Path (Join-Path $freshRoot $relative) | Where-Object { $_.Principal -eq 'BUILTIN\Users' }).Count -eq 0)
}
Assert-Equal 'the DELTA log survived the rerun intact' 'delta log content' (Get-Content -LiteralPath $liveDeltaLog -Raw).Trim()
Assert-Equal 'the NGINX log survived the rerun intact' 'nginx log content' (Get-Content -LiteralPath $liveNginxLog -Raw).Trim()

# The uninstall archive walks logs\ elevated; Administrators must still read.
Assert-Equal 'and the backup walk still sees both' 2 `
    @(Get-ChildItem -LiteralPath (Join-Path $freshRoot 'logs') -Recurse -File -Force).Count

# ---------------------------------------------------------------------------
Start-TestCase 'The completed uploads and TLS ACLs are untouched'
# ---------------------------------------------------------------------------

Assert-That 'uploads still gets its own ACL from the same stage' $first.UploadsAcl.Applied
Assert-Equal 'and uploads is still three entries, not widened by this change' 3 `
    (Get-AclEntries -Path (Join-Path $freshRoot 'uploads')).Count
Assert-That 'certs is not given a log policy' `
    (@(Get-AclEntries -Path (Join-Path $freshRoot 'certs') | Where-Object { $_.Rights -match '\(I\)' }).Count -gt 0)
Assert-That 'and neither is backups' `
    (@(Get-AclEntries -Path (Join-Path $freshRoot 'backups') | Where-Object { $_.Rights -match '\(I\)' }).Count -gt 0)

# ---------------------------------------------------------------------------
Start-TestCase 'The shipped source says what it does'
# ---------------------------------------------------------------------------

$configText = Get-Content -LiteralPath (Join-Path $Script:ProjectRoot 'lib\Delta.Config.ps1') -Raw
Assert-That 'the log grant is Modify, not Full Control' `
    ($configText -match '(?s)function Protect-DeltaLogDirectory.*?\$\{dockerSid\}:\(OI\)\(CI\)\(M\)')
Assert-That 'and nothing in it takes ownership' `
    ($configText -notmatch '(?s)function Protect-DeltaLogDirectory.*?(takeown|SetOwner|/setowner)')

$stackText = Get-Content -LiteralPath (Join-Path $Script:ProjectRoot 'lib\Delta.Stack.ps1') -Raw
Assert-That 'both log directories are named at the call site' `
    ($stackText -match '''logs\\delta'',\s*''logs\\nginx''')
Assert-That 'and logs\installer is not given the container policy' `
    ($stackText -notmatch 'Protect-DeltaLogDirectory[^\r\n]*installer')

# ---------------------------------------------------------------------------
# Live
# ---------------------------------------------------------------------------

if ($Live) {

    $deltaPresent = (Invoke-DeltaDockerCommand -Arguments @('image', 'inspect', $LiveImage, '--format', '{{.Id}}') -TimeoutSeconds 120).ExitCode -eq 0
    $nginxPresent = (Invoke-DeltaDockerCommand -Arguments @('image', 'inspect', $LiveNginxImage, '--format', '{{.Id}}') -TimeoutSeconds 120).ExitCode -eq 0

    # -----------------------------------------------------------------------
    Start-TestCase 'Live: logs\delta through the image own winston transport'
    # -----------------------------------------------------------------------

    if (-not $deltaPresent) {
        Write-Host "    [skip] $LiveImage is not present locally, and this suite pulls nothing" -ForegroundColor DarkGray
    }
    else {
        # The probe builds the same DailyRotateFile transport the application
        # builds - zippedArchive, maxSize, maxFiles - with maxSize small enough
        # that size rotation and retention both fire inside one run.
        $probeJs = @'
const fs = require('fs');
const path = require('path');
const winston = require('/delta/node_modules/winston');
require('/delta/node_modules/winston-daily-rotate-file');
const D = '/delta/logs';
const out = [];
const t = (n, f) => { try { f(); out.push(n + '=OK'); } catch (e) { out.push(n + '=FAIL'); } };
t('traverse', () => fs.readdirSync(D));
t('mkdir',    () => fs.mkdirSync(path.join(D, 'probe-sub'), { recursive: true }));
t('create',   () => fs.writeFileSync(path.join(D, 'probe.log'), 'a\n'));
t('append',   () => fs.appendFileSync(path.join(D, 'probe.log'), 'b\n'));
t('read',     () => fs.readFileSync(path.join(D, 'probe.log')));
t('truncate', () => fs.writeFileSync(path.join(D, 'probe.log'), 'c\n'));
t('rename',   () => fs.renameSync(path.join(D, 'probe.log'), path.join(D, 'probe.log.1')));
t('delete',   () => fs.unlinkSync(path.join(D, 'probe.log.1')));
t('recreate', () => fs.writeFileSync(path.join(D, 'probe.log'), 'd\n'));
t('rmdir',    () => fs.rmSync(path.join(D, 'probe-sub'), { recursive: true, force: true }));
t('cleanup',  () => fs.unlinkSync(path.join(D, 'probe.log')));
let tr = null;
try {
  tr = new winston.transports.DailyRotateFile({
    filename: path.join(D, 'probe-dts-%DATE%.log'),
    datePattern: 'YYYY-MM-DD', zippedArchive: true, maxSize: '2k', maxFiles: '2'
  });
} catch (e) { out.push('transport=FAIL'); }
if (!tr) { console.log(out.join('\n')); }
else {
  const rotations = [];
  tr.on('rotate', (a, b) => rotations.push(path.basename(b)));
  const logger = winston.createLogger({ transports: [tr] });
  for (let i = 0; i < 400; i++) { logger.info('x'.repeat(80), { n: i }); }
  setTimeout(() => {
    const files = fs.readdirSync(D);
    out.push('winston_wrote=' + (files.some(f => f.startsWith('probe-dts-')) ? 'OK' : 'FAIL'));
    out.push('winston_audit=' + (files.some(f => f.includes('-audit.json')) ? 'OK' : 'FAIL'));
    out.push('winston_rotated=' + (rotations.length > 0 ? 'OK' : 'FAIL'));
    for (const f of files) {
      if (f.indexOf('probe') >= 0 || f.indexOf('-audit.json') >= 0) {
        try { fs.unlinkSync(path.join(D, f)); } catch (e) { /* counted below */ }
      }
    }
    const left = fs.readdirSync(D).filter(f => f.indexOf('probe') >= 0 || f.indexOf('-audit.json') >= 0);
    out.push('retention_cleanup=' + (left.length === 0 ? 'OK' : 'FAIL'));
    out.push('left_behind=' + left.length);
    console.log(out.join('\n'));
  }, 3000);
}
'@
        $probeDir = Join-Path $Script:WorkRoot 'probe'
        $null = New-Item -ItemType Directory -Path $probeDir -Force
        # LF only: a CR would reach node as part of the source.
        [System.IO.File]::WriteAllText((Join-Path $probeDir 'probe.js'), ($probeJs -replace "`r`n", "`n"))

        $liveDelta = New-InheritedLogDirectory -Path (Join-Path $Script:WorkRoot 'live\logs\delta') -LogName 'dts-2026-01-01.log'
        $existingDeltaLog = Join-Path $liveDelta 'dts-2026-01-01.log'
        $applied = Protect-DeltaLogDirectory -Path $liveDelta
        Assert-That 'the real ACL is applied to the live logs\delta' $applied.Applied

        $run = Invoke-DeltaDockerCommand -Arguments @(
            'run', '--rm', '--network', 'none',
            '-v', "${liveDelta}:/delta/logs", '-v', "${probeDir}:/probe:ro",
            '--entrypoint', 'node', $LiveImage, '/probe/probe.js') -TimeoutSeconds 300

        $out = ($run.StdOut + "`n" + $run.StdErr)
        Assert-Equal 'the probe container ran' 0 $run.ExitCode
        Assert-That  'and node did not die on an unhandled EACCES' ($out -notmatch 'EACCES')

        foreach ($op in @('traverse', 'mkdir', 'create', 'append', 'read', 'truncate', 'rename',
                          'delete', 'recreate', 'rmdir', 'cleanup',
                          'winston_wrote', 'winston_audit', 'winston_rotated', 'retention_cleanup')) {
            Assert-That "$op succeeds under the hardened ACL" ($out -match "(?m)^$op=OK")
        }

        Assert-That  'the log that was already there is still there' (Test-Path -LiteralPath $existingDeltaLog -PathType Leaf)
        Assert-Equal 'with its content untouched' 'existing log line' (Get-Content -LiteralPath $existingDeltaLog -Raw).Trim()

        Start-TestCase 'Live: the logs\delta ACLs that do NOT work'

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
            'Administrators + SYSTEM only'   = @{ Grants = @();                                          Expect = 'mount' }
            'the installing user with (RX,W)' = @{ Grants = @("*$Script:CurrentUserSid`:(OI)(CI)(RX,W)"); Expect = 'norotate' }
            'a Program Files style root'      = @{ Grants = @('BUILTIN\Users:(OI)(CI)(RX)');              Expect = 'eacces' }
        }

        foreach ($label in $negatives.Keys) {
            $negDir = Join-Path $Script:WorkRoot ('negd-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
            $null = New-Item -ItemType Directory -Path $negDir -Force
            Set-FilteredTokenModelAcl -Path $negDir -Grants $negatives[$label].Grants

            $neg = Invoke-DeltaDockerCommand -Arguments @(
                'run', '--rm', '--network', 'none',
                '-v', "${negDir}:/delta/logs", '-v', "${probeDir}:/probe:ro",
                '--entrypoint', 'node', $LiveImage, '/probe/probe.js') -TimeoutSeconds 300
            $negOut = ($neg.StdOut + "`n" + $neg.StdErr)

            switch ($negatives[$label].Expect) {
                'mount'    { Assert-That "logs\delta, $label - the bind mount itself is refused" `
                                 (($neg.ExitCode -ne 0) -and ($negOut -match '(?i)access is denied')) }
                'norotate' { Assert-That "logs\delta, $label - rename and delete fail, retention leaves files behind" `
                                 (($negOut -match '(?m)^rename=FAIL') -and ($negOut -match '(?m)^retention_cleanup=FAIL')) }
                'eacces'   { Assert-That "logs\delta, $label - the logger dies on EACCES" `
                                 ($negOut -match 'EACCES') }
            }
        }
    }

    # -----------------------------------------------------------------------
    Start-TestCase 'Live: logs\nginx through the real rotation function'
    # -----------------------------------------------------------------------

    if (-not $nginxPresent) {
        Write-Host "    [skip] $LiveNginxImage is not present locally, and this suite pulls nothing" -ForegroundColor DarkGray
    }
    else {
        $composeText = @"
services:
  nginx:
    image: $LiveNginxImage
    volumes:
      - ./logs/nginx:/var/log/nginx
"@
        function New-ProbeInstallation {
            param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Project)
            $logs = Join-Path $Root 'logs\nginx'
            $null = New-Item -ItemType Directory -Path $logs -Force
            Set-Content -LiteralPath (Join-Path $Root 'docker-compose.yml') -Value $composeText -Encoding ascii
            # Get-DeltaComposeArguments always passes --env-file.
            Set-Content -LiteralPath (Join-Path $Root '.env') -Value "COMPOSE_PROJECT_NAME=$Project" -Encoding ascii
            return $logs
        }

        $nginxRoot = Join-Path $Script:WorkRoot 'live-nginx'
        $project = 'deltalogtest'
        $nginxLogs = New-ProbeInstallation -Root $nginxRoot -Project $project

        # A log already on disk, written before the repair - the existing
        # installation whose rotation has never been able to work.
        foreach ($grant in $Script:RootDefaults) {
            $null = & icacls.exe @($nginxLogs, '/grant', $grant, '/C') 2>&1
        }
        Set-Content -LiteralPath (Join-Path $nginxLogs 'older.log') -Value 'kept across the repair' -Encoding utf8

        $nginxApplied = Protect-DeltaLogDirectory -Path $nginxLogs
        Assert-That 'the real ACL is applied to the live logs\nginx' $nginxApplied.Applied

        try {
            $up = Invoke-DeltaCompose -InstallRoot $nginxRoot -ProjectName $project -Arguments @('up', '-d', 'nginx') -TimeoutSeconds 180
            Assert-Equal 'NGINX starts against the hardened log directory' 0 $up.ExitCode

            if ($up.ExitCode -eq 0) {
                Start-Sleep -Seconds 3
                $logs = Invoke-DeltaCompose -InstallRoot $nginxRoot -ProjectName $project -Arguments @('logs', '--no-color', 'nginx') -TimeoutSeconds 60
                Assert-That 'and reports no permission alert on its error log' `
                    (($logs.StdOut + $logs.StdErr) -notmatch '(?i)could not open error log file')
                Assert-That 'the error log is open on the host' `
                    (Test-Path -LiteralPath (Join-Path $nginxLogs 'error.log') -PathType Leaf)

                for ($r = 0; $r -lt 3; $r++) {
                    $null = Invoke-DeltaCompose -InstallRoot $nginxRoot -ProjectName $project `
                        -Arguments @('exec', '-T', 'nginx', 'wget', '-qO-', 'http://127.0.0.1/') -TimeoutSeconds 60
                }
                Start-Sleep -Seconds 1

                $accessPath = Join-Path $nginxLogs 'access.log'
                Assert-That 'requests reach the access log' `
                    ((Test-Path -LiteralPath $accessPath -PathType Leaf) -and (Get-Item -LiteralPath $accessPath).Length -gt 0)

                # Four cycles retaining two, so retention has to delete.
                $cfg = [PSCustomObject]@{ ProjectName = $project }
                $rotations = New-Object 'System.Collections.Generic.List[object]'
                for ($n = 1; $n -le 4; $n++) {
                    $rot = Invoke-DeltaNginxLogRotation -InstallRoot $nginxRoot -Configuration $cfg -Retain 2
                    $null = $rotations.Add($rot)
                    $null = Invoke-DeltaCompose -InstallRoot $nginxRoot -ProjectName $project `
                        -Arguments @('exec', '-T', 'nginx', 'wget', '-qO-', 'http://127.0.0.1/') -TimeoutSeconds 60
                    Start-Sleep -Milliseconds 800
                }

                Assert-Equal 'all four rotations succeed' 4 @($rotations | Where-Object { $_.Succeeded }).Count
                Assert-Equal 'all four actually rotated'  4 @($rotations | Where-Object { $_.Rotated }).Count
                Assert-Equal 'and NGINX reopened each time' 4 @($rotations | Where-Object { $_.Reopened }).Count
                Assert-That  'no rotation reported a rename refusal' `
                    (@($rotations | Where-Object { $_.Reason -match '(?i)permission denied' }).Count -eq 0)

                foreach ($rot in $rotations) {
                    if ($rot.RotatedTo) {
                        Assert-That "the replacement file was created for $(Split-Path -Leaf $rot.RotatedTo)" `
                            (Test-Path -LiteralPath $accessPath -PathType Leaf)
                        break
                    }
                }

                $removed = @($rotations | ForEach-Object { $_.Removed } | Where-Object { $_ })
                Assert-That 'retention deleted the rotations beyond the newest two' ($removed.Count -ge 1)
                Assert-Equal 'and exactly two rotations are on disk' 2 `
                    @(Get-ChildItem -LiteralPath $nginxLogs -File -Force |
                        Where-Object { $_.Name -like 'access.log.*' }).Count

                $null = Invoke-DeltaCompose -InstallRoot $nginxRoot -ProjectName $project `
                    -Arguments @('exec', '-T', 'nginx', 'wget', '-qO-', 'http://127.0.0.1/') -TimeoutSeconds 60
                Start-Sleep -Milliseconds 800
                Assert-That 'NGINX is still logging after the last reopen' `
                    ((Get-Item -LiteralPath $accessPath).Length -gt 0)

                Assert-Equal 'the log that predates the repair is intact' 'kept across the repair' `
                    (Get-Content -LiteralPath (Join-Path $nginxLogs 'older.log') -Raw).Trim()

                $freshAcl = Get-AclEntries -Path $accessPath
                Assert-That 'and the access log NGINX created carries no broad principal' `
                    (@($freshAcl | Where-Object { $Script:BroadPrincipals -contains $_.Principal }).Count -eq 0)
                Assert-That 'while the account that has to rotate it holds Modify' `
                    (@($freshAcl | Where-Object { $_.Principal -eq $Script:CurrentUserName -and $_.Rights -match 'M' }).Count -ge 1)
            }
        }
        finally {
            $null = Invoke-DeltaCompose -InstallRoot $nginxRoot -ProjectName $project -Arguments @('down', '-t', '3') -TimeoutSeconds 120
        }

        Start-TestCase 'Live: the logs\nginx ACLs that do NOT work'

        $nginxNegatives = [ordered]@{
            'Administrators + SYSTEM only'    = @{ Grants = @();                                          Expect = 'nostart' }
            'the installing user with (RX,W)' = @{ Grants = @("*$Script:CurrentUserSid`:(OI)(CI)(RX,W)"); Expect = 'norotate' }
            'a Program Files style root'      = @{ Grants = @('BUILTIN\Users:(OI)(CI)(RX)');              Expect = 'noerrorlog' }
        }

        $n = 0
        foreach ($label in $nginxNegatives.Keys) {
            $n++
            $negRoot = Join-Path $Script:WorkRoot "neg-nginx-$n"
            $negProject = "deltalogneg$n"
            $negLogs = New-ProbeInstallation -Root $negRoot -Project $negProject
            Set-FilteredTokenModelAcl -Path $negLogs -Grants $nginxNegatives[$label].Grants

            try {
                $negUp = Invoke-DeltaCompose -InstallRoot $negRoot -ProjectName $negProject -Arguments @('up', '-d', 'nginx') -TimeoutSeconds 180

                switch ($nginxNegatives[$label].Expect) {
                    'nostart' {
                        Assert-That "logs\nginx, $label - the container cannot even be created" `
                            (($negUp.ExitCode -ne 0) -and (($negUp.StdErr + $negUp.StdOut) -match '(?i)access is denied'))
                    }
                    'noerrorlog' {
                        Start-Sleep -Seconds 3
                        $negLogsOut = Invoke-DeltaCompose -InstallRoot $negRoot -ProjectName $negProject -Arguments @('logs', '--no-color', 'nginx') -TimeoutSeconds 60
                        Assert-That "logs\nginx, $label - NGINX refuses to open its error log" `
                            (($negLogsOut.StdOut + $negLogsOut.StdErr) -match '(?i)could not open error log file')
                    }
                    'norotate' {
                        Start-Sleep -Seconds 3
                        for ($r = 0; $r -lt 3; $r++) {
                            $null = Invoke-DeltaCompose -InstallRoot $negRoot -ProjectName $negProject `
                                -Arguments @('exec', '-T', 'nginx', 'wget', '-qO-', 'http://127.0.0.1/') -TimeoutSeconds 60
                        }
                        Start-Sleep -Seconds 1
                        $negRot = Invoke-DeltaNginxLogRotation -InstallRoot $negRoot `
                            -Configuration ([PSCustomObject]@{ ProjectName = $negProject }) -Retain 2
                        Assert-That "logs\nginx, $label - NGINX logs but rotation is refused" `
                            ((-not $negRot.Succeeded) -and ($negRot.Reason -match "(?i)can't rename|permission denied"))
                    }
                }
            }
            finally {
                $null = Invoke-DeltaCompose -InstallRoot $negRoot -ProjectName $negProject -Arguments @('down', '-t', '3') -TimeoutSeconds 120
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
    Write-Host '  log mounts and the real rotation cycle against the real engine.'
    Write-Host ''
}

exit $(if ($Script:Failed -gt 0) { 1 } else { 0 })
