# pdf-local-read

Lets Claude open PDFs from your own folders on Windows, through the Claude desktop app's built-in **pdf-viewer**
extension: `list_pdfs` lists them, `display_pdf` opens one in the viewer panel. Without it, pdf-viewer on Windows
refuses every local file. The toolkit also fixes four defects of the viewer panel and one that stops Claude Code from
opening the viewer at all, and keeps `list_pdfs` from crawling a whole drive.

It patches the extension the app installed, in place, and every change is reversible: `uninstall-pdf-read.ps1` puts
back the original files byte for byte.

## Status

| | pdf-viewer 1.7.4 | pdf-viewer 1.7.5 | pdf-viewer 2.0.0 |
|---|---|---|---|
| Every patch has a known anchor (the exact text it replaces) | yes | yes | yes (the schema patch is built in) |
| `test-pdf-read.ps1` passes on a copy | yes | yes | yes |
| Seen working inside the app | yes, 2026-10-19 (desktop app 2.42304.0.0) | yes, 2026-10-19 | yes, 2026-10-19 |

The patch that shows the Download button ("Download fix", below) was added after that, and was seen working inside
the app on 2.0.0 the same day: the button showed, and its Windows Save dialog saved the PDF where it was told to.

npm's `@modelcontextprotocol/server-pdf` 2.0.1, 2.0.2 and 2.0.3 ship 2.0.0's viewer file byte for byte, every patch finds its anchor in them, and they still have the bug below.

**The model's `interact` tool** (which carries `get_text`, `get_screenshot`, `save_as` and the rest) works inside the
app's Code tab on all three versions as of 2026-10-19. It had failed there on 2026-09-26 and 2026-10-14 with
`Viewer never connected ... (no poll within 8s)`; both the app and this toolkit have changed since, and which change
fixed it has not been established.

## Use

Each script prints what it acts on before it changes anything. Open Windows PowerShell 5.1 (built into Windows) or
PowerShell 7 in this folder. Windows refuses to run downloaded scripts by default; this lets them run in that window
only, until it is closed:

```
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

1. Quit the Claude app fully: right-click its icon in the notification area and choose Quit, or, if it shows no icon
   there, close its window. The scripts that change the extension refuse while it runs, and the server reads its files
   only when it starts. A `claude` process with no threads left, which quitting the app can leave behind, does not
   count: it can neither run nor hold a file open.
2. Run `.\install-pdf-read.ps1`. With no arguments it grants your Documents, Downloads and Desktop folders. To choose
   the folders yourself: `.\install-pdf-read.ps1 -Directories 'D:\Papers', 'C:\Users\you\Books'`. That replaces the
   three, so name them too if you want to keep them. `-Directories 'C:\'` grants the whole drive: any PDF on it can
   be opened by its path, and `list_pdfs` lists none of them ("The patches", list fix).
3. Run `.\lock-pdf-read.ps1`, so an update of pdf-viewer cannot silently remove the fix ("Updating pdf-viewer").
4. Start the app.

`verify-pdf-read.ps1` reports the state at any time, with the app open or closed. To remove everything, quit the app
and run `uninstall-pdf-read.ps1`.

Requirements: Windows 10 or 11, and the Claude desktop app with pdf-viewer installed (Settings > Extensions). Node.js
on PATH is needed only by `check-schema-dialect.mjs` (which `verify-pdf-read.ps1` runs, and reports `NOT RUN` without
it) and by `test-pdf-read.ps1`.

## The bug

pdf-viewer opens a local file only if it lies under a folder in its allowed-directories list. That list holds the
folders the server was started with, and the folders the app sends it as MCP roots (MCP, the Model Context Protocol,
is how the app talks to the server; a root is a folder the client lets a server use). Roots arrive as `file://`
addresses such as `file:///C:/Users/you/project`, and the server turns each one into a path with its own
`fileUrlToPath`, which only strips the scheme:

```
file:///C:/Users/you/project  ->  "/C:/Users/you/project"  ->  path.resolve  ->  "C:\C:\Users\you\project"
```

That folder does not exist, the error is swallowed by an empty `catch {}`, and nothing is added. Worse, the function
that reads the roots, `refreshRoots()`, first empties the whole list with `allowedLocalDirs.clear()`, so it also
wipes every folder the server was started with: the folders given on its command line, which in 2.0.0 include its
own "PDF Directories" setting. On Windows the list is empty from the moment the app sends its roots. On macOS and
Linux a path already starts with `/`, so the same code works.

