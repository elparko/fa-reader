# fa-reader

A macOS app for reading, highlighting, and annotating PDF textbooks. Built for First Aid for USMLE Step 1; works with any PDF.
It never writes to the PDF. Highlights and notes are stored in a folder next to each PDF, so every book has its own highlights, history, search index and export.

## Build

    make app      # builds "build/FA Reader.app", signs it ad hoc, registers it with LaunchServices
    make run      # builds and opens the app
    make install  # builds and copies the app to /Applications
    ./scripts/make-icon.sh  # redraws Resources/AppIcon.icns from scripts/make-icon.swift
    make test     # runs the tests
    make clean

Requires macOS 14 or later and the Swift 6 toolchain.

## Install on another Mac

`make dist` builds `build/FA Reader.zip`, which runs on Apple Silicon and Intel Macs with macOS 14 or later.

1. Copy the zip to the other Mac (iCloud Drive, AirDrop, or a USB drive) and double-click it.
2. Drag `FA Reader.app` into Applications.
3. The first time you open it, macOS blocks it because it is not signed with an Apple Developer ID. Open System Settings > Privacy & Security, scroll down, and click Open Anyway next to the FA Reader message. Or run this once in Terminal:

       xattr -dr com.apple.quarantine "/Applications/FA Reader.app"

Highlights sync between Macs through iCloud Drive when both open the same PDF from iCloud Drive. Each Mac writes its own change log in `<book>.fa-reader/changes/` and reads the others' every 5 seconds.

## Which PDF opens

1. `--pdf <path>` on the command line
2. The last PDF you opened
3. `~/Library/Mobile Documents/com~apple~CloudDocs/School/MS1/Textbooks/first aid.pdf`, if it exists
4. An Open dialog

File > Open (Cmd+O) opens another PDF. File > Open Recent lists the last 10 books. You can also drag a PDF onto the app icon, or choose Open With > FA Reader in Finder.

## Where data lives

For `first aid.pdf`, the folder is `first aid.fa-reader/` next to the PDF:

- `changes/<device>.jsonl`: one append-only change log per device. iCloud Drive syncs this folder.
- `local.nosync/fa.sqlite`: search index and current state. Not synced by iCloud. It can be deleted and is rebuilt from the change logs.
- `markdown/`: exported notes, one file per section.

The app reads other devices' logs every 5 seconds and when it becomes active.

## Layout

- The search field is in the toolbar and always works. Cmd+F focuses it.
- The sidebar is hidden by default. Show it with the sidebar button in the toolbar or View > Show Sidebar (Cmd+Ctrl+S). With the sidebar hidden, search results appear in a panel under the search field; with it shown, they appear in the sidebar.
- The button at the top of the sidebar switches between chapters with result text, and page images only (page thumbnails, or result thumbnails while searching).
- Clicking a highlight opens a small popup next to it with its colors, note and Delete. Done or Esc closes it.
- The window works down to about 480 points wide, so half a screen is fine.

## Notes pane

The Notes button in the toolbar (Cmd+Option+N) opens the markdown notes for the section you are reading, next to the PDF. It follows you as you move between sections. It uses the Marky viewer (md4c parser, native TextKit rendering) with three modes: preview, edit and preview side by side, and edit.

Each section file has an automatic highlights block between `<!-- fa-reader:highlights:start -->` and `<!-- fa-reader:highlights:end -->`. The app rewrites that block whenever highlights change. Everything outside it (the `## Notes` part, or anything you add above the block) is yours and is never overwritten. Edits save as you type. Page links in the notes jump the PDF to that highlight.

## Highlighting

Select text and a bar of four color dots pops up above it. Click a color, or press 1 to 4 (yellow, green, pink, blue), and the text is highlighted. Esc or clicking elsewhere closes the bar and leaves the text selected. The bar follows the text when you scroll or zoom.

A drag stays on the line where it started until the mouse moves most of a line height up or down. The text lines in the PDF overlap, so without this a slightly low drag would also select the next line.

The toolbar, next to the zoom buttons, also has a highlighter button and four color dots.

- Select text, then click a color: the text is highlighted in that color.
- Click a highlight, then click a color: the highlight changes color.
- Click a color with nothing selected: highlighter mode turns on with that color. Every selection you make is highlighted when you release the mouse, without the popup. Click the highlighter button or press Esc to turn it off.
- Right-click selected text to highlight it, or right-click a highlight to change its color, edit its note or delete it.

## Keyboard shortcuts

