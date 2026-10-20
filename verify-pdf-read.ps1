# Copyright (C) 2026 tzipora-rose
#
# This file is part of pdf-local-read.
#
# pdf-local-read is free software: you can redistribute it and/or modify it under the
# terms of the GNU Affero General Public License, version 3, as published by
# the Free Software Foundation.
#
# pdf-local-read is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE. See the GNU Affero General Public License for
# more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with pdf-local-read. If not, see <https://www.gnu.org/licenses/>.
#
# SPDX-License-Identifier: AGPL-3.0-only

# verify-pdf-read.ps1
# Reports whether the local-PDF-read wrapper is installed and HEALTHY - loudly, so a silent wipe by an extension
# update cannot go unnoticed. Read-only by default.
#   -Fix   : if it is not healthy, run the installer to (re)install (needs the app closed).
#   -Dist <folder> : the pdf-viewer dist folder to check. Without it: PDF_VIEWER_DIST, then the app's
#                    extension folder (README - "Finding the extension").
#
# States it distinguishes:
#   HEALTHY   - wrapper in index.js, real server preserved in index.real.js. PDF read access is ON.
#   OFF       - clean original extension, wrapper not installed. Read access is OFF (expected if never
#               installed, and what the app leaves after an update: it puts in a whole new folder).
#   WIPED     - index.js is a stock server again but index.real.js is still there: something replaced
#               the wrapper alone. Read access is OFF and there is a stale orphan. Run with -Fix.
#   HALF      - wrapper present but the real server (index.real.js) is missing. Needs extension repair.
#   INCOMPLETE - the extension folder is missing files of its own (README - "An incomplete extension
#               folder"). The app cannot run it and no script here can repair it; -Fix does nothing.
#
# It also reports whether the installed wrapper is this toolkit's current pdf-stdio-wrap.js and is linked to this
# toolkit (dist\pdf-local-read.json), the folders the link grants, each patch of patches.ps1 (PATCHED / NOT PATCHED /
# NOT NEEDED / UNKNOWN PATTERN), and the verdict of check-schema-dialect.mjs, which asks the installed server for its
# tool list and tests every output schema against the gate Claude Code applies before it will call a tool.

[CmdletBinding(PositionalBinding = $false)]
param([switch]$Fix, [string]$Dist)

$SIG = 'PDF-LOCAL-READ-WRAPPER'
if (-not $PSScriptRoot) {
    Write-Host "Run this as a script file: the toolkit folder is found from the script's own location." -ForegroundColor Red
    return
}
. (Join-Path $PSScriptRoot 'patches.ps1')

# The dist is resolved the same way in every toolkit script and in check-schema-dialect.mjs; change them together.
$distOverride = $PSBoundParameters.ContainsKey('Dist')
if ($distOverride -and [string]::IsNullOrWhiteSpace($Dist)) {
    Write-Host "-Dist needs a folder." -ForegroundColor Red
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
    Write-Host "STATE: NO EXTENSION - could not find pdf-viewer's dist\index.js via $distFrom." -ForegroundColor Red
    $distCandidates | ForEach-Object { Write-Host "    tried: $_" -ForegroundColor DarkGray }
    if (-not $distCandidates) { Write-Host "    tried: nothing - LOCALAPPDATA and APPDATA are both unset" -ForegroundColor DarkGray }
    return
}
if ($distOverride -and -not (Test-Path -LiteralPath (Join-Path (Split-Path $distDir -Parent) 'manifest.json'))) {
    Write-Host "STATE: NOT AN EXTENSION - $distDir (from $distFrom): the folder above it has no manifest.json, so it is not the pdf-viewer extension." -ForegroundColor Red
    return
}
$passDist = @{}
if ($PSBoundParameters.ContainsKey('Dist')) { $passDist['Dist'] = $distDir }

$idx  = Join-Path $distDir 'index.js'
$real = Join-Path $distDir 'index.real.js'
$idxIsWrapper = Select-String -LiteralPath $idx -Pattern $SIG -Quiet
$realExists   = Test-Path -LiteralPath $real