The bug is in the example server `examples/pdf-server` of
[modelcontextprotocol/ext-apps](https://github.com/modelcontextprotocol/ext-apps) (MIT-licensed), which the app
installs as pdf-viewer. It is in 1.7.4, in 2.0.0, and in npm's 2.0.3.

## The fix

Two parts, which work together:

- **The roots fix**, a patch to `dist\server.js` (see "The patches"): on Windows, `fileUrlToPath` drops the slash
  before a drive letter, so `/C:/x` becomes `C:/x`. Nothing else changes: an address with an encoded drive
  (`file://C%3A%5Cx`, the form the server builds itself), and every address on other systems, give the same path as
  before.
- **The wrapper**, `pdf-stdio-wrap.js`. The installer renames the extension's `dist\index.js` to `dist\index.real.js`
  and puts the wrapper in its place, so the app starts the wrapper. In the same process (nothing is spawned, no
  network), it:
  1. adds the granted folders to the server's command line, where its own `main()` registers them;
  2. takes the server's exported `allowedLocalDirs` set and changes what its `clear()` does: it still empties the
     set, then puts back the folders the server was started with, as the set held them at the first `clear()`.
     `refreshRoots()` adds roots only after it clears, so the roots are still replaced each time the app sends a new
     list;
  3. imports `index.real.js`, which runs the server unchanged.

The wrapper finds its toolkit folder and the folders to grant in `dist\pdf-local-read.json` (the toolkit link), which
`install-pdf-read.ps1` writes and `uninstall-pdf-read.ps1` removes. It never creates a folder.

## What Claude may read

The server can open any PDF under these folders:

- **The folders you grant**: those named with `-Directories`, or else your Documents, Downloads and Desktop folders
  (the ones that exist). Installing again without `-Directories` keeps the folders of the earlier install.
- **The folders of the sessions open in the app.** The app sends them to the server as its roots, for a Code session
  its working folder, and sends the list again whenever a session starts or stops (read in the app's code, version
  2.31226.1.0). A folder whose session has ended stops being readable when the next list arrives. If a session's
  folder is a whole drive, so is the grant.
- **On 2.0.0, the extension's own "PDF Directories" setting** (Settings > Extensions > pdf-viewer; its default is
  Documents).

`list_pdfs` lists the PDFs it finds by walking these folders, up to 500 and eight folders deep. A whole drive is not
walked: it stays allowed, and a PDF on it is opened by its path ("The patches", list fix).

**Reading is not all it allows.** The server also lets PDFs be written under the same folders: the viewer's Save
button overwrites the open PDF, and `interact`'s `save_as` can overwrite one or write a new one (the server's
`isWritablePath`, the same in 1.7.4 and 2.0.0). So anything that steers the model, such as instructions hidden in a
web page or in a PDF it reads, could list, open and overwrite PDFs in every folder above. Grant the folders you would
let it work in. A whole drive can be granted (`-Directories 'C:\'`); it is the widest grant there is.

## The patches

Each patch is one exact replacement of a piece of text that must occur exactly once in its file. They are listed in
`patches.ps1`, which every script reads, with one anchor per bundle version where the versions differ (1.7.4, 1.7.5
and 2.0.0 have the same code under different minified names). No two replacements of a patch are alike, since the
uninstall finds which one it applied by its text. Each leaves a marker that only the patched text contains, so every script can tell a
patched file from an unpatched one.