| Keys | Action |
| --- | --- |
| Cmd+1, 2, 3, 4 | Highlight the selected text yellow, green, pink, blue. With a highlight selected and no text selected, change its color. |
| 1, 2, 3, 4 (color popup open) | Highlight the selected text yellow, green, pink, blue |
| Esc (color popup open) | Close the popup |
| Cmd+Delete | Delete the selected highlight |
| Cmd+Shift+N | Edit the note of the selected highlight |
| Cmd+Return | Save the note |
| Cmd+F | Focus the search field |
| Up / Down (in the search field) | Step through results; the page jumps to each one |
| Return (in the search field) | Open the selected result |
| Cmd+G, Cmd+Shift+G | Next, previous result |
| Cmd+Y | History |
| Cmd+Shift+E | Export Markdown |
| Cmd+O | Open a PDF |
| Cmd+= or Cmd++, Cmd+-, Cmd+0, Cmd+9 | Zoom in, zoom out, actual size, fit width |

Notes can contain `#tags`. Search filters by color, section, and tag.

Each search result shows a thumbnail of its page with the match outlined in red. Opening a book-text result highlights every match on that page.

"Go to page" accepts a printed book page (`346`) or a PDF page (`pdf 367`).

## URL scheme

`fa-reader://open?page=<n>&highlight=<id>&pdf=<path>` opens the book at `path` (percent-encoded), goes to PDF page `n` (counting from 1) and selects the highlight. Without `pdf`, it uses the book that is open. Markdown exports use these links.

## History and undo

History lists every editing session with its device, time, and pages. "Undo this session" shows how many changes will be reverted and how many are skipped because later work changed them. A change that touches more than 20 pages asks for confirmation.

## Import from Preview

File > Import from Preview scans the highlights and notes already saved in the PDF by Preview and lists them. Nothing is imported until you press the Import button. Imported Preview annotations are hidden in the app so they do not show twice. The PDF itself is not changed.

Annotations made in rapid runs are grouped as a burst: at least 15 annotations with no more than 3 seconds between one and the next, or annotations on 5 or more different pages within 10 seconds. These usually come from accidental select-all or drag actions. Bursts are excluded by default; tick a burst to include it.

The current First Aid PDF has 49 Preview highlights and 7 text notes, all made one at a time, so the scan finds no bursts in it.

## Markdown export format

One file per section (for example `24 Endocrine.md`), in the book's `markdown/` folder. The files update automatically about a second after any highlight change; File > Export Markdown does the same on demand. If you choose an export folder, each book gets its own subfolder there. Re-running the export rewrites only files whose content changed. It deletes a file it created only when that section has no highlights left and you have written nothing in the file. Files without the `fa-reader-export: 1` line are never touched.

```
---
fa-reader-export: 1
book: "first aid"
section: "Endocrine"
parent: "Section III: High-Yield Organ Systems"
pdf-pages: 349-383
highlights: 12
---
# Endocrine

## p. 346 (PDF 367)
- ==Papillary carcinoma: most prevalent, palpable lymph nodes== (pink) [open](fa-reader://open?page=367&highlight=<id>&pdf=<path>) <!-- fa:<id> -->
  > note text
```

Each highlight line ends with `<!-- fa:<id> -->`, a stable ID another tool can key on.

## Checking the app

    "build/FA Reader.app/Contents/MacOS/FAReader" --pdf <copy of the PDF> --measure-open --exit
    "build/FA Reader.app/Contents/MacOS/FAReader" --pdf <copy of the PDF> --self-check report.json

`--self-check` runs without taking focus. It highlights text with Cmd+1, recolors with Cmd+3, highlights from the color popup with a mouse click and with the 2 key, checks that a drag drifting below its line selects one line, adds a note, searches with each filter, imports from Preview, undoes a session, exports markdown twice, opens a `fa-reader://` link and zooms. It writes pass/fail results to `report.json` and a window snapshot to `report.png`. Run it on a copy of the PDF, because it writes highlights into the folder next to that PDF.

## Updates

Every push to `main` on GitHub (`elparko/fa-reader`, public) runs the tests, builds `FA Reader.zip`, and publishes it as a release named `build-<n>`, where `n` is the commit count. The app checks for a newer build once a day and from FA Reader > Check for Updates. It downloads the zip, replaces itself and restarts.

No GitHub account is needed to update. If the GitHub command-line tool (`gh`) is installed and logged in, the app uses its token, which avoids GitHub's limit of 60 anonymous requests per hour.

## Third-party code

- md4c 0.5.2 (MIT), in `Sources/md4c`.
- Marky Markdown view, in `Sources/FAReader/Marky`.
