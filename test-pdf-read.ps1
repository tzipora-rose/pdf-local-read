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

# test-pdf-read.ps1
# End-to-end test of this toolkit that never touches the live extension. It copies the installed pdf-viewer
# extension (or the one -Dist names) and this toolkit into a work folder, then runs the real install / verify /
# uninstall / lock scripts against the copies, in child PowerShell processes whose LOCALAPPDATA and APPDATA point into
# the work folder, so no location those scripts can derive reaches the live extension. Only their "is the Claude app
# running" check is stubbed (to see no app, a leftover Claude process with no threads, or a running app), and one test
# runs it unstubbed. It also starts the installed wrapper under node against a
# copy, calls the patched server's fileUrlToPath, speaks MCP to the wrapped server as a client that sends it roots,
# calls list_pdfs with a whole drive allowed (every read of the drive's root intercepted, so the disk is never walked),
# and builds copies missing the extension's own files, which every script must refuse. It also checks that the
# Download button is shown only together with the download fix. The source extension and this toolkit are hashed
# before and after.
#
#   test-pdf-read.ps1                  work folder: %TEMP%\pdf-local-read-test
#   -WorkDir <folder>                  another work folder: a new one, or one this script made before
#   -Dist <folder>                     copy this pdf-viewer dist instead of the app's
#                                      (README - "Finding the extension")
#
# The app can stay open. Needs node on PATH. Takes a few minutes. Prints one PASS or FAIL line per check.
# Exit 0 = every check passed, and the work folder is removed; 1 = a check failed, and the work folder is
# kept for inspection; 2 = the test could not run.
#
# Pure ASCII (PowerShell 5.1 reads .ps1 as Windows-1252; a non-ASCII char breaks parsing).

[CmdletBinding(PositionalBinding = $false)]
param([string]$WorkDir, [string]$Dist)

$ErrorActionPreference = 'Stop'
function Stop-Test([string]$Why) { Write-Host "COULD NOT RUN - $Why" -ForegroundColor Red; exit 2 }

if (-not $PSScriptRoot) { Stop-Test "run this as a script file: the toolkit folder is found from the script's own location" }
$TK  = $PSScriptRoot
. (Join-Path $TK 'patches.ps1')
$SIG = 'PDF-LOCAL-READ-WRAPPER'
$me  = "$env:USERDOMAIN\$env:USERNAME"
$rel = 'Claude\Claude Extensions\ant.dir.gh.anthropic.pdf-server-mcp'
$latin1 = [System.Text.Encoding]::GetEncoding(28591)
# The extension's own files, as install, uninstall, verify and lock list them; change them together.
$OWN = @('manifest.json', 'dist\server.js', 'dist\mcp-app.html', 'dist\pdfjs-polyfill.js', 'node_modules\pdfjs-dist\legacy\build\pdf.mjs')
$pdfMjs = $OWN[4]

# The dist is resolved the same way in every toolkit script and in check-schema-dialect.mjs; change them together.
$distOverride = $PSBoundParameters.ContainsKey('Dist')
if ($distOverride -and [string]::IsNullOrWhiteSpace($Dist)) { Stop-Test '-Dist needs a folder' }
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
$srcDist = $null
# A string, not Join-Path, which throws on a missing drive; Test-Path throws on illegal characters. Either way: not found.
foreach ($c in $distCandidates) { try { if (Test-Path -LiteralPath "$c\index.js" -ErrorAction Stop) { $srcDist = $c; break } } catch {} }
if (-not $srcDist) {
    $tried = if ($distCandidates) { $distCandidates -join ' ; ' } else { 'nothing - LOCALAPPDATA and APPDATA are both unset' }
    Stop-Test "could not find the extension's dist\index.js via $distFrom (tried: $tried)"
}
$srcExt = Split-Path $srcDist -Parent
if (-not (Test-Path -LiteralPath (Join-Path $srcExt 'manifest.json'))) { Stop-Test "$srcDist (from $distFrom): the folder above it has no manifest.json, so it is not the pdf-viewer extension" }

