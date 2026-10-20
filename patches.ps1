# patches.ps1 - every patch the toolkit applies to the pdf-viewer extension, in one table.
# Dot-sourced by install-pdf-read.ps1, verify-pdf-read.ps1, uninstall-pdf-read.ps1 and test-pdf-read.ps1, so an
# anchor is written once. Pure ASCII: Windows PowerShell 5.1 reads a .ps1 file as Windows-1252.
#
# Each patch has:
#   Name     what the scripts print
#   File     the dist file it changes: mcp-app.html (the viewer) or server.js (the server)
#   Marker   a string present in the file only when the patch is applied
#   Variants one per bundle version: Orig, the exact text it replaces, which must occur exactly once in the file,
#            and New, its replacement. pdf-viewer 1.7.4, 1.7.5 and 2.0.0 carry the same code under different minified
#            names; npm's 2.0.1 to 2.0.3 ship 2.0.0's viewer file unchanged. No two variants of a patch may share a
#            New text: the uninstall finds the variant to revert by its New text.
#   NotNeeded (optional) a string whose presence means the bundle already has the fix
#
# A patch whose Marker is absent and none of whose Orig strings occurs exactly once is UNKNOWN: the bundle changed,
# and the scripts skip it with a warning instead of guessing.

$DLG_INS = @'
 if (url2 && url2.startsWith("::DOWNLOAD-DIALOG::")) { try { const dlgName = (url2.slice(19) || "document.pdf").replace(/[<>:"/\|?*]/g, "_"); const { execFile } = await import("node:child_process"); const dlgPs = "Add-Type -AssemblyName System.Windows.Forms;$f=New-Object System.Windows.Forms.Form;$f.TopMost=$true;$d=New-Object System.Windows.Forms.SaveFileDialog;$d.FileName='" + dlgName.replace(/'/g, "''") + "';$d.Filter='PDF document (*.pdf)|*.pdf|All files (*.*)|*.*';$d.InitialDirectory=\"$env:USERPROFILE\Downloads\";$d.RestoreDirectory=$true;if($d.ShowDialog($f) -eq [System.Windows.Forms.DialogResult]::OK){[Console]::Out.Write($d.FileName)}"; const dlgOut = await new Promise((res) => { execFile("powershell.exe", ["-NoProfile", "-STA", "-Command", dlgPs], { encoding: "utf8", windowsHide: true, timeout: 600000 }, (e2, so) => res(e2 && !so ? "" : (so || ""))); }); const dlgPath = (dlgOut || "").trim(); if (!dlgPath) { return { content: [{ type: "text", text: "Download cancelled" }], isError: true }; } const dlgBytes = Buffer.from(data, "base64"); await fs.promises.writeFile(dlgPath, dlgBytes); const dlgStat = await fs.promises.stat(dlgPath); return { content: [{ type: "text", text: `Saved to ${dlgPath}` }], structuredContent: { filePath: dlgPath, mtimeMs: dlgStat.mtimeMs } }; } catch (dlgErr) { return { content: [{ type: "text", text: `Download failed: ${dlgErr instanceof Error ? dlgErr.message : String(dlgErr)}` }], isError: true }; } }
'@
$DLG_ANCHOR = 'async ({ url: url2, data }) => {'

$ROOTS_ORIG = "function fileUrlToPath(fileUrl) {`n" + '  return decodeURIComponent(fileUrl.replace(/^(?:file|computer):\/\//, ""));'
$ROOTS_NEW  = "function fileUrlToPath(fileUrl) {`n" + '  const p = decodeURIComponent(fileUrl.replace(/^(?:file|computer):\/\//, "")); /* PDF-LOCAL-READ-ROOTSFIX: on Windows, file:///C:/x decodes to /C:/x */' + "`n" + '  return process.platform === "win32" && /^\/[A-Za-z]:(?:[\/\\]|$)/.test(p) ? p.slice(1) : p;'

$LIST_ORIG = "    for (const dir of allowedLocalDirs)`n" + '      await walk(dir, 0);'
$LIST_NEW  = "    for (const dir of allowedLocalDirs)`n" + '      if (path.parse(dir).root !== dir) await walk(dir, 0); /* PDF-LOCAL-READ-LISTFIX: a whole drive stays allowed but is not walked */'

$PATCHES = @(
    [pscustomobject]@{
        Key = 'poll1'; Name = 'poll-loop fix'; File = 'mcp-app.html'; Marker = '[PDF-LOCAL-READ-POLLFIX] not stopping'
        Variants = @(
            @{ Bundle = '1.7.4'; Orig = 'stopping poll loop:",g),xb=!1;return}'
               New  = 'stopping poll loop:",g),Bg.error("[PDF-LOCAL-READ-POLLFIX] not stopping - retrying in 2s"),await new Promise(I=>setTimeout(I,2e3));continue}' },
            @{ Bundle = '1.7.5'; Orig = 'stopping poll loop:",g),Tb=!1;return}'
               New  = 'stopping poll loop:",g),Bg.error("[PDF-LOCAL-READ-POLLFIX] not stopping - retrying in 2s"),await new Promise(I=>setTimeout(I,2e3));continue/*Tb*/}' },
            @{ Bundle = '2.0.0 to 2.0.3'; Orig = 'stopping poll loop:",g),qb=!1;return}'
               New  = 'stopping poll loop:",g),Ng.error("[PDF-LOCAL-READ-POLLFIX] not stopping - retrying in 2s"),await new Promise(I=>setTimeout(I,2e3));continue}' }
        )
    },
    [pscustomobject]@{
        Key = 'poll2'; Name = 'poll-loop fix v2 (hang timeout)'; File = 'mcp-app.html'; Marker = '__pollTimeout'
        Variants = @(
            @{ Bundle = '1.7.4, 1.7.5'; Orig = 'const g=await eI.callServerTool({name:"poll_pdf_commands",arguments:{viewUUID:ui}});'
               New  = 'const g=await Promise.race([eI.callServerTool({name:"poll_pdf_commands",arguments:{viewUUID:ui}}),new Promise((dlr)=>setTimeout(()=>dlr({__pollTimeout:!0}),45e3))]);if(g&&g.__pollTimeout){Bg.error("[PDF-LOCAL-READ-POLLFIX] poll hung >45s - abandoning and re-polling");continue}' },
            @{ Bundle = '2.0.0 to 2.0.3'; Orig = 'const g=await tI.callServerTool({name:"poll_pdf_commands",arguments:{viewUUID:Ri}});'
               New  = 'const g=await Promise.race([tI.callServerTool({name:"poll_pdf_commands",arguments:{viewUUID:Ri}}),new Promise((dlr)=>setTimeout(()=>dlr({__pollTimeout:!0}),45e3))]);if(g&&g.__pollTimeout){Ng.error("[PDF-LOCAL-READ-POLLFIX] poll hung >45s - abandoning and re-polling");continue}' }
        )
    },
    [pscustomobject]@{
        Key = 'dlwidget'; Name = 'download fix (widget)'; File = 'mcp-app.html'; Marker = '::DOWNLOAD-DIALOG::'
        Variants = @(
            @{ Bundle = '1.7.4, 1.7.5'; Orig = 'e=bR(g);if((i=eI.getHostCapabilities())!=null&&i.downloadFile){const{isError:l}=await eI.downloadFile({contents:[{type:"resource",resource:{uri:`file:///${A}`,mimeType:"application/pdf",blob:e}}]});l&&Bg.info("Download was cancelled or denied by host")}else{'
               New  = 'e=bR(g);let dlDone=!1;try{const dlR=await eI.callServerTool({name:"save_pdf",arguments:{url:"::DOWNLOAD-DIALOG::"+A,data:e}});if(dlR.isError){const dlM=(dlR.content||[]).map(x=>x&&x.text||"").join(" ");/cancel/i.test(dlM)?(dlDone=!0,Bg.info("[PDF-LOCAL-READ-DLFIX] save dialog cancelled by user")):Bg.error("[PDF-LOCAL-READ-DLFIX] server save failed, using fallback:",dlM)}else{dlDone=!0;Bg.info("[PDF-LOCAL-READ-DLFIX] saved via native dialog")}}catch(dlE){Bg.error("[PDF-LOCAL-READ-DLFIX] reroute failed, using fallback:",dlE)}if(dlDone){}else{' },
            @{ Bundle = '2.0.0 to 2.0.3'; Orig = 's=by(g);if((A=tI.getHostCapabilities())!=null&&A.downloadFile){const{isError:e}=await tI.downloadFile({contents:[{type:"resource",resource:{uri:`file:///${i}`,mimeType:"application/pdf",blob:s}}]});e&&Ng.info("Download was cancelled or denied by host")}else{'
               New  = 's=by(g);let dlDone=!1;try{const dlR=await tI.callServerTool({name:"save_pdf",arguments:{url:"::DOWNLOAD-DIALOG::"+i,data:s}});if(dlR.isError){const dlM=(dlR.content||[]).map(x=>x&&x.text||"").join(" ");/cancel/i.test(dlM)?(dlDone=!0,Ng.info("[PDF-LOCAL-READ-DLFIX] save dialog cancelled by user")):Ng.error("[PDF-LOCAL-READ-DLFIX] server save failed, using fallback:",dlM)}else{dlDone=!0;Ng.info("[PDF-LOCAL-READ-DLFIX] saved via native dialog")}}catch(dlE){Ng.error("[PDF-LOCAL-READ-DLFIX] reroute failed, using fallback:",dlE)}if(dlDone){}else{' }
        )
    },
    [pscustomobject]@{
        Key = 'dlshow'; Name = 'download fix (button shown)'; File = 'mcp-app.html'; Marker = 'PDF-LOCAL-READ-DLSHOW'
        Variants = @(
            @{ Bundle = '1.7.4'; Orig = 'Jn.style.display=(s=eI.getHostCapabilities())!=null&&s.downloadFile?"":"none"'
               New  = 'Jn.style.display=(s=eI.getHostCapabilities(),"")/*PDF-LOCAL-READ-DLSHOW: the download fix needs no download support from the app*/' },
            @{ Bundle = '1.7.5'; Orig = 'Ln.style.display=(s=eI.getHostCapabilities())!=null&&s.downloadFile?"":"none"'
               New  = 'Ln.style.display=(s=eI.getHostCapabilities(),"")/*PDF-LOCAL-READ-DLSHOW: the download fix needs no download support from the app*/' },
            @{ Bundle = '2.0.0 to 2.0.3'; Orig = 'J0.style.display=(l=tI.getHostCapabilities())!=null&&l.downloadFile?"":"none"'
               New  = 'J0.style.display=(l=tI.getHostCapabilities(),"")/*PDF-LOCAL-READ-DLSHOW: the download fix needs no download support from the app*/' }
        )
    },
    [pscustomobject]@{
        Key = 'restore'; Name = 'transcript-restore fix'; File = 'mcp-app.html'; Marker = 'PDF-LOCAL-READ-RESTOREFIX'
        Variants = @(
            @{ Bundle = '1.7.4, 1.7.5'; Orig = 'function E7(i){return i.structuredContent}'
               New  = 'function E7(i){if(i.structuredContent)return i.structuredContent;try{const c=i.content,t=typeof c=="string"?c:Array.isArray(c)?c.map(x=>x&&x.text||"").join(""):"";const o=JSON.parse(t);if(o&&o.url)return Bg.info("[PDF-LOCAL-READ-RESTOREFIX] recovered flattened tool result"),o}catch(e){}return i.structuredContent}' },
            @{ Bundle = '2.0.0 to 2.0.3'; Orig = 'function DE(A){return A.structuredContent}'
               New  = 'function DE(A){if(A.structuredContent)return A.structuredContent;try{const c=A.content,t=typeof c=="string"?c:Array.isArray(c)?c.map(x=>x&&x.text||"").join(""):"";const o=JSON.parse(t);if(o&&o.url)return Ng.info("[PDF-LOCAL-READ-RESTOREFIX] recovered flattened tool result"),o}catch(e){}return A.structuredContent}' }
        )
    },
    [pscustomobject]@{
        Key = 'redo'; Name = 'redo fix (Ctrl+Shift+Z)'; File = 'mcp-app.html'; Marker = 'PDF-LOCAL-READ-REDOFIX'
        Variants = @(
            @{ Bundle = '1.7.4, 1.7.5'; Orig = '(i.ctrlKey||i.metaKey)&&i.key==="z"){if(document.activeElement instanceof HTMLInputElement||document.activeElement instanceof HTMLTextAreaElement)return;i.preventDefault(),i.shiftKey?u7():h7();'
               New  = '(i.ctrlKey||i.metaKey)&&(i.key==="z"||i.key==="Z")/*PDF-LOCAL-READ-REDOFIX: with Shift held the key is "Z"*/){if(document.activeElement instanceof HTMLInputElement||document.activeElement instanceof HTMLTextAreaElement)return;i.preventDefault(),i.shiftKey?u7():h7();' },
            @{ Bundle = '2.0.0 to 2.0.3'; Orig = '(A.ctrlKey||A.metaKey)&&A.key==="z"){if(document.activeElement instanceof HTMLInputElement||document.activeElement instanceof HTMLTextAreaElement)return;A.preventDefault(),A.shiftKey?iE():AE();'
               New  = '(A.ctrlKey||A.metaKey)&&(A.key==="z"||A.key==="Z")/*PDF-LOCAL-READ-REDOFIX: with Shift held the key is "Z"*/){if(document.activeElement instanceof HTMLInputElement||document.activeElement instanceof HTMLTextAreaElement)return;A.preventDefault(),A.shiftKey?iE():AE();' }
        )
    },
    [pscustomobject]@{
        Key = 'dlserver'; Name = 'download fix (server dialog)'; File = 'server.js'; Marker = '::DOWNLOAD-DIALOG::'
        Variants = @(
            @{ Bundle = '1.7.4 to 2.0.3'; Orig = $DLG_ANCHOR; New = $DLG_ANCHOR + $DLG_INS }
        )
    },
    [pscustomobject]@{
        Key = 'schema'; Name = 'schema-dialect fix'; File = 'server.js'; Marker = 'PDF-LOCAL-READ-SCHEMAFIX'
        NotNeeded = 'JSON_SCHEMA_CONVERSION_TARGET = "draft-2020-12"'
        Variants = @(
            @{ Bundle = '1.7.4, 1.7.5'; Orig = 'pipeStrategy: "output"'; New = 'pipeStrategy: "output", target: "draft-2020-12" /* PDF-LOCAL-READ-SCHEMAFIX */' }
        )
    },
    [pscustomobject]@{
        Key = 'roots'; Name = 'roots fix (Windows file:// URLs)'; File = 'server.js'; Marker = 'PDF-LOCAL-READ-ROOTSFIX'
        Variants = @(
            @{ Bundle = '1.7.4 to 2.0.3'; Orig = $ROOTS_ORIG; New = $ROOTS_NEW }
        )
    },
    [pscustomobject]@{
        Key = 'list'; Name = 'list fix (whole drives not walked)'; File = 'server.js'; Marker = 'PDF-LOCAL-READ-LISTFIX'
        Variants = @(
            @{ Bundle = '1.7.4 to 2.0.3'; Orig = $LIST_ORIG; New = $LIST_NEW }
        )
    }
)

function Get-AnchorCount([string]$Text, [string]$Anchor) { return ([regex]::Matches($Text, [regex]::Escape($Anchor))).Count }

# The state of one patch in one file's text: PATCHED, PATCHABLE (with the variant that applies), NOTNEEDED or UNKNOWN.
function Get-PatchState($Patch, [string]$Text) {
    if ($Text.Contains($Patch.Marker)) { return [pscustomobject]@{ State = 'PATCHED'; Variant = $null } }
    foreach ($v in $Patch.Variants) {
        if ((Get-AnchorCount $Text $v.Orig) -eq 1) { return [pscustomobject]@{ State = 'PATCHABLE'; Variant = $v } }
    }
    if ($Patch.PSObject.Properties['NotNeeded'] -and $Patch.NotNeeded -and $Text.Contains($Patch.NotNeeded)) { return [pscustomobject]@{ State = 'NOTNEEDED'; Variant = $null } }
    return [pscustomobject]@{ State = 'UNKNOWN'; Variant = $null }
}

# Reverts every variant of the patch found applied. Returns the new text; the caller refuses to write when a marker
# remains afterwards, since that means an applied segment no longer matches any known replacement.
function Undo-Patch($Patch, [string]$Text) {
    foreach ($v in $Patch.Variants) { if ($Text.Contains($v.New)) { $Text = $Text.Replace($v.New, $v.Orig) } }
    return $Text
}
