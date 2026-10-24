# Rowlight 1.0.0 launch review

Branch: `rowlight-launch`. Base: `main` at `444ee37`.
The branch holds the three commits of PR #1 (App Store readiness) and the fixes from this review.
This pull request replaces PR #1.

## Summary

- The App Store target builds, signs with Apple Distribution (team 74W94PA2F4, Pereste Health Inc), and exports a Mac App Store package.
- Validate App passed: `xcrun altool --validate-app` with the App Store Connect API key returned "VERIFY SUCCEEDED with no errors" for the export of commit `4fc0cd8`.
- The review fixed 9 blockers, 19 high findings, and 15 medium findings. 13 medium findings stay open with a recommendation.
- Tests: after the compile fix, 205 tests passed. Now 237 Swift Testing tests and 5 XCTest tests pass (`swift test`). Debug and Release Xcode builds pass.
- Measured on a 1000-page PDF with 2984 highlights (MacBook Pro, M2 Max): open 0.5–0.7 s, search 9 ms median and 16 ms at the 95th percentile, full highlight rebuild 0.1 s.

## PR #1 verification

PR #1 was open, not merged, and nobody had compiled it. Its body says so. Results:

| PR #1 claim | Result |
|---|---|
| Sandboxed book data goes to the iCloud container, not beside the PDF | Correct. `BookStorage.swift` only reads the old `<book>.fa-reader/` folder in the sandbox. |
| Entitlements: sandbox, user-selected read-write, app-scope bookmarks, iCloud Documents, network client | Correct and minimal. The network entitlement is needed for remote images in notes (`Marky/ImageStore.swift:50`). |
| Updater and self-check are absent from the archive | Correct for the updater and SelfCheck. Other debug hooks were still in the binary (B3). |
| Privacy manifest: UserDefaults CA92.1, file timestamp C617.1 and 3B52.1 | Correct. The only file-timestamp call is `Marky/ImageStore.swift:25`. The Release app calls no disk-space, boot-time, or keyboard API. `SelfCheck.swift` calls `systemUptime`, but only under `#if DEBUG`. |
| Display name from `PRODUCT_NAME` | Correct. Commit 92e4f40 sets `Rowlight`. The executable stays `FAReader`, which is valid. |
| Marky has no known upstream or license | Resolved. Marky was written in this repo (commit f00b2b4, Parker with Claude). It is first-party code. The README now says so. |
| md4c is MIT | Correct, but the app showed no acknowledgement (B5). |
| Tests in `tests/BookStorageTests.swift` | They did not compile until the `SyncFolder` fix (B1). They pass now. |
| Owner checklist step 7: leave `MARKETING_VERSION` at 1.0 | Changed to 1.0.0 as the launch goal requires. |

## Blocker