$marker = '.pdf-local-read-test'
if ($PSBoundParameters.ContainsKey('WorkDir')) {
    if ([string]::IsNullOrWhiteSpace($WorkDir)) { Stop-Test '-WorkDir needs a folder' }
    $W = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($WorkDir)
} elseif ($env:TEMP) {
    $W = Join-Path $env:TEMP 'pdf-local-read-test'
} else { Stop-Test 'TEMP is unset: pass -WorkDir <folder>' }
if ($W.Length -gt 3) { $W = $W.TrimEnd('\', '/') }
function Test-Within([string]$Child, [string]$Parent) { return ($Child.TrimEnd('\') + '\').StartsWith($Parent.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) }
if ((Test-Within $W $srcExt) -or (Test-Within $srcExt $W) -or (Test-Within $W $TK) -or (Test-Within $TK $W)) { Stop-Test "the work folder $W overlaps the extension or this toolkit" }
if ((Test-Path -LiteralPath $W) -and -not (Test-Path -LiteralPath (Join-Path $W $marker))) { Stop-Test "$W exists and was not made by this script; refusing to use or delete it" }

$T   = Join-Path $W 'T'
$T2  = Join-Path $W 'T2'
$L   = Join-Path $W 'L'
$R   = Join-Path $W 'R'
$E   = Join-Path $W 'E'
$X   = Join-Path $W 'X\ext'
$XD  = Join-Path $X 'dist'
$B   = Join-Path $W 'B'
$BD  = Join-Path $B 'dist'
$P   = Join-Path $W 'P'
$RUN = Join-Path $W 'run'
$GR  = Join-Path $W 'grant'
$LE  = Join-Path $L "Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\$rel"
$LD  = Join-Path $LE 'dist'
$G   = Join-Path $W 'G'
$GE  = Join-Path $G "Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\$rel"
$GD  = Join-Path $GE 'dist'
$RE  = Join-Path $R $rel
$RD  = Join-Path $RE 'dist'

# Windows paths stop at 260 characters, and node_modules nests deep, so only X carries it.
$maxRel = 0; $maxRelNoMods = 0
Get-ChildItem -LiteralPath $srcExt -Recurse -Force -File | ForEach-Object {
    $len = $_.FullName.Length - $srcExt.Length
    if ($len -gt $maxRel) { $maxRel = $len }
    if ($_.FullName -notmatch '\\node_modules\\' -and $len -gt $maxRelNoMods) { $maxRelNoMods = $len }
}
if ($X.Length + $maxRel -ge 260) { Stop-Test "the work folder path is too long: a full copy of the extension would need $($X.Length + $maxRel)-character paths, over the Windows limit of 260; pass a shorter -WorkDir" }
$maxRelNoMods = [Math]::Max($maxRelNoMods, $pdfMjs.Length + 1)
if ($LE.Length + $maxRelNoMods -ge 260) { Stop-Test "the work folder path is too long for the default-location copy ($($LE.Length + $maxRelNoMods) characters); pass a shorter -WorkDir" }

$node = Get-Command node -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $node) { Stop-Test 'node is not on PATH; the schema check and the wrapper tests need it' }

# Pristine references: the untouched server, and the originals install backs up before its first patch.
$ver = 'unknown'
try { $ver = (Get-Content -LiteralPath (Join-Path $srcExt 'manifest.json') -Raw | ConvertFrom-Json).version } catch {}
$srcIsWrapper = Select-String -LiteralPath (Join-Path $srcDist 'index.js') -Pattern $SIG -Quiet
if ($srcIsWrapper -and -not (Test-Path -LiteralPath (Join-Path $srcDist 'index.real.js'))) { Stop-Test 'the extension is half-installed (wrapper present, index.real.js missing); repair it first' }
$srcMissing = @($OWN | Where-Object { -not (Test-Path -LiteralPath (Join-Path $srcExt $_) -PathType Leaf) })
if ($srcMissing.Count -gt 0) { Stop-Test "the extension is missing files of its own ($($srcMissing -join ', ')); replace it with an intact copy first" }
$pristineIdx = if ($srcIsWrapper) { Join-Path $srcDist 'index.real.js' } else { Join-Path $srcDist 'index.js' }
function Get-PristineRef([string]$Name) {
    $bak = Join-Path $TK "backups\$Name.orig-$ver"
    if (Test-Path -LiteralPath $bak) {
        $want = $null
        try { $want = (Get-Content -LiteralPath "$bak.sha256" -Raw).Trim() } catch {}
        if ($want -and $want -ne (Get-FileHash -LiteralPath $bak -Algorithm SHA256).Hash) { Stop-Test "backups\$Name.orig-$ver does not match its .sha256 sidecar" }
        return $bak
    }
    $live = Join-Path $srcDist $Name
    $text = $latin1.GetString([System.IO.File]::ReadAllBytes($live))
    foreach ($pt in @($PATCHES | Where-Object { $_.File -eq $Name })) { if ($text.Contains($pt.Marker)) { Stop-Test "no pristine $Name for version $($ver): the extension's copy is patched and backups\ has no original" } }
    return $live
}
$refApp = Get-PristineRef 'mcp-app.html'
$refSrv = Get-PristineRef 'server.js'
# What a full install must leave in this bundle: every patch whose anchor the pristine file carries.
$pristineText = @{ 'mcp-app.html' = $latin1.GetString([System.IO.File]::ReadAllBytes($refApp)); 'server.js' = $latin1.GetString([System.IO.File]::ReadAllBytes($refSrv)) }
$EXPECT = @($PATCHES | Where-Object { (Get-PatchState $_ $pristineText[$_.File]).State -eq 'PATCHABLE' })
$NOTNEEDED = @($PATCHES | Where-Object { (Get-PatchState $_ $pristineText[$_.File]).State -eq 'NOTNEEDED' })
$UNKNOWN = @($PATCHES | Where-Object { (Get-PatchState $_ $pristineText[$_.File]).State -eq 'UNKNOWN' })

# ------------------------------------------------------------------ helpers
$script:pass = 0; $script:fail = 0; $script:failed = @(); $script:lastOut = @(); $script:runN = 0
function Check([string]$Name, [bool]$Cond) {
    if ($Cond) { $script:pass++; Write-Host "  PASS  $Name" -ForegroundColor Green; return }
    $script:fail++; $script:failed += $Name
    Write-Host "  FAIL  $Name" -ForegroundColor Red
    $script:lastOut | Select-Object -Last 15 | ForEach-Object { Write-Host "        | $_" -ForegroundColor DarkGray }
}
function Has($Out, [string]$Text) { return [bool](@($Out | Where-Object { $_.Contains($Text) }).Count) }
function Hash([string]$Path) { if (Test-Path -LiteralPath $Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash } else { 'ABSENT' } }
function Get-Snap([string]$Root, [switch]$NoLogs) {
    $h = [ordered]@{}
    if (-not (Test-Path -LiteralPath $Root)) { return $h }
    Get-ChildItem -LiteralPath $Root -Recurse -Force -File |
        Where-Object { $_.FullName -notmatch '\\node_modules\\' -and -not ($NoLogs -and ($_.Name -like '*.log*' -or $_.Name -like '*.flag')) } |
        Sort-Object FullName | ForEach-Object { $h[$_.FullName.Substring($Root.Length)] = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
    return $h
}
function Same-Snap($a, $b) {
    if ($a.Count -ne $b.Count) { return $false }
    foreach ($k in $a.Keys) { if (-not $b.Contains($k) -or $a[$k] -ne $b[$k]) { return $false } }
    return $true
}
function Get-DenyCount([string]$Path) {
    try { return @((Get-Acl -LiteralPath $Path).Access | Where-Object { -not $_.IsInherited -and $_.AccessControlType -eq 'Deny' -and $_.IdentityReference.Value -eq $me }).Count } catch { return -1 }
}
function Thaw([string]$Path) { if (Test-Path -LiteralPath $Path) { icacls "$Path" /remove:d "$me" /T /C /Q 2>&1 | Out-Null } }
function Copy-Tree([string]$From, [string]$To, [string[]]$Extra = @()) {
    $null = & robocopy $From $To /E /R:0 /W:0 /NFL /NDL /NJH /NJS /NP @Extra
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($LASTEXITCODE): $From -> $To" }
}
function Get-LinkJson([string]$D) {
    $f = Join-Path $D 'pdf-local-read.json'
    if (-not (Test-Path -LiteralPath $f)) { return $null }
    try { return (Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}
function Get-Link([string]$D) {
    $f = Join-Path $D 'pdf-local-read.json'
    if (-not (Test-Path -LiteralPath $f)) { return $null }
    $j = Get-LinkJson $D
    if ($null -eq $j) { return '<unreadable>' }
    return $j.toolkit
}
function Get-LinkDirs([string]$D) { $j = Get-LinkJson $D; if ($null -eq $j -or -not $j.PSObject.Properties['directories']) { return $null }; return @($j.directories) }
function Set-Link([string]$D, [string]$Text) { [System.IO.File]::WriteAllText((Join-Path $D 'pdf-local-read.json'), $Text, (New-Object System.Text.UTF8Encoding($false))) }
function Set-Pristine([string]$D) {
    foreach ($n in 'index.js', 'mcp-app.html', 'server.js') { Copy-Item -LiteralPath (Join-Path $P $n) -Destination (Join-Path $D $n) -Force }
    foreach ($n in 'index.real.js', 'pdf-local-read.json', 'pdf-read.log', 'pdf-read.log.old') { $f = Join-Path $D $n; if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force } }
}
function Test-Pristine([string]$D) {
    foreach ($n in 'index.js', 'mcp-app.html', 'server.js') { if ((Hash (Join-Path $D $n)) -ne (Hash (Join-Path $P $n))) { return $false } }
    foreach ($n in 'index.real.js', 'pdf-local-read.json') { if (Test-Path -LiteralPath (Join-Path $D $n)) { return $false } }
    return $true
}
function Test-Installed([string]$D, [string]$Toolkit) {
    if ((Hash (Join-Path $D 'index.js')) -ne (Hash (Join-Path $Toolkit 'pdf-stdio-wrap.js'))) { return $false }
    if ((Hash (Join-Path $D 'index.real.js')) -ne (Hash (Join-Path $P 'index.js'))) { return $false }
    $txt = @{ 'mcp-app.html' = $latin1.GetString([System.IO.File]::ReadAllBytes((Join-Path $D 'mcp-app.html'))); 'server.js' = $latin1.GetString([System.IO.File]::ReadAllBytes((Join-Path $D 'server.js'))) }
    foreach ($pt in $EXPECT) { if (-not $txt[$pt.File].Contains($pt.Marker)) { return $false } }
    return ((Get-Link $D) -ceq $Toolkit)
}
# Each child command runs from a file: with -EncodedCommand, PowerShell 5.1 also echoes the child's Write-Host output.
# -ProcStub: what the stubbed "is the app running" check sees. Empty: no Claude process. 'husk': one with no threads,
# as quitting the app can leave behind. 'live': one with a thread, a running app.
function Run([string]$Script, [string[]]$A = @(), [hashtable]$Env = @{}, [switch]$NoStub, [string]$Cwd, [switch]$FromText, [string]$ProcStub = '') {
    $e = @{ LOCALAPPDATA = $L; APPDATA = $R; PDF_VIEWER_DIST = $null }
    foreach ($k in $Env.Keys) { $e[$k] = $Env[$k] }
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($k in $e.Keys) {
        if ($null -eq $e[$k]) { $lines.Add("Remove-Item Env:$k -ErrorAction SilentlyContinue") }
        else { $lines.Add("`$env:$k = '" + ($e[$k] -replace "'", "''") + "'") }
    }
    $fake = switch ($ProcStub) {
        ''     { '' }
        'husk' { '[pscustomobject]@{ ProcessName = ''claude''; Threads = @() }' }
        'live' { '[pscustomobject]@{ ProcessName = ''claude''; Threads = @(1) }' }
        default { throw "Run: unknown -ProcStub '$ProcStub'" }
    }
    if (-not $NoStub) { $lines.Add('function Get-Process { [CmdletBinding()] param([string[]]$Name) if ($Name -contains ''Claude'') { return ' + $fake + ' }; Microsoft.PowerShell.Management\Get-Process @PSBoundParameters }') }
    if ($Cwd) { $lines.Add("Set-Location -LiteralPath '" + ($Cwd -replace "'", "''") + "'") }
    $argText = ($A | ForEach-Object { if ($_ -match '^-[A-Za-z]+$') { $_ } else { "'" + ($_ -replace "'", "''") + "'" } }) -join ' '
    $sp = $Script -replace "'", "''"
    if ($FromText) { $lines.Add("& ([scriptblock]::Create([IO.File]::ReadAllText('$sp'))) $argText") }
    else { $lines.Add("& '$sp' $argText") }
    $script:runN++
    $child = Join-Path $RUN ('child-{0:D3}.ps1' -f $script:runN)
    [System.IO.File]::WriteAllText($child, ($lines -join "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $child 2>&1 | ForEach-Object { "$_" }
    $ErrorActionPreference = $prev
    $script:lastOut = @($out)
    return ,@($out)
}
function S([string]$Name) { return Join-Path $T $Name }
function Start-Wrapper([string]$D, [hashtable]$Env = @{}) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $node.Path
    $psi.Arguments = '"' + (Join-Path $D 'index.js') + '" --stdio'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = $W
    $psi.EnvironmentVariables['APPDATA'] = $R
    $psi.EnvironmentVariables['LOCALAPPDATA'] = $L
    foreach ($k in 'PDF_WRAP_DIAG', 'PDF_VIEWER_DIST') { if ($psi.EnvironmentVariables.ContainsKey($k)) { $psi.EnvironmentVariables.Remove($k) } }
    foreach ($k in $Env.Keys) { $psi.EnvironmentVariables[$k] = $Env[$k] }
    $proc = [System.Diagnostics.Process]::Start($psi)
    $errTask = $proc.StandardError.ReadToEndAsync()
    $null = $proc.StandardOutput.ReadToEndAsync()
    $proc.StandardInput.Close()
    if (-not $proc.WaitForExit(6000)) { try { $proc.Kill() } catch {}; $null = $proc.WaitForExit(5000) }
    $script:lastOut = @($errTask.Result -split "`r?`n")
    return $errTask.Result
}
function Get-LastSession([string]$Log) {
    if (-not (Test-Path -LiteralPath $Log)) { return '' }
    $t = [System.IO.File]::ReadAllText($Log)
    $i = $t.LastIndexOf('==== SESSION')
    if ($i -lt 0) { return '' }
    return $t.Substring($i)
}
# Calls the exported fileUrlToPath of a dist's server.js under node; returns one result line per input.
function Invoke-FileUrlToPath([string]$D, [string[]]$Urls) {
    $js = Join-Path $RUN 'furl.mjs'
    $code = "import { pathToFileURL } from 'node:url';`n" +
            "const lines = [];`n" +
            "try {`n" +
            "  const m = await import(pathToFileURL(process.argv[2]).href);`n" +
            "  for (const u of process.argv.slice(3)) { let r; try { r = 'OK ' + m.fileUrlToPath(u); } catch (e) { r = 'THROWS ' + e.message; } lines.push(r); }`n" +
            "} catch (e) { lines.push('IMPORT FAILED ' + ((e && e.message) || e)); }`n" +
            "process.stdout.write(lines.join('\n') + '\n', () => process.exit(0));`n"
    [System.IO.File]::WriteAllText($js, $code, (New-Object System.Text.UTF8Encoding($false)))
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $out = & $node.Path $js (Join-Path $D 'server.js') @Urls 2>$null
    $ErrorActionPreference = $prev
    $script:lastOut = @($out)
    return ,@($out)
}

# A client of the wrapped server over stdio, as the app is: it declares the roots capability, answers the server's
# first roots/list with one folder and, after notifications/roots/list_changed, its second with another, and calls
# list_pdfs after each. Prints {first, second, rootsAsked, error} as JSON: the allowedDirectories of each list_pdfs.
$ROOTS_CLIENT = @'
import { spawn } from 'node:child_process';
import { pathToFileURL } from 'node:url';
const [idx, firstRoot, secondRoot] = process.argv.slice(2);
const out = { first: null, second: null, rootsAsked: 0, error: null };
const child = spawn(process.execPath, [idx, '--stdio'], { stdio: ['pipe', 'pipe', 'ignore'] });
const finish = (code) => { try { child.kill(); } catch (e) {} process.stdout.write(JSON.stringify(out) + '\n', () => process.exit(code)); };
setTimeout(() => { out.error = out.error || 'no result within 40 s'; finish(2); }, 40000).unref();
const answers = [[firstRoot], [secondRoot]];
const waiting = new Map();
let onRootsAnswered = null;
let buf = '';
const send = (m) => child.stdin.write(JSON.stringify(m) + '\n');
child.stdout.on('data', (d) => {
  buf += d.toString('utf8');
  let i;
  while ((i = buf.indexOf('\n')) >= 0) {
    const line = buf.slice(0, i).trim();
    buf = buf.slice(i + 1);
    if (!line) continue;
    let m;
    try { m = JSON.parse(line); } catch (e) { continue; }
    if (m.method === 'roots/list' && m.id !== undefined) {
      const dirs = answers[out.rootsAsked] || [];
      out.rootsAsked++;
      send({ jsonrpc: '2.0', id: m.id, result: { roots: dirs.map((p) => ({ uri: pathToFileURL(p).href, name: p })) } });
      if (onRootsAnswered) { const f = onRootsAnswered; onRootsAnswered = null; setTimeout(f, 300); }
    } else if (m.id !== undefined && waiting.has(m.id)) {
      const f = waiting.get(m.id);
      waiting.delete(m.id);
      f(m);
    }
  }
});
const request = (id, method, params) => new Promise((resolve, reject) => {
  const t = setTimeout(() => reject(new Error(method + ': no response within 15 s')), 15000);
  waiting.set(id, (m) => { clearTimeout(t); resolve(m); });
  send({ jsonrpc: '2.0', id, method, params });
});
const rootsAnswered = () => new Promise((resolve, reject) => {
  const t = setTimeout(() => reject(new Error('the server did not ask for its roots within 15 s')), 15000);
  onRootsAnswered = () => { clearTimeout(t); resolve(); };
});
const allowedDirectories = async (id) => {
  const r = await request(id, 'tools/call', { name: 'list_pdfs', arguments: {} });
  if (r.error) throw new Error('list_pdfs: ' + r.error.message);
  return (r.result && r.result.structuredContent && r.result.structuredContent.allowedDirectories) || null;
};
try {
  const init = await request(1, 'initialize', { protocolVersion: '2025-06-18', capabilities: { roots: { listChanged: true } }, clientInfo: { name: 'test-pdf-read', version: '1.0.0' } });
  if (init.error) throw new Error('initialize: ' + init.error.message);
  let asked = rootsAnswered();
  send({ jsonrpc: '2.0', method: 'notifications/initialized' });
  await asked;
  out.first = await allowedDirectories(2);
  asked = rootsAnswered();
  send({ jsonrpc: '2.0', method: 'notifications/roots/list_changed' });
  await asked;
  out.second = await allowedDirectories(3);
  finish(0);
} catch (e) {
  out.error = (e && e.message) || String(e);
  finish(1);
}
'@
# Builds a server.js in this process, allows a whole drive and one folder in it, and calls list_pdfs over an in-memory
# MCP connection. Every read of the drive's root folder is recorded and answered with an empty listing, so the disk is
# never walked. Prints {walked, localFiles, allowedDirectories, error} as JSON.
$LIST_CHECK = @'
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
const [serverJs, granted] = process.argv.slice(2);
const folder = path.resolve(granted);
const driveRoot = path.parse(folder).root;
const out = { walked: [], localFiles: null, allowedDirectories: null, error: null };
const finish = (code) => { process.stdout.write(JSON.stringify(out) + '\n', () => process.exit(code)); };
setTimeout(() => { out.error = out.error || 'no result within 30 s'; finish(2); }, 30000).unref();
const fsp = fs.promises;
const readdir = fsp.readdir.bind(fsp);
fsp.readdir = async (p, o) => {
  if (path.resolve(String(p)) === driveRoot) { out.walked.push(driveRoot); return []; }
  return readdir(p, o);
};
class MemoryTransport {
  #waiting = new Map();
  async start() {}
  async close() {}
  async send(message) {
    const done = message && message.id !== undefined ? this.#waiting.get(message.id) : undefined;
    if (done) { this.#waiting.delete(message.id); done(message); }
  }
  request(id, method, params) {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { this.#waiting.delete(id); reject(new Error(method + ': no response within 15 s')); }, 15000);
      this.#waiting.set(id, (m) => { clearTimeout(timer); resolve(m); });
      this.onmessage({ jsonrpc: '2.0', id, method, params });
    });
  }
  notify(method) { this.onmessage({ jsonrpc: '2.0', method }); }
}
try {
  const saved = {};
  for (const k of ['log', 'info', 'warn', 'error', 'debug']) { saved[k] = console[k]; console[k] = () => {}; }
  let m;
  try { m = await import(pathToFileURL(serverJs).href); } finally { Object.assign(console, saved); }
  m.allowedLocalDirs.add(driveRoot);
  m.allowedLocalDirs.add(folder);
  const server = m.createServer({ enableInteract: true });
  const t = new MemoryTransport();
  await server.connect(t);
  const init = await t.request(1, 'initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'test-pdf-read', version: '1.0.0' } });
  if (init.error) throw new Error('initialize: ' + init.error.message);
  t.notify('notifications/initialized');
  const r = await t.request(2, 'tools/call', { name: 'list_pdfs', arguments: {} });
  if (r.error) throw new Error('list_pdfs: ' + r.error.message);
  const sc = (r.result && r.result.structuredContent) || {};
  out.localFiles = sc.localFiles || null;
  out.allowedDirectories = sc.allowedDirectories || null;
  finish(0);
} catch (e) {
  out.error = (e && e.message) || String(e);
  finish(1);
}
'@
# Runs one of the node programs above with the work folder's APPDATA and LOCALAPPDATA; returns its JSON line, parsed.
function Invoke-NodeJson([string]$Code, [string]$FileName, [string[]]$Arguments) {
    $js = Join-Path $RUN $FileName
    [System.IO.File]::WriteAllText($js, $Code, (New-Object System.Text.UTF8Encoding($false)))
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $node.Path
    $psi.Arguments = (@($js) + $Arguments | ForEach-Object { '"' + ($_ -replace '\\$', '\\') + '"' }) -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = $W
    $psi.EnvironmentVariables['APPDATA'] = $R
    $psi.EnvironmentVariables['LOCALAPPDATA'] = $L
    foreach ($k in 'PDF_WRAP_DIAG', 'PDF_VIEWER_DIST') { if ($psi.EnvironmentVariables.ContainsKey($k)) { $psi.EnvironmentVariables.Remove($k) } }
    $proc = [System.Diagnostics.Process]::Start($psi)
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    if (-not $proc.WaitForExit(60000)) { try { $proc.Kill() } catch {}; $null = $proc.WaitForExit(5000) }
    $text = $outTask.Result
    $script:lastOut = @(($text + "`n" + $errTask.Result) -split "`r?`n")
    try { return ($text | ConvertFrom-Json) } catch { return $null }
}
function Invoke-RootsClient([string]$D, [string]$First, [string]$Second) { return Invoke-NodeJson $ROOTS_CLIENT 'roots-client.mjs' @((Join-Path $D 'index.js'), $First, $Second) }

# PowerShell variable names ignore case, so a loop variable can silently overwrite a work path: stop before the first
# write, and again after the preflight checks, if any is not inside the work folder.
function Assert-WorkPaths {
    foreach ($v in $T, $T2, $L, $R, $E, $X, $XD, $B, $BD, $P, $RUN, $GR, $LE, $LD, $RE, $RD, $G, $GE, $GD) {
        if (-not (($v -is [string]) -and [System.IO.Path]::IsPathRooted($v) -and (Test-Within $v $W))) { Stop-Test "internal error: the work path '$v' is not inside $W" }
    }
}
Assert-WorkPaths

# ------------------------------------------------------------------ run
$started = Get-Date
Write-Host "Toolkit        : $TK" -ForegroundColor Cyan
Write-Host "Extension dist : $srcDist  (from $distFrom), version $ver" -ForegroundColor Cyan
Write-Host "Work folder    : $W" -ForegroundColor Cyan
Write-Host "Patches        : $($EXPECT.Count) apply to this bundle ($(($EXPECT | ForEach-Object { $_.Key }) -join ', '))$(if ($NOTNEEDED.Count) { '; not needed: ' + (($NOTNEEDED | ForEach-Object { $_.Key }) -join ', ') })$(if ($UNKNOWN.Count) { '; NO KNOWN ANCHOR: ' + (($UNKNOWN | ForEach-Object { $_.Key }) -join ', ') })" -ForegroundColor Cyan

$live0 = Get-Snap $srcExt; $liveDeny0 = Get-DenyCount $srcExt
$tk0 = Get-Snap $TK -NoLogs

$pushed = $false
try {
    if (Test-Path -LiteralPath $W) { Thaw $W; Remove-Item -LiteralPath $W -Recurse -Force }
    New-Item -ItemType Directory -Path $W | Out-Null
    # Child processes start in the current folder, so any relative path lands in the work folder.
    Push-Location -LiteralPath $W; $pushed = $true
    Set-Content -LiteralPath (Join-Path $W $marker) -Value 'made by test-pdf-read.ps1' -Encoding Ascii
    foreach ($d in $T, $T2, $R, $E, $P, $BD, $RUN, $GR) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    $tkFiles = @(Get-ChildItem -LiteralPath $TK -File | Where-Object { $_.Name -notlike '*.log*' -and $_.Name -notlike '*.flag' })
    foreach ($d in $T, $T2) { foreach ($f in $tkFiles) { Copy-Item -LiteralPath $f.FullName -Destination $d } }
    if (Test-Path -LiteralPath (Join-Path $TK 'backups')) { Copy-Tree (Join-Path $TK 'backups') (Join-Path $T 'backups') }
    Copy-Tree $srcExt $X
    Copy-Tree $srcExt $LE @('/XD', 'node_modules')
    New-Item -ItemType Directory -Force -Path (Split-Path (Join-Path $LE $pdfMjs) -Parent) | Out-Null
    Copy-Item -LiteralPath (Join-Path $srcExt $pdfMjs) -Destination (Join-Path $LE $pdfMjs)
    Copy-Item -LiteralPath $pristineIdx -Destination (Join-Path $P 'index.js')
    Copy-Item -LiteralPath $refApp -Destination (Join-Path $P 'mcp-app.html')
    Copy-Item -LiteralPath $refSrv -Destination (Join-Path $P 'server.js')
    Copy-Item -LiteralPath (Join-Path $T 'pdf-stdio-wrap.js') -Destination (Join-Path $BD 'index.js')
    Copy-Item -LiteralPath (Join-Path $P 'index.js') -Destination (Join-Path $BD 'index.real.js')
    Set-Pristine $XD; Set-Pristine $LD

    Write-Host "== 0 preflight"
    Check '0.1 the copies start pristine' ((Test-Pristine $XD) -and (Test-Pristine $LD))
    Check '0.2 the copies start thawed' (((Get-DenyCount $X) -eq 0) -and ((Get-DenyCount $LE) -eq 0))
    Check '0.3 control: the comparisons can fail (two different files hash differently)' ((Hash (Join-Path $P 'index.js')) -ne (Hash (Join-Path $P 'server.js')))
    Check '0.4 every patch has a known anchor in this bundle, or is not needed in it' ($UNKNOWN.Count -eq 0)
    $overlap = @(foreach ($pt in $PATCHES) { foreach ($va in @($pt.Variants)) { foreach ($vb in @($pt.Variants)) { if (-not [object]::ReferenceEquals($va, $vb) -and $va.New.Contains($vb.New)) { "$($pt.Key): $($va.Bundle) / $($vb.Bundle)" } } } })
    Check '0.5 no replacement text of a patch contains another of its replacement texts (the uninstall finds the variant by it)' ($overlap.Count -eq 0)
    Assert-WorkPaths

    Write-Host "== 1 default location (a copy where the app's extension would be, without node_modules)"
    $o = Run (S 'verify-pdf-read.ps1')
    Check '1.1 verify: finds the dist derived from LOCALAPPDATA' (Has $o "Extension dist : $LD  (from the app's extension folder)")
    Check '1.1 verify: reports OFF on the pristine copy' (Has $o 'STATE: OFF')
    $o = Run (S 'install-pdf-read.ps1')
    Check '1.2 install: prints the dist, its source and its own folder' ((Has $o "Extension dist: $LD  (from the app's extension folder)") -and (Has $o "Toolkit       : $T"))
    Check '1.2 install: fresh install with every patch for this bundle and the toolkit link' ((Has $o 'Fresh install.') -and (Test-Installed $LD $T))
    Check '1.2 install: its health check says the wrapper is current and linked here' ((Has $o 'Wrapper code   : CURRENT') -and (Has $o "Toolkit link   : $T (this toolkit)"))
    $defDirs = Get-LinkDirs $LD
    Check '1.2 install with no -Directories and no earlier link: the link grants existing folders of yours (Documents, Downloads, Desktop)' (($null -ne $defDirs) -and ($defDirs.Count -ge 1) -and (@($defDirs | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Container) }).Count -eq 0))
    foreach ($pt in $NOTNEEDED) { Check "1.2 install: $($pt.Name) reported as not needed in this bundle" (Has $o "$($pt.Name): not needed on this version") }
    $o = Run (S 'lock-pdf-read.ps1')
    Check '1.3 lock: FROZEN, verified by probe' ((Has $o 'FROZEN in') -and ((Get-DenyCount $LE) -ge 1))
    $ldSnap = Get-Snap $LD
    $o = Run (S 'install-pdf-read.ps1')
    Check '1.4 install again: already installed, nothing written' ((Has $o 'Already installed and healthy') -and (Has $o "toolkit link: $T") -and (Same-Snap $ldSnap (Get-Snap $LD)))
    $o = Run (S 'uninstall-pdf-read.ps1')
    Check '1.5 uninstall: prints the dist before writing' (Has $o "Extension dist: $LD  (from the app's extension folder)")
    Check '1.5 uninstall: pristine again, link removed, freeze removed' ((Test-Pristine $LD) -and (Has $o "Removed the wrapper's toolkit link") -and ((Get-DenyCount $LE) -eq 0))
    $dlw = $PATCHES | Where-Object { $_.Key -eq 'dlwidget' }; $dlsh = $PATCHES | Where-Object { $_.Key -eq 'dlshow' }
    if (@($EXPECT | Where-Object { $_.Key -in 'dlwidget', 'dlshow' }).Count -eq 2) {
        $appPath = Join-Path $LD 'mcp-app.html'
        $appText = $latin1.GetString([System.IO.File]::ReadAllBytes($appPath))
        $wv = (Get-PatchState $dlw $appText).Variant
        [System.IO.File]::WriteAllBytes($appPath, $latin1.GetBytes($appText.Replace($wv.Orig, $wv.Orig.Replace('downloadFile){', 'downloadFile) {'))))
        $o = Run (S 'install-pdf-read.ps1')
        $after = $latin1.GetString([System.IO.File]::ReadAllBytes($appPath))
        Check '1.6 install with the widget half of the download fix unanchored: the fix held back, the button left as the app decides' ((Has $o 'download fix held back') -and (Has $o 'download button left as the app decides') -and -not $after.Contains($dlw.Marker) -and -not $after.Contains($dlsh.Marker))
        $o = Run (S 'uninstall-pdf-read.ps1')
        Set-Pristine $LD
        $sv = (Get-PatchState $dlsh $appText).Variant
        [System.IO.File]::WriteAllBytes($appPath, $latin1.GetBytes($appText.Replace($sv.Orig, $sv.New)))
        $o = Run (S 'verify-pdf-read.ps1')
        Check '1.7 verify with the button shown but no download fix: says so' (Has $o 'Download button: SHOWN WITHOUT THE FIX')
        Set-Pristine $LD
        Check '1.7 the copy is pristine again' (Test-Pristine $LD)
    }

    Write-Host "== 2 -Dist and PDF_VIEWER_DIST (a short-path copy with node_modules)"
    $L1 = Get-Snap $LE
    $o = Run (S 'install-pdf-read.ps1') @('-Dist', $XD, '-Directories', $GR)
    Check '2.1 install -Dist: prints the dist and -Dist' (Has $o "Extension dist: $XD  (from -Dist)")
    Check '2.1 install -Dist: every patch for this bundle and the toolkit link' (Test-Installed $XD $T)
    Check '2.1 install -Dist: its health check ran on the same dist, schema check PASS, HEALTHY' ((Has $o "Extension dist : $XD  (from -Dist)") -and (Has $o 'Schema check   : PASS') -and (Has $o 'STATE: HEALTHY - local PDF read access is ON.'))
    Check '2.1 install -Directories: the link grants exactly that folder, and verify shows it' ((((Get-LinkDirs $XD) -join '|') -ceq $GR) -and (Has $o "Read access    : $GR"))
    $X1 = Get-Snap $XD
    $o = Run (S 'lock-pdf-read.ps1') @('-Dist', $XD)
    Check '2.2 lock -Dist: FROZEN; the default-location copy untouched' ((Has $o 'FROZEN in') -and ((Get-DenyCount $X) -ge 1) -and (Same-Snap $L1 (Get-Snap $LE)) -and ((Get-DenyCount $LE) -eq 0))
    $idxBefore = Hash (Join-Path $XD 'index.js')
    $o = Run (Join-Path $T2 'install-pdf-read.ps1') @('-Dist', $XD)
    Check '2.3 install from another toolkit folder, while frozen: thaws, re-points the link, refreezes' ((Has $o 'Extension is FROZEN - thawing') -and (Has $o "linked the wrapper    ->  $T2") -and (Has $o 'Refroze the extension.') -and ((Get-Link $XD) -ceq $T2) -and ((Get-DenyCount $X) -ge 1))
    Check '2.3 re-pointing leaves the wrapper itself alone, and keeps the granted folder' (((Hash (Join-Path $XD 'index.js')) -eq $idxBefore) -and (((Get-LinkDirs $XD) -join '|') -ceq $GR))
    Check '2.3 that toolkit folder reports the link as its own' (Has $o "Toolkit link   : $T2 (this toolkit)")
    $o = Run (S 'verify-pdf-read.ps1') @('-Dist', $XD)
    Check '2.4 verify from the first toolkit: the link points elsewhere' (Has $o "Toolkit link   : points at $T2, another toolkit folder, not this toolkit.")
    $o = Run (S 'install-pdf-read.ps1') @('-Dist', $XD)
    Check '2.5 install from the first toolkit: link points back' ((Get-Link $XD) -ceq $T)
    $o = Run (S 'uninstall-pdf-read.ps1') @('-Dist', $XD)
    Check '2.6 uninstall -Dist: pristine, link and freeze removed' ((Test-Pristine $XD) -and ((Get-DenyCount $X) -eq 0) -and (Has $o 'Freeze removed'))
    $o = Run (S 'install-pdf-read.ps1') @('-Dist', $XD, '-Directories', $GR)
    Check '2.7 install -Dist again: byte-identical to the first install, link included' (Same-Snap $X1 (Get-Snap $XD))
    $o = Run (S 'verify-pdf-read.ps1') @('-Dist', "$XD\")
    Check '2.8 a trailing backslash is normalized, and the schema check still runs' ((Has $o "Extension dist : $XD  (from -Dist)") -and (Has $o 'Schema check   : PASS'))
    $o = Run (S 'verify-pdf-read.ps1') @('-Dist', 'dist') -Cwd $X
    Check '2.9 a relative -Dist resolves against the current folder' (Has $o "Extension dist : $XD  (from -Dist)")
    $o = Run (S 'verify-pdf-read.ps1') -Env @{ PDF_VIEWER_DIST = $XD }
    Check '2.10 PDF_VIEWER_DIST: verify uses it' (Has $o "Extension dist : $XD  (from PDF_VIEWER_DIST)")
    $o = Run (S 'lock-pdf-read.ps1') @('-Status') -Env @{ PDF_VIEWER_DIST = $XD }
    Check '2.10 PDF_VIEWER_DIST: lock uses it' (Has $o "Extension  : $X  (from PDF_VIEWER_DIST)")
    $o = Run (S 'verify-pdf-read.ps1') @('-Dist', $XD) -Env @{ PDF_VIEWER_DIST = (Join-Path $E 'ignored') }
    Check '2.10 -Dist wins over PDF_VIEWER_DIST' (Has $o "Extension dist : $XD  (from -Dist)")
    Copy-Item -LiteralPath (Join-Path $XD 'index.real.js') -Destination (Join-Path $XD 'index.js') -Force
    $o = Run (S 'verify-pdf-read.ps1') @('-Dist', $XD, '-Fix')
    Check '2.11 verify -Dist -Fix on a wiped wrapper: re-wraps the same dist, HEALTHY' ((Has $o 'STATE: WIPED') -and (Has $o 'Detected a replaced index.js') -and (Has $o "Extension dist: $XD  (from -Dist)") -and (Has $o 'STATE: HEALTHY - local PDF read access is ON.') -and (Test-Installed $XD $T))
    Check '2.11 the default-location copy untouched throughout' ((Same-Snap $L1 (Get-Snap $LE)) -and ((Get-DenyCount $LE) -eq 0))
    [System.IO.File]::AppendAllText((Join-Path $XD 'index.js'), "`n// an older copy`n")
    Remove-Item -LiteralPath (Join-Path $XD 'pdf-local-read.json') -Force
    $o = Run (S 'verify-pdf-read.ps1') @('-Dist', $XD)
    Check '2.12 an outdated wrapper is reported, with the refresh that also sets the link' ((Has $o 'Wrapper code   : OUTDATED') -and (Has $o 'Toolkit link   : MISSING') -and (Has $o 'The refresh above sets it.'))
    $o = Run (S 'install-pdf-read.ps1') @('-Dist', $XD, '-Directories', $GR)
    Check '2.12 install alone writes the link but keeps the outdated wrapper, and says so' (((Get-Link $XD) -ceq $T) -and (Has $o 'Wrapper code   : OUTDATED'))
    $o = Run (S 'uninstall-pdf-read.ps1') @('-Dist', $XD)
    $o = Run (S 'install-pdf-read.ps1') @('-Dist', $XD, '-Directories', $GR)
    Check '2.12 uninstall then install refreshes it' ((Test-Installed $XD $T) -and (Has $o 'Wrapper code   : CURRENT'))

    Write-Host "== 3 refusals"
    $Ls = Get-Snap $LE; $Xs = Get-Snap $X
    $four = 'install-pdf-read.ps1', 'uninstall-pdf-read.ps1', 'lock-pdf-read.ps1', 'verify-pdf-read.ps1'
    foreach ($s in $four) { $o = Run (S $s) @('-Dist', ''); Check "3.1 $s -Dist '': refused" (Has $o '-Dist needs a folder') }
    $nope = Join-Path $E 'nope\dist'
    foreach ($s in $four) { $o = Run (S $s) @('-Dist', $nope); Check "3.2 $s -Dist <missing folder>: refused, names what it tried, no fallback" ((Has $o 'via -Dist') -and (Has $o "tried: $nope")) }
    foreach ($s in 'install-pdf-read.ps1', 'uninstall-pdf-read.ps1', 'lock-pdf-read.ps1') { $o = Run (S $s) @('-Dist', $BD); Check "3.3 $s -Dist <not an extension>: refused" (Has $o "Refusing $BD (from -Dist)") }
    $o = Run (S 'verify-pdf-read.ps1') @('-Dist', $BD)
    Check '3.3 verify -Dist <not an extension>: says so' (Has $o 'STATE: NOT AN EXTENSION')
    Check '3.3 the not-an-extension folder is unchanged and unfrozen' (((Get-DenyCount $B) -eq 0) -and ((Hash (Join-Path $BD 'index.js')) -eq (Hash (Join-Path $T 'pdf-stdio-wrap.js'))) -and (Test-Path -LiteralPath (Join-Path $BD 'index.real.js')))
    $o = Run (S 'verify-pdf-read.ps1') -Env @{ LOCALAPPDATA = $null; APPDATA = $null }
    Check '3.4 LOCALAPPDATA and APPDATA both unset: says so' (Has $o 'tried: nothing - LOCALAPPDATA and APPDATA are both unset')
    Copy-Tree $LE $RE
    $o = Run (S 'verify-pdf-read.ps1') -Env @{ LOCALAPPDATA = $E }
    Check '3.5 the APPDATA location is used when LOCALAPPDATA has none' (Has $o "Extension dist : $RD  (from the app's extension folder)")
    $o = Run (S 'install-pdf-read.ps1') @('-Dist', $XD) -NoStub
    $claudeUp = @(Get-Process -Name Claude -ErrorAction SilentlyContinue | Where-Object { $_.Threads.Count -gt 0 }).Count -gt 0
    Check '3.6 install: the unstubbed app-running guard refuses while the app runs (skipped when it is closed)' ((-not $claudeUp) -or (Has $o 'The Claude app is RUNNING'))
    $guardLine = 'if (@(Get-Process -Name Claude -ErrorAction SilentlyContinue | Where-Object { $_.Threads.Count -gt 0 }).Count -gt 0) {'
    $guardIn = @('install-pdf-read.ps1', 'uninstall-pdf-read.ps1', 'verify-pdf-read.ps1' | Where-Object { @(Get-Content -LiteralPath (S $_) | Where-Object { $_.Trim() -ceq $guardLine }).Count -eq 1 })
    Check '3.6 install, uninstall and verify each hold the same app-running test, once' ($guardIn.Count -eq 3)
    $Xg = Get-Snap $X
    foreach ($s in 'install-pdf-read.ps1', 'uninstall-pdf-read.ps1') {
        $o = Run (S $s) @('-Dist', $XD) -ProcStub live
        Check "3.6 $($s): a Claude process with a thread stops it, nothing changed" ((Has $o 'The Claude app is RUNNING') -and (Same-Snap $Xg (Get-Snap $X)))
    }
    $o = Run (S 'install-pdf-read.ps1') @('-Dist', $XD, '-Directories', $GR) -ProcStub husk
    Check '3.6 install: a Claude process with no threads (a husk) does not stop it' ((-not (Has $o 'is RUNNING')) -and (Has $o 'Already installed and healthy') -and (Same-Snap $Xg (Get-Snap $X)))
    $o = Run (S 'uninstall-pdf-read.ps1') @('-Dist', $XD) -ProcStub husk
    Check '3.6 uninstall: a husk does not stop it' ((-not (Has $o 'is RUNNING')) -and (Test-Pristine $XD))
    $o = Run (S 'install-pdf-read.ps1') @('-Dist', $XD, '-Directories', $GR) -ProcStub husk
    Check '3.6 install with a husk, after that uninstall: byte-identical to before' (Same-Snap $Xg (Get-Snap $X))
    Copy-Item -LiteralPath (Join-Path $XD 'index.real.js') -Destination (Join-Path $XD 'index.js') -Force
    $Xw = Get-Snap $X
    $o = Run (S 'verify-pdf-read.ps1') @('-Dist', $XD, '-Fix') -ProcStub live
    Check '3.6 verify -Fix: a Claude process with a thread stops it, nothing changed' ((Has $o '-Fix requested but the Claude app is RUNNING') -and (Same-Snap $Xw (Get-Snap $X)))
    $o = Run (S 'verify-pdf-read.ps1') @('-Dist', $XD, '-Fix') -ProcStub husk
    Check '3.6 verify -Fix: a husk does not stop it; the wrapper is back, as before' ((-not (Has $o 'is RUNNING')) -and (Has $o 'STATE: HEALTHY - local PDF read access is ON.') -and (Same-Snap $Xg (Get-Snap $X)))
    $o = Run (S 'install-pdf-read.ps1') -FromText -NoStub
    Check '3.7 install run as text, with no script folder: refused' (Has $o 'Run this as a script file')
    $o = Run (S 'install-pdf-read.ps1') @('-Dist', 'C:\a|b\dist')
    Check '3.8 install -Dist <illegal characters>: refused cleanly' ((Has $o 'Could not find') -and -not (Has $o 'Exception'))
    $o = Run (S 'verify-pdf-read.ps1') @('-Dist', 'C:\a|b\dist')
    Check '3.8 verify -Dist <illegal characters>: refused cleanly' ((Has $o 'STATE: NO EXTENSION') -and -not (Has $o 'Exception'))
    $used = @([System.IO.DriveInfo]::GetDrives() | ForEach-Object { $_.Name.Substring(0, 1).ToUpper() })
    $free = @([char[]](71..90) | ForEach-Object { "$_" } | Where-Object { $used -notcontains $_ })[0]
    $o = Run (S 'install-pdf-read.ps1') @('-Dist', "$($free):\x\dist")
    Check "3.9 install -Dist <missing drive $($free):>: refused cleanly" ((Has $o 'Could not find') -and -not (Has $o 'Exception'))
    $o = Run (S 'install-pdf-read.ps1') @('-Dist', $XD, '-Directories', (Join-Path $E 'no-such-folder'))
    Check '3.10 install -Directories <missing folder>: refused, nothing changed' (Has $o 'is not an existing folder')
    $o = Run (S 'install-pdf-read.ps1') @('-Dist', $XD, '-Directories', '')
    Check '3.10 install -Directories <empty name>: refused, nothing changed' (Has $o 'an empty folder name was given')
    $o = Run (S 'install-pdf-read.ps1') @('-Dist', $XD, (Join-Path $E 'stray'))
    Check '3.10 a stray positional value is refused instead of binding to -Dist' ((Has $o 'positional parameter') -or (Has $o 'A positional parameter cannot be found'))
    Check '3.11 no refusal changed either copy' ((Same-Snap $Xs (Get-Snap $X)) -and (Same-Snap $Ls (Get-Snap $LE)))

    Write-Host "== 4 a relocated toolkit (a second copy with no backups)"
    $o = Run (S 'uninstall-pdf-read.ps1') @('-Dist', $XD)
    Check '4.0 pristine before the relocated install' (Test-Pristine $XD)
    $tb = Get-Snap (Join-Path $T 'backups')
    $o = Run (Join-Path $T2 'install-pdf-read.ps1') @('-Dist', $XD, '-Directories', $GR)
    Check '4.1 prints its own folder, installs its own wrapper, links itself' ((Has $o "Toolkit       : $T2") -and (Test-Installed $XD $T2))
    $bakOk = $true
    foreach ($n in @($EXPECT | ForEach-Object { $_.File } | Select-Object -Unique)) {
        $bk = Join-Path $T2 "backups\$n.orig-$ver"
        if ((Hash $bk) -ne (Hash (Join-Path $P $n))) { $bakOk = $false }
        try { if ((Get-Content -LiteralPath "$bk.sha256" -Raw).Trim() -ne (Hash (Join-Path $P $n))) { $bakOk = $false } } catch { $bakOk = $false }
    }
    Check '4.1 backs up into its own backups folder, sidecars correct' $bakOk
    Check '4.1 the other toolkit copy untouched' (Same-Snap $tb (Get-Snap (Join-Path $T 'backups')))
    $o = Run (Join-Path $T2 'uninstall-pdf-read.ps1') @('-Dist', $XD)
    Check '4.2 its uninstall returns the copy to pristine' (Test-Pristine $XD)

    Write-Host "== 5 the wrapper itself, started under node against the copy"
    $o = Run (S 'install-pdf-read.ps1') @('-Dist', $XD, '-Directories', $GR)
    New-Item -ItemType Directory -Force -Path (Join-Path $R 'Claude\logs') | Out-Null
    $tLog = Join-Path $T 'pdf-read.log'
    $aLog = Join-Path $R 'Claude\logs\pdf-read.log'
    $err = Start-Wrapper $XD
    $s = Get-LastSession $tLog
    Check '5.1 linked: reports the toolkit on stderr and logs into it' (($err.Contains("toolkit=$T log=$tLog")) -and $s.Contains("[wrap] toolkit=$T") -and $s.Contains('(diag=false)'))
    Check '5.1 the granted folder is registered by the server and kept in its list' ($s.Contains('FIX ACTIVE') -and $s.Contains("Registered local directory: $GR") -and $s.Contains(('read access: ' + (ConvertTo-Json @($GR) -Compress))))
    Check '5.1 the session header names its process' ($s -match '==== SESSION \S+  pid=\d+  \(diag=false\)')
    New-Item -ItemType File -Force -Path (Join-Path $T 'DIAG-ON.flag') | Out-Null
    $err = Start-Wrapper $XD
    Check '5.2 DIAG-ON.flag in the linked toolkit turns on the full log' ((Get-LastSession $tLog).Contains('(diag=true)'))
    Remove-Item -LiteralPath (Join-Path $T 'DIAG-ON.flag') -Force
    $err = Start-Wrapper $XD -Env @{ PDF_WRAP_DIAG = '1' }
    Check '5.3 PDF_WRAP_DIAG=1 works for a wrapper started by hand' ((Get-LastSession $tLog).Contains('(diag=true)'))
    $goneDir = Join-Path $W 'gone\granted'
    Set-Link $XD ((([ordered]@{ toolkit = $T; directories = @($GR, $goneDir) }) | ConvertTo-Json -Compress) + "`n")
    $err = Start-Wrapper $XD
    $s = Get-LastSession $tLog
    Check '5.4 a granted folder that does not exist is skipped and named, and never created' ($s.Contains('skipped, not existing folders') -and $s.Contains("Registered local directory: $GR") -and -not (Test-Path -LiteralPath (Join-Path $W 'gone')))
    $tSize = (Get-Item -LiteralPath $tLog).Length
    Remove-Item -LiteralPath (Join-Path $XD 'pdf-local-read.json') -Force
    $err = Start-Wrapper $XD
    Check '5.5 no link: says so, logs to the app logs folder derived from APPDATA, grants no folder of its own' ($err.Contains('toolkit=NOT FOUND (no pdf-local-read.json beside the wrapper)') -and (Get-LastSession $aLog).Contains('toolkit=NOT FOUND') -and (Get-LastSession $aLog).Contains('(no folders of its own)') -and ((Get-Item -LiteralPath $tLog).Length -eq $tSize))
    $gone = Join-Path $W 'gone\toolkit'
    Set-Link $XD ((@{ toolkit = $gone } | ConvertTo-Json -Compress) + "`n")
    $err = Start-Wrapper $XD
    Check '5.6 a link to a folder that is gone: says so, and never recreates it' ($err.Contains('the toolkit folder it names does not exist') -and -not (Test-Path -LiteralPath (Join-Path $W 'gone')))
    Set-Link $XD "not json`n"
    $err = Start-Wrapper $XD
    Check '5.7 an unreadable link: says so' ($err.Contains('pdf-local-read.json is not valid JSON'))
    Remove-Item -LiteralPath (Join-Path $XD 'pdf-local-read.json') -Force
    $err = Start-Wrapper $XD -Env @{ APPDATA = $E }
    Check '5.8 no toolkit and no app logs folder: logs beside itself' ((Get-LastSession (Join-Path $XD 'pdf-read.log')).Contains('toolkit=NOT FOUND'))

    Write-Host "== 6 the roots fix, through the server's own fileUrlToPath"
    $urls = @('file:///C:/x', 'file://C%3A%5Cy', 'file:///tmp/z', 'computer:///C:/w')
    $o = Run (S 'uninstall-pdf-read.ps1') @('-Dist', $XD)
    Check '6.0 the copy is pristine again' (Test-Pristine $XD)
    $before = Invoke-FileUrlToPath $XD $urls
    Check '6.1 control: the unpatched server turns file:///C:/x into /C:/x' (($before.Count -eq 4) -and ($before[0] -ceq 'OK /C:/x'))
    $o = Run (S 'install-pdf-read.ps1') @('-Dist', $XD, '-Directories', $GR)
    $after = Invoke-FileUrlToPath $XD $urls
    Check '6.2 patched: file:///C:/x becomes C:/x' (($after.Count -eq 4) -and ($after[0] -ceq 'OK C:/x'))
    Check '6.3 patched: the encoded form the server makes itself is unchanged' (($after[1] -ceq $before[1]) -and ($after[1] -ceq 'OK C:\y'))
    Check '6.4 patched: a path with no drive letter is unchanged' (($after[2] -ceq $before[2]) -and ($after[2] -ceq 'OK /tmp/z'))
    Check '6.5 patched: computer:///C:/w becomes C:/w' ($after[3] -ceq 'OK C:/w')

    Write-Host "== 7 the client's roots and list_pdfs, end to end (MCP clients of the wrapped and the patched server)"
    $R1 = Join-Path $W 'roots\one'
    $R2 = Join-Path $W 'roots\two'
    foreach ($d in $R1, $R2) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    $x = Invoke-RootsClient $XD $R1 $R2
    $first = @($x.first); $second = @($x.second)
    Check '7.1 the server asked for its roots twice, and list_pdfs answered both times' (($null -ne $x) -and ($x.rootsAsked -eq 2) -and (-not $x.error) -and ($null -ne $x.first) -and ($null -ne $x.second))
    Check '7.2 the first root is readable, beside the granted folder' (($first -contains $GR) -and ($first -contains $R1))
    Check '7.3 after the roots change: the new root is readable, the old one no longer is, the granted folder still is' (($second -contains $GR) -and ($second -contains $R2) -and -not ($second -contains $R1))
    $s = Get-LastSession $tLog
    Check '7.4 the log shows the kept folders at the first clear(), and the root the server allowed' ($s.Contains('allowedLocalDirs.clear() #1: kept the folders the server was started with') -and $s.Contains("Root directory allowed: $R1"))
    $keep = Join-Path $RUN 'server.js.installed'
    Copy-Item -LiteralPath (Join-Path $XD 'server.js') -Destination $keep -Force
    Copy-Item -LiteralPath (Join-Path $P 'server.js') -Destination (Join-Path $XD 'server.js') -Force
    $c = Invoke-RootsClient $XD $R1 $R2
    Copy-Item -LiteralPath $keep -Destination (Join-Path $XD 'server.js') -Force
    Check '7.5 control: with the unpatched server.js no root ever becomes readable, and the granted folder stays' (($null -ne $c) -and ($c.rootsAsked -eq 2) -and (-not $c.error) -and ((@($c.first) -join '|') -ceq $GR) -and ((@($c.second) -join '|') -ceq $GR))
    $sample = Join-Path $GR 'sample.pdf'
    [System.IO.File]::WriteAllText($sample, "%PDF-1.4`n%%EOF`n")
    $driveRoot = [System.IO.Path]::GetPathRoot($GR)
    $lc = Invoke-NodeJson $LIST_CHECK 'list-check.mjs' @((Join-Path $XD 'server.js'), $GR)
    Check '7.6 list_pdfs lists the granted folder and allows the whole drive, but never reads the drive''s root' (($null -ne $lc) -and (-not $lc.error) -and (@($lc.walked).Count -eq 0) -and (@($lc.allowedDirectories) -contains $driveRoot) -and (@($lc.localFiles).Count -eq 1))
    $noList = Join-Path $XD 'server.nolist.js'
    $listPatch = $PATCHES | Where-Object { $_.Key -eq 'list' }
    [System.IO.File]::WriteAllBytes($noList, $latin1.GetBytes((Undo-Patch $listPatch $latin1.GetString([System.IO.File]::ReadAllBytes((Join-Path $XD 'server.js'))))))
    $lc0 = Invoke-NodeJson $LIST_CHECK 'list-check.mjs' @($noList, $GR)
    Remove-Item -LiteralPath $noList -Force
    Remove-Item -LiteralPath $sample -Force
    Check '7.7 control: with the list fix undone, list_pdfs reads the drive''s root to walk it' (($null -ne $lc0) -and (-not $lc0.error) -and (@($lc0.walked) -contains $driveRoot) -and (@($lc0.localFiles).Count -eq 1))
    Check '7.8 the copy is back in its installed state' (Test-Installed $XD $T)

    Write-Host "== 8 an incomplete extension folder (a copy at the default location, under another LOCALAPPDATA)"
    $gEnv = @{ LOCALAPPDATA = $G }
    Copy-Tree $LE $GE
    $o = Run (S 'verify-pdf-read.ps1') -Env $gEnv
    Check '8.1 control: the complete copy is reported complete, and OFF' ((Has $o "Extension dist : $GD  (from the app's extension folder)") -and (Has $o 'Extension files: complete') -and (Has $o 'STATE: OFF'))
    $held = Join-Path $W 'held'
    foreach ($f in $OWN) {
        $full = Join-Path $GE $f
        Move-Item -LiteralPath $full -Destination $held
        $o = Run (S 'verify-pdf-read.ps1') -Env $gEnv
        Check "8.2 verify: a copy missing only $f is INCOMPLETE and names exactly that file" ((Has $o 'STATE: INCOMPLETE') -and (@($o | Where-Object { $_.Trim() -eq "Extension files: MISSING $f" }).Count -eq 1))
        Move-Item -LiteralPath $held -Destination $full
    }
    $o = Run (S 'install-pdf-read.ps1') -Env $gEnv
    Check '8.3 control: the complete copy installs, HEALTHY' ((Has $o 'STATE: HEALTHY - local PDF read access is ON.') -and (Test-Installed $GD $T))
    # The state a failed rollback by the app's updater can leave: only dist\index.js of the new version, which an
    # install then wrapped. Nothing else of the extension's remains.
    Get-ChildItem -LiteralPath $GE -Force | Where-Object { $_.Name -ne 'dist' } | Remove-Item -Recurse -Force
    Get-ChildItem -LiteralPath $GD -Force | Where-Object { @('index.js', 'index.real.js', 'pdf-local-read.json') -notcontains $_.Name } | Remove-Item -Recurse -Force
    $allMissing = $OWN -join ', '
    $o = Run (S 'verify-pdf-read.ps1') -Env $gEnv
    Check '8.4 verify on a gutted folder: INCOMPLETE, all five files named, never HEALTHY' ((Has $o 'STATE: INCOMPLETE') -and (Has $o "Extension files: MISSING $allMissing") -and -not (Has $o 'STATE: HEALTHY'))
    $g0 = Get-Snap $GE
    $o = Run (S 'verify-pdf-read.ps1') @('-Fix') -Env $gEnv
    Check '8.5 verify -Fix: INCOMPLETE, and it does not run the installer' ((Has $o 'STATE: INCOMPLETE') -and -not (Has $o 'running install-pdf-read.ps1') -and (Same-Snap $g0 (Get-Snap $GE)))
    foreach ($s in 'install-pdf-read.ps1', 'uninstall-pdf-read.ps1') {
        $o = Run (S $s) -Env $gEnv
        Check "8.6 $($s): refused, the missing files named, nothing changed" ((Has $o "Refusing $GD (from the app's extension folder)") -and (Has $o "missing files of its own: $allMissing") -and (Same-Snap $g0 (Get-Snap $GE)) -and ((Get-DenyCount $GE) -eq 0))
    }
    $o = Run (S 'lock-pdf-read.ps1') -Env $gEnv
    Check '8.7 lock: refused, the folder left unfrozen and unchanged' ((Has $o 'Refusing: the extension folder is missing files of its own') -and ((Get-DenyCount $GE) -eq 0) -and (Same-Snap $g0 (Get-Snap $GE)))
    $o = Run (S 'lock-pdf-read.ps1') @('-Fix') -Env $gEnv
    Check '8.7 lock -Fix: refused, the folder left unfrozen and unchanged' ((Has $o 'Refusing: the extension folder is missing files of its own') -and ((Get-DenyCount $GE) -eq 0) -and (Same-Snap $g0 (Get-Snap $GE)))
    $o = Run (S 'lock-pdf-read.ps1') @('-Status') -Env $gEnv
    Check '8.8 lock -Status: reports the missing files, changes nothing' ((Has $o "Own files  : MISSING $allMissing") -and (Same-Snap $g0 (Get-Snap $GE)))
    # Freeze it with lock-pdf-read.ps1's own three rules, as a freeze applied before the gutting would have.
    icacls "$GE" /deny "${me}:(OI)(IO)(DE,WD,AD)" /C /Q 2>&1 | Out-Null
    icacls "$GE" /deny "${me}:(CI)(IO)(DE,DC)" /C /Q 2>&1 | Out-Null
    icacls "$GE" /deny "${me}:(DE,DC)" /C /Q 2>&1 | Out-Null
    $gDeny = Get-DenyCount $GE
    $o = Run (S 'lock-pdf-read.ps1') @('-Unlock') -Env $gEnv
    Check '8.9 lock -Unlock still thaws a frozen incomplete folder' (($gDeny -ge 1) -and (Has $o 'THAWED. index.js writable again: True') -and ((Get-DenyCount $GE) -eq 0))

    Write-Host "== 9 the source extension and this toolkit"
    Check '9.1 the source extension is unchanged (dist and root files)' (Same-Snap $live0 (Get-Snap $srcExt))
    Check '9.2 the source extension''s freeze is unchanged' ((Get-DenyCount $srcExt) -eq $liveDeny0)
    Check '9.3 this toolkit is unchanged (logs and flags aside)' (Same-Snap $tk0 (Get-Snap $TK -NoLogs))
}
catch {
    $script:fail++; $script:failed += 'the test itself stopped'
    Write-Host "TEST ERROR: $($_.Exception.Message)" -ForegroundColor Red
    $script:lastOut | Select-Object -Last 15 | ForEach-Object { Write-Host "        | $_" -ForegroundColor DarkGray }
}
finally {
    if ($pushed) { Pop-Location }
    Thaw $W
}

$secs = [int]((Get-Date) - $started).TotalSeconds
Write-Host ""
if ($script:fail -eq 0) {
    Remove-Item -LiteralPath $W -Recurse -Force
    Write-Host "RESULT: PASS - $($script:pass) checks passed in $secs s. Work folder removed." -ForegroundColor Green
    exit 0
}
Write-Host "RESULT: FAIL - $($script:fail) failed, $($script:pass) passed, in $secs s. Work folder kept: $W" -ForegroundColor Red
$script:failed | ForEach-Object { Write-Host "  failed: $_" -ForegroundColor Red }
exit 1