# extension version, for context (an update is what removes the wrapper)
$ver = '(unknown)'
$manifest = Join-Path $distDir '..\manifest.json'
if (Test-Path -LiteralPath $manifest) {
    try { $ver = (Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json).version } catch {}
}
Write-Host "Extension dist : $distDir  (from $distFrom)" -ForegroundColor DarkGray
Write-Host "Extension ver  : $ver" -ForegroundColor DarkGray
$missing = @(Get-MissingOwnFiles (Split-Path $distDir -Parent))
if ($missing.Count -eq 0) { Write-Host "Extension files: complete" -ForegroundColor DarkGray }
else { Write-Host "Extension files: MISSING $($missing -join ', ')" -ForegroundColor Red }

# Freeze state (lock-pdf-read.ps1). FROZEN means an extension update cannot complete over the wrapper.
# Reported here because a protection you cannot see is a protection you cannot trust.
$ext = Split-Path $distDir -Parent
$me  = "$env:USERDOMAIN\$env:USERNAME"
$frozen = $false
try {
    $acl = Get-Acl -LiteralPath $ext
    foreach ($a in $acl.Access) {
        if ((-not $a.IsInherited) -and $a.AccessControlType -eq 'Deny' -and $a.IdentityReference.Value -eq $me) { $frozen = $true }
    }
} catch {}
Write-Host "Update freeze  : $(if ($frozen) { 'FROZEN (an update cannot complete over the wrapper)' } else { 'THAWED (an update WILL silently remove the wrapper)' })" -ForegroundColor $(if ($frozen) { 'Green' } else { 'Yellow' })

# The installed wrapper is a copy, and only uninstall then install replaces it, so a changed pdf-stdio-wrap.js
# shows here. The link tells the wrapper where this toolkit is (its DIAG flag and log folder) and what to grant.
if ($idxIsWrapper) {
    $srcWrap = Join-Path $PSScriptRoot 'pdf-stdio-wrap.js'
    $wrapState = 'UNKNOWN'
    if (-not (Test-Path -LiteralPath $srcWrap)) {
        Write-Host "Wrapper code   : UNKNOWN - pdf-stdio-wrap.js is missing from $PSScriptRoot" -ForegroundColor Yellow
    } elseif ((Get-FileHash -LiteralPath $idx -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $srcWrap -Algorithm SHA256).Hash) {
        $wrapState = 'CURRENT'
        Write-Host "Wrapper code   : CURRENT (identical to this toolkit's pdf-stdio-wrap.js)" -ForegroundColor Green
    } else {
        $wrapState = 'OUTDATED'
        Write-Host "Wrapper code   : OUTDATED - differs from this toolkit's pdf-stdio-wrap.js. To refresh it, with the app closed: uninstall-pdf-read.ps1, install-pdf-read.ps1, then lock-pdf-read.ps1." -ForegroundColor Yellow
    }
    $linkFix = if ($wrapState -eq 'OUTDATED') { 'The refresh above sets it.' } else { 'Run install-pdf-read.ps1 (app closed) to set it.' }
    $link = Join-Path $distDir 'pdf-local-read.json'
    $linkToolkit = $null; $linkDirs = $null
    if (Test-Path -LiteralPath $link) { try { $lj = Get-Content -LiteralPath $link -Raw -Encoding UTF8 | ConvertFrom-Json; $linkToolkit = $lj.toolkit; if ($lj.PSObject.Properties['directories']) { $linkDirs = @($lj.directories) } } catch {} }
    if (-not (Test-Path -LiteralPath $link)) {
        Write-Host "Toolkit link   : MISSING (dist\pdf-local-read.json) - the wrapper finds its DIAG flag, log folder and granted folders through it. $linkFix" -ForegroundColor Yellow
    } elseif (-not ($linkToolkit -is [string]) -or -not $linkToolkit) {
        Write-Host "Toolkit link   : UNREADABLE - $link names no toolkit folder. $linkFix" -ForegroundColor Yellow
    } elseif ($linkToolkit -ieq $PSScriptRoot) {
        Write-Host "Toolkit link   : $linkToolkit (this toolkit)" -ForegroundColor Green
    } else {
        $where = if (Test-Path -LiteralPath $linkToolkit) { 'another toolkit folder' } else { 'a folder that does not exist' }
        Write-Host "Toolkit link   : points at $linkToolkit, $where, not this toolkit. $linkFix" -ForegroundColor Yellow
    }
    if (Test-Path -LiteralPath $link) {
        if ($null -eq $linkDirs) { Write-Host "Read access    : the link names no folders (an older link; install-pdf-read.ps1 writes them)" -ForegroundColor Yellow }
        elseif ($linkDirs.Count -eq 0) { Write-Host "Read access    : no folders of its own; the app's roots and settings only" -ForegroundColor DarkGray }
        else {
            $gone = @($linkDirs | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Container) })
            Write-Host "Read access    : $($linkDirs -join '; ')" -ForegroundColor DarkGray
            if ($gone.Count) { Write-Host "                 not existing folders, skipped by the wrapper: $($gone -join '; ')" -ForegroundColor Yellow }
        }
    }
}

