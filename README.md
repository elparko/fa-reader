# fa-reader

A macOS app for reading, highlighting, and annotating the First Aid for USMLE Step 1 PDF.
It never writes to the PDF. Highlights and notes are stored in a folder next to the PDF.

## Build

    make app      # builds "build/FA Reader.app", signs it ad hoc, registers it with LaunchServices
    make run      # builds and opens the app
    make install  # builds and copies the app to /Applications
    make test     # runs the tests
    make clean

Requires macOS 14 or later and the Swift 6 toolchain.

## Which PDF opens

1. `--pdf <path>` on the command line
2. The last PDF you opened
3. `~/Library/Mobile Documents/com~apple~CloudDocs/School/MS1/Textbooks/first aid.pdf`, if it exists
4. An Open dialog

File > Open (Cmd+O) opens another PDF.

## Where data lives

For `first aid.pdf`, the folder is `first aid.fa-reader/` next to the PDF:

- `changes/<device>.jsonl`: one append-only change log per device. iCloud Drive syncs this folder.
- `local.nosync/fa.sqlite`: search index and current state. Not synced by iCloud. It can be deleted and is rebuilt from the change logs.
- `markdown/`: exported notes, one file per section.

The app reads other devices' logs every 5 seconds and when it becomes active.

## Keyboard shortcuts

| Keys | Action |
| --- | --- |
| Cmd+1, 2, 3, 4 | Highlight the selected text yellow, green, pink, blue. With a highlight selected and no text selected, change its color. |
| Cmd+Delete | Delete the selected highlight |
| Cmd+Shift+N | Edit the note of the selected highlight |
| Cmd+Return | Save the note |
| Cmd+F | Focus the search field |
| Cmd+Y | History |
| Cmd+Shift+E | Export Markdown |
| Cmd+O | Open a PDF |
| Cmd+= or Cmd++, Cmd+-, Cmd+0, Cmd+9 | Zoom in, zoom out, actual size, fit width |

Notes can contain `#tags`. Search filters by color, section, and tag.

"Go to page" accepts a printed book page (`346`) or a PDF page (`pdf 367`).

## URL scheme

`fa-reader://open?page=<n>&highlight=<id>` opens the app at PDF page `n` (counting from 1) and selects the highlight. Markdown exports use these links.

## History and undo

History lists every editing session with its device, time, and pages. "Undo this session" shows how many changes will be reverted and how many are skipped because later work changed them. A change that touches more than 20 pages asks for confirmation.

## Import from Preview

File > Import from Preview scans the highlights and notes already saved in the PDF by Preview and lists them. Nothing is imported until you press the Import button. Imported Preview annotations are hidden in the app so they do not show twice. The PDF itself is not changed.

Annotations made in rapid runs are grouped as a burst: at least 15 annotations with no more than 3 seconds between one and the next, or annotations on 5 or more different pages within 10 seconds. These usually come from accidental select-all or drag actions. Bursts are excluded by default; tick a burst to include it.

The current First Aid PDF has 49 Preview highlights and 7 text notes, all made one at a time, so the scan finds no bursts in it.

## Markdown export format

One file per section (for example `24 Endocrine.md`). Re-running the export rewrites only files whose content changed and deletes files it created earlier for sections that no longer have highlights. Files without the `fa-reader-export: 1` line are never touched.

```
---
fa-reader-export: 1
section: "Endocrine"
parent: "Section III: High-Yield Organ Systems"
pdf-pages: 349-383
highlights: 12
---
# Endocrine

## p. 346 (PDF 367)
- ==Papillary carcinoma: most prevalent, palpable lymph nodes== (pink) [open](fa-reader://open?page=367&highlight=<id>) <!-- fa:<id> -->
  > note text
```

Each highlight line ends with `<!-- fa:<id> -->`, a stable ID another tool can key on.

## Checking the app

    "build/FA Reader.app/Contents/MacOS/FAReader" --pdf <copy of the PDF> --measure-open --exit
    "build/FA Reader.app/Contents/MacOS/FAReader" --pdf <copy of the PDF> --self-check report.json

`--self-check` runs without taking focus. It highlights text with Cmd+1, recolors with Cmd+3, adds a note, searches with each filter, imports from Preview, undoes a session, exports markdown twice, opens a `fa-reader://` link and zooms. It writes pass/fail results to `report.json` and a window snapshot to `report.png`. Run it on a copy of the PDF, because it writes highlights into the folder next to that PDF.
