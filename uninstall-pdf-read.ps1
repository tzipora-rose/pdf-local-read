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

# uninstall-pdf-read.ps1
# Reverses install-pdf-read.ps1: restores dist\index.real.js -> dist\index.js, removes the wrapper and its link
# (dist\pdf-local-read.json), and reverts every patch of patches.ps1 by exact inverse. It refuses an extension folder
# that is missing files of its own (README - "An incomplete extension folder").
# RUN WITH THE CLAUDE APP FULLY CLOSED.
#   -Dist <folder> : the pdf-viewer dist folder to act on. Without it: PDF_VIEWER_DIST, then the app's
#                    extension folder (README - "Finding the extension").

[CmdletBinding(PositionalBinding = $false)]
param([string]$Dist)

$ErrorActionPreference = 'Stop'

$SIG = 'PDF-LOCAL-READ-WRAPPER'
if (-not $PSScriptRoot) {
    Write-Host "Run this as a script file: the toolkit folder is found from the script's own location. Nothing changed." -ForegroundColor Red
    return
}
. (Join-Path $PSScriptRoot 'patches.ps1')

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

# A Claude process with no threads can neither run nor hold a file open; quitting the app can leave one behind.
# The same test in install, uninstall and verify; change them together.
if (@(Get-Process -Name Claude -ErrorAction SilentlyContinue | Where-Object { $_.Threads.Count -gt 0 }).Count -gt 0) {
    Write-Host "The Claude app is RUNNING. Close it fully, then re-run. Nothing changed." -ForegroundColor Red
    return
}

$distDir = $null
# A string, not Join-Path, which throws on a missing drive; Test-Path throws on illegal characters. Either way: not found.
foreach ($c in $distCandidates) { try { if (Test-Path -LiteralPath "$c\index.real.js" -ErrorAction Stop) { $distDir = $c; break } } catch {} }
if (-not $distDir) {
    Write-Host "No index.real.js found via $distFrom - nothing to revert (wrapper not installed)." -ForegroundColor Yellow
    $distCandidates | ForEach-Object { Write-Host "    tried: $_" -ForegroundColor DarkGray }
    if (-not $distCandidates) { Write-Host "    tried: nothing - LOCALAPPDATA and APPDATA are both unset" -ForegroundColor DarkGray }
    return
}
# The thaw acts on the folder above the dist, so a location given by hand must be an extension's dist.
if ($distOverride -and -not (Test-Path -LiteralPath (Join-Path (Split-Path $distDir -Parent) 'manifest.json'))) {
    Write-Host "Refusing $distDir (from $distFrom): the folder above it has no manifest.json, so it is not the pdf-viewer extension. Nothing changed." -ForegroundColor Red
    return
}
$missing = @(Get-MissingOwnFiles (Split-Path $distDir -Parent))
if ($missing.Count -gt 0) {
    Write-Host "Refusing $distDir (from $distFrom): the extension folder is missing files of its own: $($missing -join ', '). Uninstalling would make index.real.js the entry again and report the original extension restored, which it would not be. Replace the folder with an intact copy first (README - `"An incomplete extension folder`"). Nothing changed." -ForegroundColor Red
    return
}

$idx  = Join-Path $distDir 'index.js'
$real = Join-Path $distDir 'index.real.js'
Write-Host "Extension dist: $distDir  (from $distFrom)" -ForegroundColor Cyan

if ((Test-Path -LiteralPath $idx) -and -not (Select-String -LiteralPath $idx -Pattern $SIG -Quiet)) {
    Write-Host "index.js is NOT our wrapper. Refusing to touch it. index.real.js left in place." -ForegroundColor Red
    Write-Host "  index.js  = $idx" -ForegroundColor DarkGray
    Write-Host "  index.real.js = $real" -ForegroundColor DarkGray
    return
}

# If the extension is FROZEN (lock-pdf-read.ps1), our own deny-ACE blocks the remove/move below. Thaw
# first. Uninstall means going back to the stock extension, so the freeze is NOT restored afterwards -
# there would be no wrapper left to protect.
$ext = Split-Path $distDir -Parent
$me  = "$env:USERDOMAIN\$env:USERNAME"
$wasFrozen = $false
try {
    $acl = Get-Acl -LiteralPath $ext
    foreach ($a in $acl.Access) {
        if ((-not $a.IsInherited) -and $a.AccessControlType -eq 'Deny' -and $a.IdentityReference.Value -eq $me) { $wasFrozen = $true }
    }
} catch {}
if ($wasFrozen) {
    Write-Host "Extension is FROZEN - thawing (uninstall removes the freeze too)." -ForegroundColor DarkGray
    icacls "$ext" /remove:d "$me" /T /C /Q 2>&1 | Out-Null
}

if (Test-Path -LiteralPath $idx) { Remove-Item -LiteralPath $idx -Force }
Move-Item -LiteralPath $real -Destination $idx
Write-Host "Restored real server: $idx" -ForegroundColor Green
$link = Join-Path $distDir 'pdf-local-read.json'
if (Test-Path -LiteralPath $link) {
    Remove-Item -LiteralPath $link -Force
    Write-Host "Removed the wrapper's toolkit link: $link" -ForegroundColor Green
}

# Revert the patches in mcp-app.html and server.js (exact inverse of the installer's). A file in which a marker
# remains after the revert is left untouched: its patched segment no longer matches any known replacement.
$enc = [System.Text.Encoding]::GetEncoding(28591)
foreach ($fileName in 'mcp-app.html', 'server.js') {
    $path = Join-Path $distDir $fileName
    if (-not (Test-Path -LiteralPath $path)) { continue }
    $text = $enc.GetString([System.IO.File]::ReadAllBytes($path))
    $reverted = $text
    $mine = @($PATCHES | Where-Object { $_.File -eq $fileName })
    foreach ($pt in $mine) { $reverted = Undo-Patch $pt $reverted }
    $left = @($mine | Where-Object { $reverted.Contains($_.Marker) })
    if ($left.Count -gt 0) {
        Write-Host "$fileName still holds a marker of $(($left | ForEach-Object { $_.Name }) -join ', ') whose exact segment did not match - NOT touched. Restore it from backups\." -ForegroundColor Red
    } elseif ($reverted -cne $text) {
        [System.IO.File]::WriteAllBytes($path, $enc.GetBytes($reverted))
        Write-Host "Patches reverted in $fileName ($path)" -ForegroundColor Green
    }
}
if ($wasFrozen) { Write-Host "Freeze removed - the app can update pdf-viewer again." -ForegroundColor Green }
Write-Host "Wrapper removed. Reopen the app to run the unmodified extension (local PDF read access OFF)." -ForegroundColor Green