# Each patch of patches.ps1 (README - "The patches"). Anchors are pure ASCII; files are read as Latin-1 so every byte
# round-trips.
$enc = [System.Text.Encoding]::GetEncoding(28591)
$texts = @{}
foreach ($n in 'mcp-app.html', 'server.js') {
    $p = Join-Path $distDir $n
    $texts[$n] = if (Test-Path -LiteralPath $p) { $enc.GetString([System.IO.File]::ReadAllBytes($p)) } else { $null }
}
$patchState = @{}
foreach ($pt in $PATCHES) {
    if ($null -eq $texts[$pt.File]) { $patchState[$pt.Key] = 'NO FILE'; Write-Host ("Patch {0,-32}: {1} NOT FOUND in dist." -f $pt.Name, $pt.File) -ForegroundColor Red; continue }
    $st = (Get-PatchState $pt $texts[$pt.File]).State
    $patchState[$pt.Key] = $st
    switch ($st) {
        'PATCHED'   { Write-Host ("Patch {0,-32}: PATCHED" -f $pt.Name) -ForegroundColor Green }
        'PATCHABLE' { Write-Host ("Patch {0,-32}: NOT PATCHED - run install-pdf-read.ps1 (app closed)" -f $pt.Name) -ForegroundColor Yellow }
        'NOTNEEDED' { Write-Host ("Patch {0,-32}: NOT NEEDED (this version already has the fix)" -f $pt.Name) -ForegroundColor Green }
        'UNKNOWN'   { Write-Host ("Patch {0,-32}: UNKNOWN PATTERN - no known anchor in this bundle (new version? the patch needs re-deriving)" -f $pt.Name) -ForegroundColor Yellow }
    }
}
if (($patchState['dlwidget'] -eq 'PATCHED') -ne ($patchState['dlserver'] -eq 'PATCHED')) {
    Write-Host "Download fix   : MISMATCH - widget=$($patchState['dlwidget']) server=$($patchState['dlserver']) (half-applied; the button is broken). Run install-pdf-read.ps1 (app closed)." -ForegroundColor Red
}
if ($patchState['dlshow'] -eq 'PATCHED' -and -not ($patchState['dlwidget'] -eq 'PATCHED' -and $patchState['dlserver'] -eq 'PATCHED')) {
    Write-Host "Download button: SHOWN WITHOUT THE FIX - widget=$($patchState['dlwidget']) server=$($patchState['dlserver']) (a click does nothing). Run install-pdf-read.ps1 (app closed); if a half has no known anchor, uninstall-pdf-read.ps1 hides the button again." -ForegroundColor Red
}
$schemaState = switch ($patchState['schema']) { 'PATCHED' { 'PATCHED' } 'PATCHABLE' { 'NOT PATCHED' } 'NOTNEEDED' { 'NOT NEEDED' } default { 'UNKNOWN' } }