| # | Finding | Location | Change |
|---|---|---|---|
| B1 | The branch did not compile: `OpenedBookData` is `Equatable` but its `SyncFolder` field was not. | `Sources/FACore/SyncFolder.swift:3` | Fixed. `SyncFolder` is `Equatable`. |
| B2 | Version was 1.0. | `Config/Brand.xcconfig:8` | Fixed. `MARKETING_VERSION = 1.0.0`. |
| B3 | Debug and test code shipped in the App Store binary: `MARKY_TRACE`, `MARKY_SNAPSHOT`, `--pdf`, `--measure-open`, `--measure-search`, `--exit`, `--visible`, `--print-update`, and their `print` calls. | `Sources/FAReader/AppModel.swift:257, 267, 309, 350, 623, 648, 741`, `FAReaderApp.swift:32, 48`, `Marky/Debug.swift:1` | Fixed. These are behind `#if !APPSTORE`. SelfCheck and `abandonSearch` stay behind `#if DEBUG`. `strings` and `nm` on the Release binary find none of them. The direct-download build keeps the flags that the README documents. |
| B4 | The updater key `FAUpdateRepo` was in the App Store Info.plist. | `Resources/Info.plist`, `scripts/build-app.sh:31` | Fixed. The key is removed. The direct-download script adds it. |
| B5 | No in-app acknowledgement for md4c (MIT). | `Resources/Credits.html:17` | Fixed. The About panel shows the md4c copyright and the MIT text. |
| B6 | The Help menu showed "Help isn't available". The app had no support link. | `Sources/FAReader/FAReaderApp.swift:155` | Fixed. Help has "Rowlight Support" and "Privacy Policy". |
| B7 | Signing used the ad hoc identity `-` with iCloud entitlements, and no team. | `FAReader.xcodeproj/project.pbxproj`, `Config/Brand.xcconfig:11` | Fixed. Automatic signing, `DEVELOPMENT_TEAM = 74W94PA2F4`. Team XFD87T8UD7 is a free personal team and cannot use iCloud. |
| B8 | The Xcode Debug build did not compile after the test flags moved behind `!APPSTORE` (the Debug configuration sets `DEBUG APPSTORE`). | `Sources/FAReader/AppModel.swift:271` | Fixed. Debug and Release both build. |
| B9 | Archive and Validate App. | `~/Library/Developer/Xcode/Archives/2026-10-24/Rowlight-1.0.0.xcarchive` | Done. The Release archive builds. The App Store export is signed by Apple Distribution: Pereste Health Inc. Validation with the App Store Connect API key (key 3CWB8ZZJ4C) returned "VERIFY SUCCEEDED with no errors". |

## High

| # | Finding | Location | Change |
|---|---|---|---|
| H1 | If a notes file lost its start or end marker, export wrote a new template over all of the user's notes. | `Sources/FACore/MarkdownExport.swift:41` | Fixed. `merge` returns nil and nothing is written. |
| H2 | A notes file that could not be read (not downloaded from iCloud, bad encoding) counted as missing, and a template replaced it. | `MarkdownExport.swift:78`, `AppModel.swift:170` | Fixed. A blocked file is never written or deleted. The download starts. The notes editor is read-only until the file can be read. |
| H3 | The export clean-up step could delete a blocked notes file. | `MarkdownExport.swift:147` | Fixed. A blocked file counts as current. |
| H4 | Notes typed in the last 0.6 s before Quit were lost. | `FAReaderApp.swift:63` | Fixed. Quit saves the notes and waits for the write. |
| H5 | Notes writes and the export wrote the same file on two queues with no order, and a read could run before a queued write. Recent edits could be lost. | `AppModel.swift:1922-2083` | Fixed. Notes writes, notes reads, and the export run in order on one serial queue, off the main thread. The editor is read-only while a notes file loads. |
| H6 | In the sandboxed build, saving a PDF in Preview changed its book ID (SHA-256 of the bytes), and its highlights seemed gone. A PDFKit save also rewrites the PDF trailer ID, so that ID cannot help. | `Sources/FACore/BookStorage.swift:262`, `AppModel.swift:391` | Fixed. A known book ID from the bookmark is kept when the page count matches. An alias record in the container maps the new hash to the old ID for other Macs. Each Mac merges only its own log. |
| H7 | An older app version skipped a newer op kind and still moved its read offset, so it lost that op for good. | `Sources/FACore/Store.swift:353, 375` | Fixed. The offset stops at an unknown kind. A damaged line of a known kind is skipped so it cannot block the log. |
| H8 | A recreated database, or the Application Support fallback, started op numbers at 1 again. Other Macs then dropped the new ops as duplicates. | `Store.swift:166` | Fixed. The next number is `max(stored, last, now in ms) + 1`. |
| H9 | Moving data into the iCloud container skipped a log that already existed there, and its edits were lost. | `BookStorage.swift:159` | Fixed. Missing lines are appended once. ID collisions are counted, not dropped silently. |
| H10 | Migration Assistant copied the device ID to a new Mac, so two Macs wrote one log. | `Sources/FACore/DeviceIdentity.swift:4`, `AppModel.swift:498, 507` | Fixed for the future. A SHA-256 of the hardware UUID is stored locally, and a Mac with a different hash gets a new device ID. The hash never goes to iCloud. A Mac that already has an ID but no stored hash keeps its ID, so two Macs that already share an ID stay shared. |
| H11 | The log flush and log read used the main thread's SQLite connection from a background queue. They could see another thread's open transaction. | `Store.swift:7` | Fixed. They use their own connection. |
| H12 | The first-open text index held one write transaction for the whole book. A highlight then waited up to 5 s and failed with "database is locked". | `Sources/FACore/BookIndex.swift:6` | Fixed. The index commits every 50 pages. |
| H13 | Tidy Overlapping Highlights ran 7.5 s on the main thread (measured, 800 pages). | `Sources/FAReader/TidyPlanner.swift`, `AppModel.swift:1207, 1227` | Fixed. Planning runs in the background. The result is dropped if the book or highlights change, also after the confirm dialog. |
| H14 | Writes into the iCloud container skipped `NSFileCoordinator`. | `BookStorage.swift:65`, `MarkdownExport.swift:92` | Fixed. Book records, copied logs, exports, and notes use coordinated writes off the main thread. |
| H15 | A stale security-scoped bookmark was re-created after access stopped, so the re-creation failed. | `AppModel.swift:537` (`restoredLastBook`), `:1565` (`openLinkedBook`), recents open | Fixed. It is re-created while access is active. |
| H16 | Cmd-Delete deleted the selected highlight while the user typed in the notes editor or a text field. | `AppModel.swift:1248`, `FAReaderApp.swift:129` | Fixed. The action checks for a text first responder when it runs. The menu item is also disabled. |
| H17 | New App Store users saw an "Older versions kept each book's highlights…" alert. | `AppModel.swift:622` (`maybeOfferSidecarImport`) | Fixed. The alert is not in the App Store build. File > Import Highlights from Folder… stays. |
| H18 | A Preview import scan could finish after a book switch and import into the wrong book. | `AppModel.swift:1726` | Fixed. A stale result is dropped and the sheet closes with a message. |
| H19 | File > Export Markdown ran on the main thread, outside the serial queue, and did not save the open notes first. A queued notes write could land between the export's read and write and be undone. | `AppModel.swift:1790` | Fixed. The command saves the notes, then runs the export on the same serial queue. |

