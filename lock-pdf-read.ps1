# lock-pdf-read.ps1
# Freezes the pdf-viewer extension directory so an extension update cannot complete over the wrapper and
# silently turn local PDF read access off. Reversible: -Unlock restores the exact original state.
#
#   lock-pdf-read.ps1            apply the freeze
#   lock-pdf-read.ps1 -Status    report the EFFECTIVE state, change nothing
#   lock-pdf-read.ps1 -Fix       check it really holds, and repair it if it does not
#   lock-pdf-read.ps1 -Unlock    remove it (before an update, or to let the app update)
#   -Dist <folder>               with any of the above: the pdf-viewer dist whose extension to act on.
#                                Without it: PDF_VIEWER_DIST, then the app's extension folder
#                                (README - "Finding the extension").
#
# ---------------------------------------------------------------------------------------------------
# WHY -Fix EXISTS, AND WHY IT DOES NOT JUST RE-RUN THE FREEZE
#   Checking "is there a deny-ACE on the root?" is a STRUCTURAL check, and it can LIE: if inheritance
#   were ever broken on a child, the root ACE would still be sitting there while the wrapper sat wide
#   open. So -Status and -Fix do not ask what the ACL SAYS, they probe what is EFFECTIVELY true - can
#   this file actually be read, written, deleted right now - and -Fix repairs from that diagnosis.
#   The probes are non-destructive (verified 2026-07-16): write-access is tested by opening for write
#   and closing; delete-access by opening a handle that REQUESTS the Delete right without ever deleting
#   (FileOptions.None, so no delete-on-close). Both leave the file byte-identical.
#
# WHY IT REFUSES WHEN THE WRAPPER IS ABSENT
#   If an update already wiped the wrapper, index.js is the stock (broken) server. Freezing THAT would
#   lock in the bug permanently and there would be nothing left to protect. So a freeze is only applied
#   when the wrapper is actually present.
#
# WHY IT REFUSES AN INCOMPLETE FOLDER
#   Freezing a folder that is missing the extension's own files locks the break in place (it has happened:
#   an updater's failed rollback left a gutted folder, which was then frozen). -Status and -Unlock still run
#   on one: -Status only reads, and thawing is what lets the folder be replaced (README - "An incomplete
#   extension folder").
#
# ---------------------------------------------------------------------------------------------------
# WHY THE MASKS ARE EXACTLY THESE (every line measured 2026-07-16, not assumed - do not "simplify")
#
# 1. A file can be deleted via DELETE on the file OR via FILE_DELETE_CHILD on its PARENT directory.
#    Denying delete on index.js alone is defeated by its own parent, which grants DC. Measured: parent
#    grants DC + file denies DE -> file deleted anyway. BOTH denials are required.
#
# 2. The right-letter matters. Inside parentheses icacls wants SPECIFIC rights, where delete is DE.
#    Passing D there gets mangled into a mask that DENIES READ - which would brick the extension,
#    because the app's node host must read index.js to import it. Measured: (D,WD,AD) -> CanRead False.
#    (DE,WD,AD) -> CanRead True, writes blocked. Never use D here.
#
# 3. Files and directories need DIFFERENT masks. Directories get (DE,DC) only. They must NOT get WD/AD,
#    because on a directory those mean "add file" / "add subdirectory" - denying them would stop the app
#    creating legitimate new files. Measured: with this split, "app can still add new files" stays True.
#
# 4. Protecting only index.js is not enough, for two measured reasons:
#      a. SKEW. index.real.js is OUR file; it is not in Anthropic's package, so an updater never
#         replaces it. It imports ./server.js (index.real.js line 34306). Protect only index.js and an
#         update rewrites server.js to the new version while index.real.js stays old -> the wrapper
#         imports a NEW server.js and runs an OLD real server. (The app's own updater swaps whole
#         folders, so it cannot cause skew; b still applies.)
#      b. PARTIAL GUTTING. A failed recursive removal destroys whatever it reaches before hitting the
#         protected file. Measured: 7 files -> 6, one destroyed. That leaves the extension BROKEN, which
#         is strictly worse than the wipe being prevented. Freezing the whole tree makes it impossible:
#         measured 6 files -> 6, nothing destroyed.
#
# 5. Inheritable ACEs set once on the root cover the whole tree in ~1.2s. Per-file icacls on the
#    thousands of files under node_modules would take minutes.
#
# 6. The undo is exact. Baseline was verified to hold ZERO explicit ACEs across the tree with
#    inheritance enabled, so /remove:d leaves 0 explicit ACEs behind - measured. And you own these
#    files, so WRITE_DAC is implicit: this lock can never lock you out of your own machine.
#
# THE COST, STATED PLAINLY: while frozen, the app CANNOT complete an update of pdf-viewer. Its automatic
# updater swaps whole folders: it renames this one aside, moves the new version in, then deletes the old
# one; the Update button in Settings > Extensions deletes the old folder and moves the new one in. The
# freeze cannot stop the renames; it stops the deletes, so each attempt fails, and a rollback that itself
# fails can leave the extension gutted. The app's switch "Enable auto-updates for extensions" (Settings >
# Extensions > Advanced settings) stops the automatic attempts. To take an update: -Unlock, update
# pdf-viewer with its Update button, close the app, install-pdf-read.ps1, then lock again.
#
# Pure ASCII (PowerShell 5.1 reads .ps1 as Windows-1252; a non-ASCII char breaks parsing).