# The live test of the same thing: ask the installed server for its tool list and put every output schema
# through a model of Claude Code's gate. Run through System.Diagnostics.Process, not & node 2>&1: in
# PowerShell 5.1 redirected native stderr becomes error records, and terminating ones under 'Stop'.
$checkJs = Join-Path $PSScriptRoot 'check-schema-dialect.mjs'
$schemaCheckExit = $null
$node = Get-Command node -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not (Test-Path -LiteralPath $checkJs)) {
    Write-Host "Schema check   : NOT RUN - check-schema-dialect.mjs is missing from $PSScriptRoot" -ForegroundColor Yellow
} elseif (-not $node) {
    Write-Host "Schema check   : NOT RUN - node is not on PATH" -ForegroundColor Yellow
} else {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $node.Path
    $psi.Arguments = '"' + $checkJs + '" --dist "' + $distDir + '"'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $null = $proc.StandardError.ReadToEndAsync()   # drained, or a chatty stderr can fill its pipe and block the child
    if (-not $proc.WaitForExit(90000)) {
        try { $proc.Kill() } catch {}
        Write-Host "Schema check   : NOT RUN - no result within 90 s" -ForegroundColor Yellow
    } else {
        $proc.WaitForExit()
        $schemaCheckExit = $proc.ExitCode
        $lines = @($outTask.Result -split "`r?`n" | Where-Object { $_.Trim() })
        $verdict = if ($lines.Count -gt 0) { $lines[-1] } else { "no output (exit code $($proc.ExitCode))" }
        $color = if ($proc.ExitCode -eq 0) { 'Green' } elseif ($proc.ExitCode -eq 1) { 'Red' } else { 'Yellow' }
        Write-Host "Schema check   : $verdict" -ForegroundColor $color
        if ($proc.ExitCode -ne 0) { Write-Host "                 full report:  node `"$checkJs`"" -ForegroundColor DarkGray }
    }
}
Write-Host ""

$state = if ($missing.Count -gt 0) { 'INCOMPLETE' }
         elseif ($idxIsWrapper -and $realExists) { 'HEALTHY' }
         elseif ($idxIsWrapper -and -not $realExists) { 'HALF' }
         elseif (-not $idxIsWrapper -and $realExists) { 'WIPED' }
         else { 'OFF' }

switch ($state) {
    'HEALTHY' {
        $gateBlocks = ($schemaCheckExit -eq 1) -or ((($null -eq $schemaCheckExit) -or ($schemaCheckExit -eq 2)) -and ($schemaState -eq 'NOT PATCHED'))
        if ($gateBlocks) {
            Write-Host "STATE: HEALTHY wrapper, but Claude Code cannot open PDFs: its schema gate blocks display_pdf. Run install-pdf-read.ps1 (app closed)." -ForegroundColor Yellow
        } else {
            Write-Host "STATE: HEALTHY - local PDF read access is ON." -ForegroundColor Green
        }
        if (-not $frozen) {
            Write-Host ""
            Write-Host "  Not frozen: the next pdf-viewer update will replace the wrapper and read access" -ForegroundColor Yellow
            Write-Host "  will silently turn off. Run lock-pdf-read.ps1 to prevent that." -ForegroundColor Yellow
        }
        return
    }
    'OFF'     { Write-Host "STATE: OFF - clean original extension, wrapper not installed." -ForegroundColor Yellow }
    'WIPED'   { Write-Host "STATE: WIPED - index.js is a stock server again but index.real.js remains: something replaced the wrapper. Read access is OFF." -ForegroundColor Red }
    'HALF'    { Write-Host "STATE: HALF - wrapper present but the real server (index.real.js) is MISSING. Repair the pdf-viewer extension in the app." -ForegroundColor Red }
    'INCOMPLETE' { Write-Host "STATE: INCOMPLETE - the extension folder is missing files of its own: $($missing -join ', '). The app cannot run it, and no script here can repair it: replace the folder with an intact copy (README - `"An incomplete extension folder`")." -ForegroundColor Red }
}

if ($state -eq 'HALF' -or $state -eq 'INCOMPLETE') { return }   # -Fix cannot recover missing files

if (-not $Fix) {
    Write-Host ""
    Write-Host "To (re)install: close the Claude app, then run this with -Fix, or run install-pdf-read.ps1." -ForegroundColor Cyan
    return
}

# -Fix: hand off to the installer (it has the full, safe state machine)
# A Claude process with no threads can neither run nor hold a file open; quitting the app can leave one behind.
# The same test in install, uninstall and verify; change them together.
if (@(Get-Process -Name Claude -ErrorAction SilentlyContinue | Where-Object { $_.Threads.Count -gt 0 }).Count -gt 0) {
    Write-Host "`n-Fix requested but the Claude app is RUNNING. Close it fully, then re-run with -Fix. Nothing changed." -ForegroundColor Red
    return
}
Write-Host "`n-Fix: running install-pdf-read.ps1 ..." -ForegroundColor Cyan
& (Join-Path $PSScriptRoot 'install-pdf-read.ps1') @passDist