## Medium

### Fixed

| Finding | Location | Change |
|---|---|---|
| An append after a crash joined the next line to a torn last line. | `SyncFolder.swift:36` | A newline is written first if the file does not end in one. The append calls `synchronize()`. |
| No schema version. A corrupt `fa.sqlite` blocked the book. | `Sources/FACore/Database.swift:45-70` | `PRAGMA user_version` with ordered steps. A newer schema gives a plain message. On corruption (`SQLITE_CORRUPT`, `SQLITE_NOTADB`, or `quick_check` not "ok") the three database files move aside and the store rebuilds from the logs. Nothing is deleted. |
| The index job kept running after another book opened. | `AppModel.swift:703` | It stops when the open book's store changes. |
| History grouped the whole change log on every commit (3 ms each). | `AppModel.swift:1709` | It refreshes only while the History sheet is open. |
| An open failure in the sandbox showed a false "not at this path". | `AppModel.swift:428` (`finishOpen`) | The reason is computed before access stops. |
| Alerts showed raw Swift and SQLite errors. | `AppModel.swift`, `Sources/FACore/OpenFailure.swift` | Plain messages. The detail goes to the log. |
| Bookmark resolution could show UI or mount a volume at launch. | `Sources/FACore/Bookmarks.swift:31` | `.withoutUI` and `.withoutMounting`. |
| A link page number was not range-checked. | `AppModel.swift:1585` (`jump(to:)`) | An out-of-range page opens the book without a jump. |
| Exported notes used `fa-reader://` links (the old name). | `MarkdownExport.swift:13`, `Resources/Info.plist:60`, `Bookmarks.swift:84` | New exports write `rowlight://`. Both schemes open, in any letter case. Old notes keep working. |
| Toolbar items were enabled with no book open. | `ReaderView.swift` toolbar | Disabled until a book opens. |
| Search showed "N results, X ms" and no empty state. | `SidebarView.swift:90` | "No results", "1 result", "N results". |
| The sidebar showed "Synced from 0 other devices". | `SidebarView.swift:68` | Hidden at 0. |
| VoiceOver read color buttons and bar cells as "button", and chapter rows were not reachable. | `ReaderView.swift:328, 460-462`, `SidebarView.swift:57` | Labels and actions added. Chapter rows are plain-style buttons. |
| Undo said "Undo Highlight" while the user typed text. Open Recent was enabled when empty. | `FAReaderApp.swift` | Plain "Undo" for text. Open Recent disabled when empty. |
| Plurals ("1 items"). The import sheet spun forever on a failed scan. | `ImportView.swift`, `HistoryView.swift`, `AppModel.swift` | Fixed. |