| Patch | File | 1.7.4 | 1.7.5 | 2.0.0 | What it fixes |
|---|---|---|---|---|---|
| roots fix (Windows file:// URLs) | `server.js` | applied | applied | applied | the app's roots never register on Windows ("The bug") |
| list fix (whole drives not walked) | `server.js` | applied | applied | applied | `list_pdfs` crawls a whole drive when one is allowed |
| poll-loop fix | `mcp-app.html` | applied | applied | applied | one failed poll stops the viewer's command loop for good |
| poll-loop fix v2 (hang timeout) | `mcp-app.html` | applied | applied | applied | a poll that never returns hangs the loop for good |
| download fix (widget) and (server dialog) | both | applied | applied | applied | the viewer's Download button did nothing |
| download fix (button shown) | `mcp-app.html` | applied | applied | applied | the viewer hides its Download button unless the app reports download support, which desktop app 2.42304.0.0 does not |
| transcript-restore fix | `mcp-app.html` | applied | applied | applied | after an app restart, viewers in a chat show "Invalid tool result" |
| schema-dialect fix | `server.js` | applied | applied | not needed | Claude Code 2.1.275 and later refuse to call `display_pdf` |

- **Install** applies every patch whose anchor it finds, after saving each original file to `backups\` with its
  SHA-256 (a fingerprint of its exact bytes). A patch with no known anchor (a new version of pdf-viewer) is skipped
  with a warning, never guessed at. The Download fix's two halves go in together or not at all, and the button is
  shown only with both in place.
- **Verify** reports each patch as PATCHED, NOT PATCHED, NOT NEEDED or UNKNOWN PATTERN, a Download fix with only
  one half in place as MISMATCH, and a Download button shown without the fix.
- **Uninstall** reverts each patch by the exact inverse replacement, and leaves a file untouched if a marker remains
  after that.
- The server reads its files once per start, so every patch takes effect at the next app start.

### List fix

`list_pdfs` walks every allowed folder until it has found 500 PDFs, eight folders deep at most. On a whole drive that
is a crawl: on one test machine, walking `C:\` read 61,801 folders in 33 seconds, and the first 500 PDFs it found
were mostly the documentation of installed programs. The fix skips a folder that is the root of a drive (or of a
network share) in that walk. The drive stays allowed, so any PDF on it can still be opened by its path, and
`list_pdfs` still names it among the allowed folders, saying any PDF under it can be displayed. Folders that are not
whole drives are walked as before.

### Poll-loop fix, v1 and v2

The viewer panel gets its work from the server by long-polling (`poll_pdf_commands`: each request waits up to 30
seconds for a command). In the viewer's code, a poll that throws is retried after 2 seconds, but a poll that comes
back as an error result stops the loop for good, and nothing restarts it. The app's host layer produces such results
when its connection hiccups. The panel then stays on screen and clickable, but every command sent to it times out.
v1 makes the error branch retry like the throw branch beside it. v2 abandons a poll that has not returned after 45
seconds and polls again, since one that never returns would hang the loop the same way.

### Download fix

The viewer's Download button hands the PDF to the host through `ui/download-file`, which earlier app builds left
unimplemented (the app logged `download-file not yet wired`), so the click did nothing. The panel runs in a sandboxed
frame from another origin, where the browser's own save routes throw. The fix has two halves, and a third patch that
shows the button:

- **Widget** (`mcp-app.html`): the button calls the server's own `save_pdf` tool with the PDF and a reserved name,
  `::DOWNLOAD-DIALOG::<file name>`.
- **Server** (`server.js`): `save_pdf` recognizes that name, shows the Windows Save dialog (through PowerShell, on
  top, starting in Downloads), writes the PDF where you choose and returns the path. Cancel returns
  `Download cancelled`. The dialog runs alongside the server, so polls keep being answered while it is open.
- **The button shown** (`mcp-app.html`): the viewer shows its Download button only when the app reports download
  support (`downloadFile` among its host capabilities). Desktop app 2.42304.0.0 does not, so 1.7.4, 1.7.5 and 2.0.0
  all hide the button there (read in their code, and seen in the app on 2026-10-19). The patch shows it whenever the
  two halves are in, since they need nothing from the app.

Newer app builds have a route for `ui/download-file`, but 2.42304.0.0 does not report the capability to the viewer;
whether a host that does completes a download itself has not been tested. The fix does not depend on it.

The viewer's Save button is a different thing: it appears once the open PDF has an unsaved change, asks "Overwrite
this file with your annotations and form edits?", and writes over the open file. Download is the one that asks where
to save.

### Transcript-restore fix

When the app reloads a chat after a restart, a tool result's structured data comes back only as JSON text inside its
content. The viewer read only the structured data, found nothing, and showed "Invalid tool result". The fix reads the
JSON text when the structured data is missing. The restored viewer works as a local viewer: the PDF reloads from its
path, and scrolling, search and Download work. It is not reconnected to the model: its old viewer ID ended with the
old server process.

### Schema-dialect fix (1.7.4 and 1.7.5)

Claude Code 2.1.275 and later refuse to call `display_pdf` on 1.7.4 and 1.7.5, before anything reaches the server:

```
Tool 'display_pdf' has an invalid outputSchema: JSON Schema declares an unsupported dialect
("$schema": "http://json-schema.org/draft-07/schema#"). The default validator supports JSON
Schema 2020-12 only
```

Claude Code's MCP client checks a tool's output schema before it sends the call, and accepts only JSON Schema
2020-12. 1.7.4 and 1.7.5 convert their schemas without naming a target, which stamps them draft-07. The patch adds one argument
in the `tools/list` handler of `server.js`:

```
before:  pipeStrategy: "output"
after:   pipeStrategy: "output", target: "draft-2020-12" /* PDF-LOCAL-READ-SCHEMAFIX */
```

Only the `$schema` line of each output schema changes, and the input schemas the model sees stay byte for byte the
same. An older client that checks draft-07 also accepts the 2020-12 schemas. 2.0.0 already converts to 2020-12
(`JSON_SCHEMA_CONVERSION_TARGET = "draft-2020-12"`), so the scripts report the patch as not needed there.

**Its check, `check-schema-dialect.mjs`.** It builds the installed server in its own Node process, asks it for its
tool list over MCP as a client would, and puts every output schema through a model of Claude Code's check. Its
controls: the list must contain `display_pdf` with an output schema, a real `display_pdf` result must pass and broken
ones must fail, and the same schema declared as draft-07 must be refused. 2.0.0 ships no JSON Schema validator, so on
2.0.0 it tests each schema's declared version only, and says so. Read-only; the app can stay open. Exit 0 = PASS, 1 =
FAIL, 2 = could not run; the last line printed is the verdict. Its model of the check is transcribed from Claude Code
2.1.281; if a later Claude Code changes its check, the model must be read again from that version.

## Files

| File | What it does |
|---|---|
| `install-pdf-read.ps1` | Installs the wrapper and its link, applies the patches, then runs `verify-pdf-read.ps1`. App closed. Safe to re-run: it handles a fresh install, an `index.js` replaced since, an install that is already complete, and a toolkit folder that has moved. It thaws and refreezes the extension if it is frozen, and refuses an incomplete extension folder. |
| `pdf-stdio-wrap.js` | The wrapper, installed as the extension's `dist\index.js`. |
| `patches.ps1` | Every patch, with its anchors per version; read by install, verify, uninstall and the test. |
| `lock-pdf-read.ps1` | Freezes the extension folder so an update cannot complete over the fix. `-Status` reports the state, `-Fix` repairs a freeze that stopped holding, `-Unlock` removes it. |
| `verify-pdf-read.ps1` | Reports the state: HEALTHY, OFF, WIPED (the wrapper replaced, `index.real.js` left), HALF (`index.real.js` missing) or INCOMPLETE; the freeze; whether the installed wrapper is this toolkit's current one and linked to it; the granted folders; each patch; and the schema check. `-Fix` reinstalls, except on HALF or INCOMPLETE. |
| `check-schema-dialect.mjs` | The schema-dialect check (above). |
| `uninstall-pdf-read.ps1` | Puts back the original extension and removes the freeze. App closed. Refuses an incomplete extension folder. |
| `test-pdf-read.ps1` | Tests the whole toolkit on copies, never on the installed extension ("Testing the toolkit"). |
| `backups\` | The original files, saved by the installer before its first patch of each version. |
| `pdf-read.log` | The wrapper's log, written while the app runs (size-capped). |

## Finding the extension

Every script finds the pdf-viewer extension's `dist` folder the same way, in this order, and prints the one it chose
and where it came from before it changes anything:

1. `-Dist <folder>` (`--dist <folder>` for `check-schema-dialect.mjs`);
2. else the environment variable `PDF_VIEWER_DIST`;
3. else the app's own extension folder:
   `%LOCALAPPDATA%\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude\Claude Extensions\ant.dir.gh.anthropic.pdf-server-mcp\dist`,
   then the same folder under `%APPDATA%\Claude\`. `Claude_pzs8sxrjxfjjc` is the app's MSIX package family name (MSIX
   is the package format the app is installed in): its publisher sets it, and it is the same on every machine. The
   `%APPDATA%` form is the name the folder has from inside the app, where Windows redirects `AppData\Roaming\Claude`
   into the package;
4. else it stops and lists every location it tried.

A location given with `-Dist` or `PDF_VIEWER_DIST` is used or refused, never swapped for the default, so a mistyped
path cannot land on the installed extension. The freeze acts on the folder above the dist, so the scripts also refuse
a given location whose parent has no `manifest.json`. `install-pdf-read.ps1 -Dist` passes the same dist to the freeze
and to its closing check, and `verify-pdf-read.ps1 -Dist <folder> -Fix` passes it to the installer.

The scripts find this toolkit's own files from their own folder, so the toolkit can be moved as a unit; after a move,
run `install-pdf-read.ps1` from the new folder (app closed) to point the link there.

## Updating pdf-viewer

An update replaces the whole extension folder, wrapper and patches included, so read access silently turns off.
`lock-pdf-read.ps1` stops an update from completing, by denying your own account (the one the app runs as) the right
to delete anything in the folder or rewrite its files. The app updates an extension in two ways:

- **Automatically**, if "Enable auto-updates for extensions" is on (Settings > Extensions > Advanced settings). The
  updater downloads a new version in the background, and at the next app start renames the old folder aside, moves the
  new one in and deletes the old one (read in the app's code, version 2.9939.2.0). While frozen, the delete fails and
  the updater rolls back, on every start. A rollback that itself fails can leave the folder gutted ("An incomplete
  extension folder"). Turning the switch off stops these attempts.
- **The Update button** on the extension's page in Settings > Extensions. It deletes the old folder and moves the new
  version in, which the freeze blocks: lift the freeze first.

To take an update on purpose:

```
lock-pdf-read.ps1 -Unlock  ->  Update in Settings > Extensions (app open)  ->  quit the app  ->  install-pdf-read.ps1  ->  lock-pdf-read.ps1  ->  start the app
```

Keep a copy of the extension folder first if you may want the old version back. A freshly updated folder is a clean
copy, which `verify-pdf-read.ps1` reports as OFF.

**How the freeze works, and why exactly this way.** Each point was measured, not assumed:

- **Deletion has two paths.** A file can be deleted through `DELETE` on the file or `FILE_DELETE_CHILD` on its
  folder, so the freeze denies both.
- **The right letter matters.** Inside parentheses `icacls` wants specific rights, where delete is `DE`. `D` there
  becomes a mask that also denies reading, and the extension could not load. Never use `D` here.
- **Files and folders get different masks.** Files get `(DE,WD,AD)`; folders get `(DE,DC)` only, because on a folder
  `WD` and `AD` mean "add file" and "add subfolder", and the app may need to add files.
- **The whole tree is frozen, not just `index.js`.** `index.real.js` imports `./server.js`, so an updater that
  replaced `server.js` alone would run a new `server.js` under an old `index.real.js`. And a failed removal deletes
  whatever it reaches before the protected file, leaving the extension broken rather than merely not updated.
- **Inherited rules**, set once on the folder, cover the whole tree in about a second; a rule per file across
  `node_modules` would take minutes.
- **The undo is exact.** `-Unlock` removes every deny rule for your account in the folder. A freshly installed
  extension has none of its own, so these are exactly the rules the freeze added. You own these files, so you can
  always change their permissions: the freeze cannot lock you out.

## An incomplete extension folder

A rollback by the app's updater that fails can leave the folder with only part of a version, for example just the new
`dist\index.js`. Before these checks existed, the toolkit acted on such a folder: install wrapped the lone file, the
freeze locked it, and verify reported HEALTHY, because it looked only at `index.js` and `index.real.js`.

So every script now requires, besides `dist\index.js`:

| File | Why |
|---|---|
| `manifest.json` | the app reads it to start the server at all |
| `dist\server.js` | the real server imports it, and the wrapper imports it first |
| `dist\mcp-app.html` | the server serves it as the viewer panel, and four patches live in it |
| `dist\pdfjs-polyfill.js` | `server.js` imports it |
| `node_modules\pdfjs-dist\legacy\build\pdf.mjs` | `server.js` imports it |

The list is the same in install, uninstall, verify and lock; change them together. With a file missing:

- `verify-pdf-read.ps1` prints `Extension files: MISSING ...` and `STATE: INCOMPLETE`, never HEALTHY, and `-Fix` does
  not run the installer, since no script here can bring files back.
- `install-pdf-read.ps1` and `uninstall-pdf-read.ps1` refuse and change nothing.
- `lock-pdf-read.ps1` and `-Fix` refuse; `-Status` reports the missing files; `-Unlock` still thaws, because thawing
  is what lets the folder be replaced.

The repair is to replace the folder with an intact copy, with the app closed: a backup the updater left beside it
(`...backup-<time>`), a copy you kept, or a reinstall of the extension.

## If the freeze itself breaks: `lock-pdf-read.ps1 -Fix`

Asking "is there a deny rule on the folder?" can give the wrong answer: if inheritance were ever broken on a subfolder,
the rule would still be there while the files under it sat open. So `-Status` and `-Fix` do not read the permissions;
they test what is actually possible right now (can this file be read, written, deleted) and act on that. The tests
change nothing: write access is tested by opening the file for writing and closing it, and delete access by opening
a handle that asks for the delete right without deleting.

| State | Meaning | `-Fix` does |
|---|---|---|
| `FROZEN` | reads work, writes and deletes are refused | nothing |
| `THAWED` | not protected | applies the freeze |
| `PARTIAL` | some files protected, some not | removes the freeze entirely, then applies it cleanly |
| `BRICKED` | `index.js` cannot be read, so the extension cannot load | removes the freeze, then applies it again correctly; if `index.js` is still unreadable, leaves it removed and says so |
| `NO WRAPPER` | `index.js` is the original server | refuses: freezing it would keep the bug in place and protect nothing. Run `install-pdf-read.ps1` first |

Before any of these, a folder missing the extension's own files is refused ("An incomplete extension folder").

## Diagnostic logging

The wrapper writes a few lines per server start to `pdf-read.log` in the toolkit folder (or, without a usable link,
to the app's logs folder, else beside itself). Each start begins with a header naming the server's process ID,
`==== SESSION <time>  pid=<process ID>  (diag=false) ====`, and every line after it begins with `pid=<process ID>`:
the app can start more than one pdf-viewer process, and they write to the same log at the same time. The log records the toolkit found, the granted folders, the server's own
messages (`Registered local directory`, `Root directory allowed`), and the first `clear()` with the folders it kept.

For a full log of every message between the app and the server, create an empty file named `DIAG-ON.flag` in the
toolkit folder and restart the app; delete it to go back. The log can grow by megabytes while the flag is there. The
environment variable `PDF_WRAP_DIAG=1` does the same, but only for a wrapper started by hand with `node`: the app gives
its extensions a fixed list of environment variables, and this one is not on it.

## Testing the toolkit

`test-pdf-read.ps1` tests every script end to end without touching the installed extension. It copies the extension
(or the one `-Dist` names) and this toolkit into a work folder (`%TEMP%\pdf-local-read-test`, or `-WorkDir <folder>`)
and runs the real install, verify, uninstall and lock against the copies, in child PowerShell processes whose
`LOCALAPPDATA` and `APPDATA` point into the work folder. Only their "is the app running" check is replaced (to report
no app, a leftover `claude` process with no threads, or a running app), and one check runs it as it is. It also:

- starts the installed wrapper under Node, to test the link, the granted folders, the DIAG switches and where the log
  goes;
- calls the server's own `fileUrlToPath` before and after the roots fix;
- speaks MCP to the wrapped server as the app does, sending it one root and then another, and checks with `list_pdfs`
  which folders it allows each time, with the unpatched `server.js` as the control;
- calls `list_pdfs` with a whole drive and a folder on it allowed, and checks that it lists the folder without walking
  the drive, with the list fix undone as the control. Every read of the drive's root is intercepted and answered with
  an empty listing, so the control does not crawl the disk either;
- builds copies missing each of the extension's own files, which every script must refuse or report.

It hashes the installed extension and this toolkit before and after, and refuses a work folder it did not make, one
that overlaps either of them, or one whose path is too long (Windows paths stop at 260 characters, and `node_modules`
nests deep). If the installed extension is already patched, the test needs its original files in `backups\`, which
the installer saved there.

The app can stay open. It needs Node.js on PATH and takes a few minutes, and prints one PASS or FAIL line per check.
Exit 0 = every check passed and the work folder is removed; 1 = a check failed and the work folder is kept for
inspection; 2 = it could not run. Run it after any change to the toolkit, and, with `-Dist`, on a new version of
pdf-viewer before installing on it (the test works on copies).