param(
    [switch]$Unlock,
    [switch]$Status,
    [switch]$Fix,
    [string]$Dist
)

$ErrorActionPreference = 'Stop'
$me  = "$env:USERDOMAIN\$env:USERNAME"
$SIG = 'PDF-LOCAL-READ-WRAPPER'

# The dist is resolved the same way in every toolkit script and in check-schema-dialect.mjs; change them together.
$distOverride = $PSBoundParameters.ContainsKey('Dist')
if ($distOverride -and [string]::IsNullOrWhiteSpace($Dist)) {
    Write-Host "-Dist needs a folder. Nothing changed." -ForegroundColor Red
    return
}
$distCandidates = @()
if ($distOverride) { $distFrom = '-Dist'; $distCandidates = @($Dist) }
elseif (-not [string]::IsNullOrWhiteSpace($env:PDF_VIEWER_DIST)) { $distOverride = $true; $distFrom = 'PDF_VIEWER_DIST'; $distCandidates = @($env:PDF_VIEWER_DIST) }
else {
    $distFrom = "the app's extension folder"
    $distRel  = 'Claude\Claude Extensions\ant.dir.gh.anthropic.pdf-server-mcp\dist'
    # Claude_pzs8sxrjxfjjc is the app's MSIX package family name: set by its publisher, the same on every machine.
    if ($env:LOCALAPPDATA) { $distCandidates += Join-Path $env:LOCALAPPDATA "Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\$distRel" }
    if ($env:APPDATA)      { $distCandidates += Join-Path $env:APPDATA $distRel }
}
$distCandidates = @($distCandidates | ForEach-Object {
    $cand = $_
    try { $cand = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($cand) } catch {}
    if ($cand.Length -gt 3) { $cand.TrimEnd('\', '/') } else { $cand }
})

# The extension's own files: what the app or the server's own code cannot start without. The same list in
# install, uninstall, verify and lock; change them together (README - "An incomplete extension folder").
$OWN_FILES = @('manifest.json', 'dist\server.js', 'dist\mcp-app.html', 'dist\pdfjs-polyfill.js', 'node_modules\pdfjs-dist\legacy\build\pdf.mjs')
function Get-MissingOwnFiles([string]$Ext) { return @($OWN_FILES | Where-Object { -not (Test-Path -LiteralPath (Join-Path $Ext $_) -PathType Leaf) }) }

$distDir = $null
# A string, not Join-Path, which throws on a missing drive; Test-Path throws on illegal characters. Either way: not found.
foreach ($c in $distCandidates) { try { if (Test-Path -LiteralPath "$c\index.js" -ErrorAction Stop) { $distDir = $c; break } } catch {} }
if (-not $distDir) {
    Write-Host "Could not find the pdf-viewer extension's dist\index.js via $distFrom. Nothing changed." -ForegroundColor Red
    $distCandidates | ForEach-Object { Write-Host "    tried: $_" -ForegroundColor DarkGray }
    if (-not $distCandidates) { Write-Host "    tried: nothing - LOCALAPPDATA and APPDATA are both unset" -ForegroundColor DarkGray }
    return
}
# The freeze covers the whole folder above the dist, so a location given by hand must be an extension's dist.
if ($distOverride -and -not (Test-Path -LiteralPath (Join-Path (Split-Path $distDir -Parent) 'manifest.json'))) {
    Write-Host "Refusing $distDir (from $distFrom): the folder above it has no manifest.json, so it is not the pdf-viewer extension. Nothing changed." -ForegroundColor Red
    return
}
$ext = Split-Path $distDir -Parent
$missing = @(Get-MissingOwnFiles $ext)

# ---------------------------------------------------------------------------------------------------
# probes - all non-destructive
# ---------------------------------------------------------------------------------------------------
function Test-RootDeny {
    param([string]$Root)
    try {
        $acl = Get-Acl -LiteralPath $Root
        foreach ($a in $acl.Access) {
            if ((-not $a.IsInherited) -and $a.AccessControlType -eq 'Deny' -and $a.IdentityReference.Value -eq $me) { return $true }
        }
    } catch {}
    return $false
}

function Get-Probe {
    param([string]$Path, [string]$Label)
    $exists = Test-Path -LiteralPath $Path
    if (-not $exists) { return [pscustomobject]@{ Name=$Label; Exists=$false; CanRead=$false; CanWrite=$false; CanDelete=$false } }

    $canRead = $false
    try { $null = [System.IO.File]::ReadAllBytes($Path); $canRead = $true } catch {}

    $canWrite = $false
    try { $fs = [System.IO.File]::Open($Path, 'Open', 'Write', 'ReadWrite'); $fs.Close(); $canWrite = $true } catch {}

    # ask for the Delete right WITHOUT deleting: no FileOptions.DeleteOnClose, so closing deletes nothing
    $canDelete = $false
    try {
        $fs = New-Object System.IO.FileStream($Path,
            [System.IO.FileMode]::Open,
            [System.Security.AccessControl.FileSystemRights]::Delete,
            [System.IO.FileShare]::ReadWrite,
            4096,
            [System.IO.FileOptions]::None)
        $fs.Close(); $fs.Dispose(); $canDelete = $true
    } catch {}

    return [pscustomobject]@{ Name=$Label; Exists=$true; CanRead=$canRead; CanWrite=$canWrite; CanDelete=$canDelete }
}

function Get-FreezeState {
    # Returns: NOWRAPPER | BRICKED | FROZEN | THAWED | PARTIAL   plus the probe rows.
    $probes = @(
        (Get-Probe -Path (Join-Path $distDir 'index.js')      -Label 'dist\index.js'),
        (Get-Probe -Path (Join-Path $distDir 'index.real.js') -Label 'dist\index.real.js'),
        (Get-Probe -Path (Join-Path $distDir 'server.js')     -Label 'dist\server.js')
    )
    $live = @($probes | Where-Object { $_.Exists })

    $idx = $probes | Where-Object { $_.Name -eq 'dist\index.js' }
    $wrapperPresent = $false
    if ($idx.CanRead) {
        try { $wrapperPresent = ([System.IO.File]::ReadAllText((Join-Path $distDir 'index.js')) -match $SIG) } catch {}
    }

    $state = 'PARTIAL'
    if (-not $idx.CanRead) {
        $state = 'BRICKED'                                  # node cannot read the entry point
    } elseif (-not $wrapperPresent) {
        $state = 'NOWRAPPER'                                # stock server sitting there; nothing to protect
    } else {
        $protected  = @($live | Where-Object { -not $_.CanWrite -and -not $_.CanDelete }).Count
        $exposed    = @($live | Where-Object { $_.CanWrite -or $_.CanDelete }).Count
        if ($exposed -eq 0)        { $state = 'FROZEN' }
        elseif ($protected -eq 0)  { $state = 'THAWED' }
        else                       { $state = 'PARTIAL' }
    }
    return [pscustomobject]@{ State=$state; Probes=$probes; RootDeny=(Test-RootDeny -Root $ext); WrapperPresent=$wrapperPresent }
}

function Show-Report {
    param($S)
    Write-Host "Extension  : $ext  (from $distFrom)" -ForegroundColor DarkGray
    Write-Host "Wrapper    : $(if ($S.WrapperPresent) { 'present' } else { 'NOT PRESENT' })" -ForegroundColor $(if ($S.WrapperPresent) { 'DarkGray' } else { 'Red' })
    Write-Host "Own files  : $(if ($missing.Count -eq 0) { 'complete' } else { 'MISSING ' + ($missing -join ', ') })" -ForegroundColor $(if ($missing.Count -eq 0) { 'DarkGray' } else { 'Red' })
    Write-Host "Root ACE   : $(if ($S.RootDeny) { 'deny present' } else { 'none' })" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "Effective state of the files that matter (probed, not read off the ACL):" -ForegroundColor DarkGray
    $S.Probes | ForEach-Object {
        if (-not $_.Exists) { Write-Host ("  {0,-22} (absent)" -f $_.Name) -ForegroundColor DarkGray; return }
        $ok = $_.CanRead -and -not $_.CanWrite -and -not $_.CanDelete
        Write-Host ("  {0,-22} read={1,-5} writable={2,-5} deletable={3,-5} {4}" -f `
            $_.Name, $_.CanRead, $_.CanWrite, $_.CanDelete, $(if ($ok) { 'protected' } else { '<-- exposed' })) `
            -ForegroundColor $(if ($ok) { 'Green' } else { 'Yellow' })
    }
    Write-Host ""
    switch ($S.State) {
        'FROZEN'    { Write-Host "STATE: FROZEN - an update cannot complete over the wrapper." -ForegroundColor Green }
        'THAWED'    { Write-Host "STATE: THAWED - the next pdf-viewer update WILL silently wipe the wrapper." -ForegroundColor Yellow }
        'PARTIAL'   { Write-Host "STATE: PARTIAL - some files protected, some exposed. The freeze is not holding." -ForegroundColor Red }
        'BRICKED'   { Write-Host "STATE: BRICKED - index.js is NOT READABLE. The extension cannot load at all." -ForegroundColor Red }
        'NOWRAPPER' { Write-Host "STATE: NO WRAPPER - index.js is the stock server. PDF read access is OFF." -ForegroundColor Red }
    }
}

function Remove-Freeze {
    icacls "$ext" /remove:d "$me" /T /C /Q 2>&1 | Out-Null
}

function Apply-Freeze {
    # Applies, then PROVES it holds. Auto-thaws if it does not verify, so nothing is left half-locked.
    $sw = [Diagnostics.Stopwatch]::StartNew()
    icacls "$ext" /deny "${me}:(OI)(IO)(DE,WD,AD)" /C /Q 2>&1 | Out-Null   # every FILE in the tree
    icacls "$ext" /deny "${me}:(CI)(IO)(DE,DC)"    /C /Q 2>&1 | Out-Null   # every SUBDIRECTORY
    icacls "$ext" /deny "${me}:(DE,DC)"            /C /Q 2>&1 | Out-Null   # the root directory itself
    $sw.Stop()

    $after = Get-FreezeState
    if ($after.State -eq 'FROZEN') {
        Write-Host "FROZEN in $($sw.ElapsedMilliseconds) ms - verified by probe." -ForegroundColor Green
        return $true
    }
    Write-Host "The freeze did NOT verify (state: $($after.State)). Thawing so nothing is left half-locked." -ForegroundColor Red
    Remove-Freeze
    Show-Report (Get-FreezeState)
    return $false
}

# ---------------------------------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------------------------------
$S = Get-FreezeState

if ($Status) { Show-Report $S; return }

if ($Unlock) {
    Show-Report $S
    if (-not $S.RootDeny) { Write-Host "`nAlready thawed. Nothing to do." -ForegroundColor DarkGray; return }
    Remove-Freeze
    $after = Get-FreezeState
    if ($after.RootDeny) { Write-Host "`nTHAW FAILED - the deny ACE is still present." -ForegroundColor Red; return }
    Write-Host "`nTHAWED. index.js writable again: $(($after.Probes | Where-Object { $_.Name -eq 'dist\index.js' }).CanWrite)" -ForegroundColor Green
    Write-Host "The app can now update pdf-viewer (its Update button in Settings > Extensions), which removes the wrapper: after the update, close the app, run install-pdf-read.ps1, then lock again." -ForegroundColor DarkGray
    return
}

if ($missing.Count -gt 0) {
    Show-Report $S
    Write-Host ""
    Write-Host "Refusing: the extension folder is missing files of its own ($($missing -join ', ')). Freezing it would lock the break in place. Replace the folder with an intact copy first (README - `"An incomplete extension folder`"); -Unlock still works on it. Nothing changed." -ForegroundColor Red
    return
}

if ($Fix) {
    Show-Report $S
    Write-Host ""
    switch ($S.State) {
        'FROZEN' {
            Write-Host "Nothing to fix - the freeze is holding." -ForegroundColor Green
            return
        }
        'BRICKED' {
            Write-Host "EMERGENCY: index.js cannot be read, so the extension cannot load. Thawing now." -ForegroundColor Red
            Remove-Freeze
            $a = Get-FreezeState
            if ($a.Probes[0].CanRead) {
                Write-Host "Thawed - index.js is readable again." -ForegroundColor Green
                Write-Host "Re-applying the freeze correctly..." -ForegroundColor Cyan
                $null = Apply-Freeze
            } else {
                Write-Host "Still unreadable after thawing - this is NOT the freeze. Do not re-lock." -ForegroundColor Red
                Write-Host "Repair the pdf-viewer extension in the app, then run install-pdf-read.ps1." -ForegroundColor Red
            }
            return
        }
        'NOWRAPPER' {
            Write-Host "Refusing to freeze: index.js is the stock server, not our wrapper." -ForegroundColor Red
            Write-Host "Freezing now would lock in the broken server permanently and protect nothing." -ForegroundColor Red
            Write-Host "Close the Claude app and run install-pdf-read.ps1 first, then lock." -ForegroundColor Cyan
            return
        }
        default {
            # THAWED or PARTIAL -> full thaw, then re-apply cleanly (never layer onto a half-state)
            Write-Host "Repairing: full thaw, then re-apply the freeze cleanly." -ForegroundColor Cyan
            Remove-Freeze
            $null = Apply-Freeze
            return
        }
    }
}

# ---- plain run: apply the freeze ----
if ($S.State -eq 'NOWRAPPER') {
    Show-Report $S
    Write-Host ""
    Write-Host "Refusing to freeze: index.js is the stock server, not our wrapper." -ForegroundColor Red
    Write-Host "Freezing now would lock in the broken server permanently. Run install-pdf-read.ps1 first." -ForegroundColor Cyan
    return
}
if ($S.State -eq 'BRICKED') {
    Show-Report $S
    Write-Host ""
    Write-Host "Refusing to freeze: index.js is not readable, so the extension is already broken." -ForegroundColor Red
    Write-Host "Run this with -Fix to recover." -ForegroundColor Cyan
    return
}
if ($S.State -eq 'FROZEN') {
    Show-Report $S
    Write-Host ""
    Write-Host "Already frozen and verified holding. Nothing to do." -ForegroundColor DarkGray
    return
}

Write-Host "Extension : $ext  (from $distFrom)" -ForegroundColor DarkGray
Write-Host "State     : $($S.State)" -ForegroundColor Yellow
Write-Host ""
if (Apply-Freeze) {
    Write-Host ""
    Write-Host "The wrapper is now protected: an extension update cannot complete while the freeze holds." -ForegroundColor Green
    Write-Host "Cost: the app cannot update pdf-viewer while frozen. To take an update:" -ForegroundColor DarkGray
    Write-Host "  lock-pdf-read.ps1 -Unlock  ->  update pdf-viewer in Settings > Extensions  ->  close the app  ->  install-pdf-read.ps1  ->  lock-pdf-read.ps1" -ForegroundColor DarkGray
}