### Open (recommendation)

| Finding | Location | Recommendation |
|---|---|---|
| Two Macs that edit the same note at once: the later wall-clock write wins and the other text is not shown. | `Store.swift` (note merge) | Keep both texts on conflict, or show a conflict marker. After launch. |
| iCloud conflict versions of a notes file (`NSFileVersion`) are not merged. iCloud keeps them, so no text is deleted, but the user cannot see them. | `MarkdownExport.swift` | Save each conflict version as a visible copy. After launch. |
| The export folder is keyed by PDF file name. Two books with the same name share files. A renamed PDF starts a new notes file. | `AppModel.swift` (export folder) | Key by book ID. Needs a migration of existing notes files. |
| Export rewrites the front matter, so keys that the user added (Obsidian tags) are removed. | `MarkdownExport.swift` | Keep unknown keys. |
| Remote sync apply and rebuild run on the main thread. Measured 0.1 s at 3000 highlights; the time grows with the log. | `AppModel.swift` sync, `Store.swift` rebuild | Move `Store` behind one serial queue. Needs locks on `maxApplied`, `revision`, `editSession`. After launch. |
| The highlights panel rebuilds on each keystroke in the note editor. | `HighlightsPanel.swift` | Move `noteDraft` and index progress to a separate observable object. |
| Tidy shows no progress for about 7 s on a large book. | `AppModel.swift` | Show the existing busy state. |
| File > Import Highlights from Folder… copies the folder's logs on the main thread. The log read after the copy already runs on `folderQueue`. | `AppModel.swift:1869` (`SidecarMigration.migrate`) | Move the copy to `folderQueue`. It runs only when the user picks a folder. |
| Swift 6 language mode: 71 strict-concurrency warnings (`-strict-concurrency=complete`), 48 before this review. Most new ones are `Store` and FACore value types captured by background closures. `Store` is not `Sendable`. | `AppModel.swift` (44), `Marky/TextViews.swift` (16), others | Change the language mode after launch. Fix `Store` isolation first, then mark the FACore value types `Sendable`. |
| `quick_check` runs on each book open. Its cost grows with database size. It runs off the main thread. | `Database.swift` | Measure on the largest real book. |
| If the database is corrupt, log lines that were not yet flushed are lost (they exist only in that database). | `Store.swift` | Accept, or flush the pending log before each commit returns. |
| SwiftUI does not re-evaluate the enabled state and Undo title when focus moves. The actions check focus when they run. | `FAReaderApp.swift` | Observe the key window's first responder. |
| The copyright says "Parker Smith". The seller is Pereste Health Inc. | `Config/Brand.xcconfig:10` | Owner decision. |

## Nice-to-have

