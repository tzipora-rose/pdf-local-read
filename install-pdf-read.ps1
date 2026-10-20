# install-pdf-read.ps1
# Installs the local-PDF-read wrapper into the Claude desktop app's pdf-viewer extension, applies the patches listed
# in patches.ps1 to dist\mcp-app.html and dist\server.js, then runs verify-pdf-read.ps1 as a health check.
#   real  dist\index.js       -> dist\index.real.js   (the untouched server, preserved)
#   wrap  pdf-stdio-wrap.js    -> dist\index.js        (the app now launches the wrapper)
#   link  dist\pdf-local-read.json: this toolkit's folder, where the wrapper finds its DIAG flag and log folder, and
#         the folders it grants read access to (-Directories)
#   patches (README - "The patches"): poll-loop v1 and v2, the Download button (two halves, and the button shown
#         where the app would hide it), transcript restore,
#         the schema dialect (1.7.4 and 1.7.5; 2.0.0 already has it), Windows file:// roots, and the list walk that
#         skips whole drives.
# Originals are backed up to backups\ with their SHA-256 before the first patch of each bundle version.
#
# RUN WITH THE CLAUDE APP FULLY CLOSED. Reversible with uninstall-pdf-read.ps1.
# Safe to re-run: it detects its own earlier work and the "index.js was replaced" case, and never overwrites the real
# server. A patch with no known anchor in this bundle is skipped with a warning rather than guessed at. It refuses an
# extension folder that is missing files of its own (README - "An incomplete extension folder").
#   -Dist <folder>        : the pdf-viewer dist folder to act on. Without it: PDF_VIEWER_DIST, then the app's
#                           extension folder (README - "Finding the extension").
#   -Directories <f1>,... : the folders Claude may read PDFs from (and save PDFs in), each an existing folder. Without
#                           it, the folders of an earlier install are kept, or else your Documents, Downloads and
#                           Desktop folders are used. The app's own roots and 2.0.0's "PDF Directories" setting are
#                           added to these by the server itself (README - "What Claude may read").

[CmdletBinding(PositionalBinding = $false)]
param([string]$Dist, [string[]]$Directories)

$ErrorActionPreference = 'Stop'

if (-not $PSScriptRoot) {
    Write-Host "Run this as a script file: the toolkit folder is found from the script's own location. Nothing changed." -ForegroundColor Red
    return
}
$src = Join-Path $PSScriptRoot 'pdf-stdio-wrap.js'
$SIG = 'PDF-LOCAL-READ-WRAPPER'   # marker string that only our wrapper contains
. (Join-Path $PSScriptRoot 'patches.ps1')
$backupDir = Join-Path $PSScriptRoot 'backups'

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
if (-not (Test-Path -LiteralPath $src)) {
    Write-Host "Wrapper source not found: $src  (nothing changed)." -ForegroundColor Red
    return
}

