# ADB test harness (`android_test/`)

Black-box tests for DocScan driven over `adb` against a real phone. Nothing here
imports Flutter: the app is treated exactly as a user treats it — taps, labeled
elements from the semantics tree, and screenshots.

## Prerequisites

- One device connected (`adb devices` shows it). Only `com.docscan.docscan_app`
  is ever operated.
- Node (no dependencies — the harness is plain `.cjs`).
- The fixtures must exist on the phone before any import test:

```
dart run tool/make_scan_fixtures.dart 6 android_test/fixtures   # generate + self-check
node android_test/setup.cjs push                               # push + media scan
```

`make_scan_fixtures.dart` does not just write JPEGs: every image is fed back
through the real pipeline, and it fails if the upright page is not cropped or the
blank page is not reported `not_found`. A passing fixture set is proof the test
input is valid, so a later failure means the app, not the data.

## Running

```
node android_test/probe.cjs                 # survey the build, print UI-string drift
node android_test/run.cjs smoke             # is the build alive at all
node android_test/run.cjs system            # core flows: import -> crop -> export -> library
node android_test/run.cjs acceptance        # user-facing promises (naming, A4, offline, upgrade)
node android_test/run.cjs scale             # many documents: pagination, jank, memory
node android_test/run.cjs smoke system acceptance scale
```

Each run writes `android_test/reports/<timestamp>-<suite>/report.md`, `report.json`
and the numbered screenshots. Reports and fixtures are git-ignored on purpose:
they contain the device serial and real document titles.

**Run `probe.cjs` first after any UI change.** Every visible string the suites tap
lives in `ui.cjs`; the probe walks the screens and lists drift, instead of a suite
dying on a bare "element not found".

## Knobs

| env | default | meaning |
| --- | --- | --- |
| `ADB_PATH` | auto | adb binary location |
| `DOCS_TARGET` | `20` | how many documents `scale` seeds (one costs ~1 min of real import + export) |
| `FIXTURE_PAGES` | `6` | pages in the large-session memory case |
| `COLD_START_BUDGET_MS` | `2500` | smoke start-up budget |
| `DOCSAN_APK` | unset | APK for `acceptance` A10 to upgrade-install over the running build |

Seeding and exporting write into the phone's real library, so `scale` ends with
S11 and `acceptance` with A12, both of which delete exactly what their own run
created through 多选 → 删除 — the same path a user has, which that also proves.

`flows.deleteSeeded` will not delete on its own arithmetic. It stops unless the
toolbar counter says `已选 N` for the N rows it tapped, the confirm dialog names
the same N, and the library count drops by exactly N. Cases that know the whole
title pass `{exact: true}`: auto-generated names are prefixes of each other, so
`10月25日 扫描 3` also matches document 30, which may be the user's.

## What "SKIP" means here

The installed release APK is not debuggable, so `run-as` cannot reach the app's
private files. Any case that wants to read the produced PDF itself (page count,
A4 pixel geometry, comparing enhancement modes) reports `SKIP: installed build is
not debuggable` rather than pretending. Install a debug build to light those up:

```
flutter build apk --debug && node android_test/setup.cjs debuggable
```

Cases also SKIP when the picker could not be driven, because an import that was
never proven cannot support a claim about what happened after it.

## The picker on this device

`pickMultiImage` is served by `com.android.documentsui` and is **not**
multi-select: one tap commits one image and closes the picker. Grid thumbnails
carry no labels, so `picker.cjs` switches to list view and selects by filename —
that is what lets a test deliberately feed the tilted photo or the edgeless one.
So "import N pages" is N trips, and the app navigates to the result page after
each one; `flows.importPages` walks back to the session view in between.

Three things about that list are measurable and each one broke an import:

- A row that has fallen off either edge reports `center.y = 0`. Tapping 0 hits
  the status bar, the ROM swallows it, and the picker just stays in focus. Rows
  are therefore only accepted inside a tappable band (below the toolbar, above
  the gesture bar).
- A full-screen fling moves about four rows, so a target can jump from just
  below the fold to above the header without ever being in the band. Locating a
  row nudges two rows at a time.
- The direction to nudge is not knowable from the clipped row — `y = 0` does not
  say which edge it fell off, and the recent group cannot scroll the other way
  at all. So the direction comes from the list itself and flips whenever a nudge
  moves nothing.

`uiautomator dump` also refuses for a second while the picker animates. Reading
the tree during *navigation* tolerates that and retries; assertions still use
`driver.dump()`, which throws rather than letting an empty tree read as "that
label is absent".

With all three handled, three consecutive trips verify at the first tap each:
`已拍 1 页` → `已拍 2 页` → `已拍 3 页`, ~10.8s for the first (cold picker) and
~2.5s for the rest.

A picker left open from an earlier run stays stacked inside the app's own task, so
`am start` re-raises the picker and the app looks dead. Every `Suite` starts with
`driver.resetToApp()` to clear that.

## The library list on this device

The Docs tab tells the harness where its rows are but not what they contain. The
whole screen dumps 9 nodes: two tabs, the app bar, 多选, the filter `EditText`,
日期, `N 个文档`, and one 分享/删除 pair per card. Nothing from the card body —
not the title, not the `10月25日 10:47 · 2 页` subtitle — reaches the tree, even
though the same widgets elsewhere on the same page (`N 个文档`, the empty-state
text) do. The Flutter side is not at fault: a widget test with an active
`SemanticsHandle` finds the row's label and its tap/long-press actions, so the
node exists and the Android embedder or this ROM's dump drops it.

So a row is never addressed by its text. `flows.cjs` identifies one through two
oracles that *are* readable:

- `setFilter(query)` types into the name field — the app's own search is what
  narrows the library to the document under test — and returns the `N 个文档`
  count it produced.
- `rowTitle(index)` long-presses the row and reads the rename sheet's prefilled
  `EditText`, then taps 取消. Dialog text reaches the dump, so this is the only
  way to ask "which document is this row?" It costs ~3s per row.
- `locateDoc(title)` requires both to agree: the filter leaves the row standing
  alone and the sheet reads back exactly that title. It returns null rather than
  a guess, because the caller is usually about to delete it.
- `deleteRowAt(row, title)` then taps *that* row's 删除 and refuses to confirm
  unless the dialog repeats the title — `删除「qa-export-01」？` — and the count
  afterwards drops by exactly one.

The per-row buttons are the geometry: `rowAnchors()` pairs each 删除 with the
分享 at the same y, and the row body is tapped at 28% of the screen width.