| Finding | Location | Recommendation |
|---|---|---|
| `AppModel.swift` has 2083 lines. | `Sources/FAReader/AppModel.swift` | Split into extensions by job: open, rendering, selection, undo, search, sync, notes. About 55 `private` members must become internal. No unit tests cover `AppModel`. After launch. |
| The highlight color to display color conversion is in five places. `Rect` to `CGRect` is in three. | `AppModel.swift`, `ReaderView.swift`, `SidebarView.swift`, `Thumbnails.swift`, `Marky/MarkdownRenderer.swift` | One helper each. |
| The sidecar import prompt never runs in any build (`!APPSTORE` plus a sandbox check). | `AppModel.swift:622` (`maybeOfferSidecarImport`) | Delete it. |
| The thumbnail crop cache and the page geometry caches have no size limit. The thumbnail image cache already has a limit of 400. | `Thumbnails.swift:42`, `PageGeometry.swift:27, 61, 71` | Use `NSCache` with a cost limit. |
| `HighlightList` does a linear search per change. `Store` makes a JSON decoder per row. | `HighlightList.swift:61`, `Store.swift:117` | Index by ID. Reuse one decoder. |
| Internal names (`FAReader`, `FACore`, `fa-reader-export`, block markers, queue labels). | many | Leave. Old exported files depend on the markers. |
| Window restoration, dark mode on real PDFs, VoiceOver by hand. | — | Not checked at run time. Check on the TestFlight build. |

## Trademarks

- "First Aid" appears only in code comments (`PageGeometry.swift:34, 68`) and test data. "Pathoma" appears only in test data. Users never see these.
- No screenshots are in the repo. Three App Store screenshots (2880x1800) were made with an original 30-page sample PDF, "Cardiovascular Physiology — Lecture Notes", written for this purpose. They were checked by eye: no third-party book, brand, or exam name, no personal paths, and no hashtags.
- The notes pane shows the export front matter, which includes the key `fa-reader-export: 1` (screenshot 3). It is the old internal name, and users can see it. Renaming the key needs the reader to accept both keys, because older notes files use the old one.

## Tests added

Storage, migrations, and sync merge:

- Log reader: an unknown op kind holds the offset; a damaged known kind is skipped; a non-JSON line is skipped.
- Op numbers: above every number in an unread log and in a rebuilt database.
- Database: `user_version` set and migrated in order; a newer version gives a plain error; a garbage file and a damaged data page are moved aside and rebuilt from the logs.
- Sync folder: an append after a torn tail starts a new line.
- Book index: more than one batch stores every page.
- Migration: missing lines appended once; idempotent; collisions counted.
- Book ID: kept after a PDFKit save through the known ID and the alias; a different page count does not inherit; the hash folder wins; an empty alias target is ignored; only this device's log merges.
- Notes export: missing start or end marker, invalid UTF-8, and an iCloud placeholder all leave the file unchanged.
- Links: both schemes, any case. Device ID decisions.

## Owner steps

1. Upload the build. Validate App already passed. Upload from Xcode Organizer (`Rowlight-1.0.0`, 2026-10-24), or ask Claude to upload the validated package with the API key.
   - The Xcode export log says "No provider associated with App Store Connect user". The API key works, but the Apple ID in Xcode has no App Store Connect access for Pereste Health Inc. Add that access if you upload from Organizer.
   - The archive in Organizer is ad hoc signed, because no Mac is registered on the team. The export re-signs it with Apple Distribution. To archive normally, open the project, select team Pereste Health Inc under Signing & Capabilities, and let Xcode register this Mac.
2. In the developer portal, confirm the iCloud container `iCloud.com.parkersmith.fa-reader` exists on the App ID. The distribution profile names it.
3. Decide the copyright holder (`FA_COPYRIGHT` in `Config/Brand.xcconfig`).
4. Increase `CURRENT_PROJECT_VERSION` for each upload.
5. App Store Connect: category Education, encryption exempt, privacy URL https://www.elparko.com/apps/rowlight/privacy/, support URL https://www.elparko.com/apps/rowlight/support/, contact rowlight@proton.me.
6. TestFlight on two Macs with one iCloud account: open a book, highlight, sync, edit a note on each Mac, save the PDF in Preview and reopen it, quit while you type a note.
7. Close PR #1. This pull request contains its commits.