# The folders to grant: given ones must exist; they are stored as full paths.
$grantGiven = $PSBoundParameters.ContainsKey('Directories')
$grant = @()
if ($grantGiven) {
    foreach ($d in @($Directories)) {
        if ([string]::IsNullOrWhiteSpace($d)) { Write-Host "Refusing -Directories: an empty folder name was given. Nothing changed." -ForegroundColor Red; return }
        $full = $null
        try { $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($d) } catch {}
        $isDir = $false
        if ($full) { try { $isDir = Test-Path -LiteralPath $full -PathType Container -ErrorAction Stop } catch {} }
        if (-not $isDir) { Write-Host "Refusing -Directories: '$d' is not an existing folder. Nothing changed." -ForegroundColor Red; return }
        if ($full.Length -gt 3) { $full = $full.TrimEnd('\', '/') }
        $grant += $full
    }
    if ($grant.Count -eq 0) { Write-Host "Refusing -Directories: no folder was given. Nothing changed." -ForegroundColor Red; return }
}

$distDir = $null
# A string, not Join-Path, which throws on a missing drive; Test-Path throws on illegal characters. Either way: not found.
foreach ($c in $distCandidates) { try { if (Test-Path -LiteralPath "$c\index.js" -ErrorAction Stop) { $distDir = $c; break } } catch {} }
if (-not $distDir) {
    Write-Host "Could not find the extension's dist\index.js via $distFrom. Is pdf-viewer installed? Nothing changed." -ForegroundColor Red
    $distCandidates | ForEach-Object { Write-Host "    tried: $_" -ForegroundColor DarkGray }
    if (-not $distCandidates) { Write-Host "    tried: nothing - LOCALAPPDATA and APPDATA are both unset" -ForegroundColor DarkGray }
    return
}
# The freeze and thaw act on the folder above the dist, so a location given by hand must be an extension's dist.
if ($distOverride -and -not (Test-Path -LiteralPath (Join-Path (Split-Path $distDir -Parent) 'manifest.json'))) {
    Write-Host "Refusing $distDir (from $distFrom): the folder above it has no manifest.json, so it is not the pdf-viewer extension. Nothing changed." -ForegroundColor Red
    return
}
$missing = @(Get-MissingOwnFiles (Split-Path $distDir -Parent))
if ($missing.Count -gt 0) {
    Write-Host "Refusing $distDir (from $distFrom): the extension folder is missing files of its own: $($missing -join ', '). Installing would wrap an extension that cannot run and report success. Replace the folder with an intact copy first (README - `"An incomplete extension folder`"). Nothing changed." -ForegroundColor Red
    return
}
$passDist = @{}
if ($PSBoundParameters.ContainsKey('Dist')) { $passDist['Dist'] = $distDir }

$idx  = Join-Path $distDir 'index.js'
$real = Join-Path $distDir 'index.real.js'
Write-Host "Extension dist: $distDir  (from $distFrom)" -ForegroundColor Cyan
Write-Host "Toolkit       : $PSScriptRoot" -ForegroundColor Cyan

$idxIsWrapper = Select-String -LiteralPath $idx -Pattern $SIG -Quiet
$realExists   = Test-Path -LiteralPath $real

# The link's format is shared with pdf-stdio-wrap.js, which reads it.
$link = Join-Path $distDir 'pdf-local-read.json'
$linkToolkit = $null; $linkDirs = @(); $linkHasDirs = $false
if (Test-Path -LiteralPath $link) {
    try { $lj = Get-Content -LiteralPath $link -Raw -Encoding UTF8 | ConvertFrom-Json; $linkToolkit = $lj.toolkit; if ($lj.PSObject.Properties['directories']) { $linkDirs = @($lj.directories | Where-Object { $_ }); $linkHasDirs = $true } } catch {}
}
if (-not $grantGiven) {
    if ($linkHasDirs -and $linkDirs.Count -gt 0) { $grant = @($linkDirs) }
    else {
        $defaults = @()
        try { $defaults += [Environment]::GetFolderPath('MyDocuments') } catch {}
        try { $defaults += (New-Object -ComObject Shell.Application).NameSpace('shell:Downloads').Self.Path } catch {}
        try { $defaults += [Environment]::GetFolderPath('Desktop') } catch {}
        $grant = @($defaults | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) } | Select-Object -Unique)
    }
}
$sameDirs = $linkHasDirs -and ((@($linkDirs) -join '|') -ceq (@($grant) -join '|'))
$needLink = -not ($linkToolkit -and ($linkToolkit -ieq $PSScriptRoot) -and $sameDirs)
Write-Host "Read access   : $(if ($grant.Count) { $grant -join '; ' } else { '(no folders of its own)' })" -ForegroundColor Cyan

# Patch states (read bytes via Latin-1 so every byte round-trips losslessly; anchors are ASCII)
$enc = [System.Text.Encoding]::GetEncoding(28591)
$files = @{}
foreach ($n in 'mcp-app.html', 'server.js') {
    $p = Join-Path $distDir $n
    $files[$n] = [pscustomobject]@{ Path = $p; Text = $enc.GetString([System.IO.File]::ReadAllBytes($p)) }
}
$states = @(foreach ($pt in $PATCHES) { [pscustomobject]@{ Patch = $pt; State = (Get-PatchState $pt $files[$pt.File].Text) } })
# The Download button's two halves go in together or not at all: one half alone leaves the button broken.
$dlw = $states | Where-Object { $_.Patch.Key -eq 'dlwidget' }; $dls = $states | Where-Object { $_.Patch.Key -eq 'dlserver' }
$dlHeld = $false
if (($dlw.State.State -eq 'UNKNOWN' -and $dls.State.State -eq 'PATCHABLE') -or ($dls.State.State -eq 'UNKNOWN' -and $dlw.State.State -eq 'PATCHABLE')) { $dlHeld = $true }
# The button is shown only with both halves in place: shown without them, a click does nothing.
$dlShow = $states | Where-Object { $_.Patch.Key -eq 'dlshow' }
$pairIn = @('PATCHED', 'PATCHABLE')
$showHeld = ($dlShow.State.State -eq 'PATCHABLE') -and ($dlHeld -or ($dlw.State.State -notin $pairIn) -or ($dls.State.State -notin $pairIn))
$toApply = @($states | Where-Object { $_.State.State -eq 'PATCHABLE' -and -not ($dlHeld -and ($_.Patch.Key -in 'dlwidget', 'dlserver')) -and -not ($showHeld -and $_.Patch.Key -eq 'dlshow') })

if ($idxIsWrapper -and -not $realExists) {
    Write-Host "HALF-INSTALLED: index.js is our wrapper but index.real.js is MISSING." -ForegroundColor Red
    Write-Host "The real server is gone. Do NOT run the app. Reinstall/repair the pdf-viewer extension in the app first." -ForegroundColor Red
    return
}

$needWrapper = -not ($idxIsWrapper -and $realExists)

function Show-States {
    foreach ($s in $states) {
        switch ($s.State.State) {
            'PATCHED'   { Write-Host "  $($s.Patch.Name): applied" -ForegroundColor Green }
            'NOTNEEDED' { Write-Host "  $($s.Patch.Name): not needed on this version (the bundle already has the fix)" -ForegroundColor Green }
            'UNKNOWN'   { Write-Host "  $($s.Patch.Name): NOT applied - no known anchor in this bundle (new version? the patch needs re-deriving)" -ForegroundColor Yellow }
        }
    }
}

if (-not $needWrapper -and -not $needLink -and $toApply.Count -eq 0) {
    Write-Host "Already installed and healthy (wrapper in place, real server preserved)." -ForegroundColor Green
    Write-Host "  toolkit link: $linkToolkit" -ForegroundColor Green
    Show-States
    if ($dlHeld) { Write-Host "  download fix: held back - one half has no known anchor in this bundle, and one half alone breaks the button" -ForegroundColor Yellow }
    if ($showHeld) { Write-Host "  download button: left as the app decides - the download fix is not in place, and the button shown without it does nothing" -ForegroundColor Yellow }
    Write-Host "To refresh the wrapper code, run uninstall-pdf-read.ps1 then install again." -ForegroundColor DarkGray
    return
}

# If the extension is FROZEN (lock-pdf-read.ps1), our own deny-ACE blocks the writes below, so thaw
# first and refreeze afterwards. Reading was never blocked by the freeze, so every check above was fine.
$ext  = Split-Path $distDir -Parent
$lock = Join-Path $PSScriptRoot 'lock-pdf-read.ps1'
$me   = "$env:USERDOMAIN\$env:USERNAME"
$wasFrozen = $false
try {
    $acl = Get-Acl -LiteralPath $ext
    foreach ($a in $acl.Access) {
        if ((-not $a.IsInherited) -and $a.AccessControlType -eq 'Deny' -and $a.IdentityReference.Value -eq $me) { $wasFrozen = $true }
    }
} catch {}
if ($wasFrozen) {
    Write-Host "Extension is FROZEN - thawing to install, will refreeze when done." -ForegroundColor DarkGray
    icacls "$ext" /remove:d "$me" /T /C /Q 2>&1 | Out-Null
}

try {
    if ($needWrapper) {
        if ($realExists) {
            # Something replaced our wrapper with a server. The current index.js is the NEW server;
            # index.real.js is the STALE old one. Re-wrap the new server.
            Write-Host "Detected a replaced index.js (the wrapper is gone and index.real.js remains). Re-wrapping the new server." -ForegroundColor Yellow
            Remove-Item -LiteralPath $real -Force
            Move-Item -LiteralPath $idx -Destination $real
        } else {
            Write-Host "Fresh install." -ForegroundColor Cyan
            Move-Item -LiteralPath $idx -Destination $real
        }
        Copy-Item -LiteralPath $src -Destination $idx
        Write-Host "  preserved real server ->  $real" -ForegroundColor Green
        Write-Host "  installed wrapper     ->  $idx" -ForegroundColor Green
    }

    if ($needLink) {
        $linkJson = [ordered]@{ toolkit = $PSScriptRoot; directories = @($grant) } | ConvertTo-Json -Compress
        [System.IO.File]::WriteAllText($link, $linkJson + "`n", (New-Object System.Text.UTF8Encoding($false)))
        $linkBack = $null; $dirsBack = $null
        try { $lb = Get-Content -LiteralPath $link -Raw -Encoding UTF8 | ConvertFrom-Json; $linkBack = $lb.toolkit; $dirsBack = @($lb.directories) } catch {}
        if (($linkBack -ceq $PSScriptRoot) -and ((@($dirsBack) -join '|') -ceq ($grant -join '|'))) { Write-Host "  linked the wrapper    ->  $PSScriptRoot  (in $link)" -ForegroundColor Green }
        else { Write-Host "Toolkit link verification FAILED after write - inspect $link." -ForegroundColor Red }
    }

    if ($toApply.Count -gt 0) {
        if (-not (Test-Path -LiteralPath $backupDir)) { New-Item -ItemType Directory -Path $backupDir | Out-Null }
        $ver = 'unknown'
        $manifest = Join-Path $distDir '..\manifest.json'
        if (Test-Path -LiteralPath $manifest) {
            try { $ver = (Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json).version } catch {}
        }
        foreach ($fileName in @($toApply | ForEach-Object { $_.Patch.File } | Select-Object -Unique)) {
            $f = $files[$fileName]
            $bak = Join-Path $backupDir "$fileName.orig-$ver"
            if (-not (Test-Path -LiteralPath $bak)) {
                Copy-Item -LiteralPath $f.Path -Destination $bak
                (Get-FileHash -LiteralPath $f.Path -Algorithm SHA256).Hash | Set-Content -LiteralPath "$bak.sha256" -Encoding Ascii
                Write-Host "  backed up original    ->  $bak (+.sha256)" -ForegroundColor Green
            }
            $newText = $f.Text
            $applied = @()
            foreach ($s in @($toApply | Where-Object { $_.Patch.File -eq $fileName })) {
                if ((Get-AnchorCount $newText $s.State.Variant.Orig) -ne 1) {
                    Write-Host "  $($s.Patch.Name) SKIPPED: its anchor no longer occurs exactly once after the other patches (nothing written for it)." -ForegroundColor Red
                    continue
                }
                $newText = $newText.Replace($s.State.Variant.Orig, $s.State.Variant.New)
                $applied += $s
                Write-Host "  applied $($s.Patch.Name) ($($s.State.Variant.Bundle) anchor) ->  $fileName" -ForegroundColor Green
            }
            if ($newText -cne $f.Text) {
                [System.IO.File]::WriteAllBytes($f.Path, $enc.GetBytes($newText))
                $check = $enc.GetString([System.IO.File]::ReadAllBytes($f.Path))
                $ok = @($applied | Where-Object { -not $check.Contains($_.Patch.Marker) }).Count -eq 0
                if (-not $ok) { Write-Host "Patch verification FAILED after write - inspect $($f.Path) against the backup." -ForegroundColor Red }
            }
        }
    }
    foreach ($s in $states) {
        if ($s.State.State -eq 'UNKNOWN') { Write-Host "  $($s.Patch.Name) NOT applied: no known anchor in this bundle (new version? the patch needs re-deriving)." -ForegroundColor Yellow }
        elseif ($s.State.State -eq 'NOTNEEDED') { Write-Host "  $($s.Patch.Name): not needed on this version (the bundle already has the fix)." -ForegroundColor DarkGray }
    }
    if ($dlHeld) { Write-Host "  download fix held back: one half has no known anchor in this bundle, and one half alone breaks the button." -ForegroundColor Yellow }
    if ($showHeld) { Write-Host "  download button left as the app decides: the download fix is not in place, and the button shown without it does nothing." -ForegroundColor Yellow }
}
finally {
    if ($wasFrozen) {
        if (Test-Path -LiteralPath $lock) {
            & $lock @passDist | Out-Null
            Write-Host "Refroze the extension." -ForegroundColor DarkGray
        } else {
            Write-Host "WARNING: could not refreeze - lock-pdf-read.ps1 not found. Run it manually." -ForegroundColor Red
        }
    }
}

$verifyScript = Join-Path $PSScriptRoot 'verify-pdf-read.ps1'
if (Test-Path -LiteralPath $verifyScript) {
    Write-Host "`nPost-install health check (verify-pdf-read.ps1):" -ForegroundColor Cyan
    & $verifyScript @passDist
}

Write-Host "`nDone. Reopen the Claude app. Claude can then read local PDFs (list_pdfs / display_pdf / interact)." -ForegroundColor Green
Write-Host "Note: the pdf-viewer server loads its files once per app start - these fixes take effect on the next app start." -ForegroundColor DarkGray
Write-Host "Check health anytime with:  verify-pdf-read.ps1" -ForegroundColor DarkGray
