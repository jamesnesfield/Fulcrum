# Library: per-shot sidecars and migration

Status: sidecars, migration, index and library sidebar implemented (19 Nov 2026).

## Why

Edits, variations, tags and upload state live in four JSON files in Application Support (`edits.json`,
`snapshots.json`, `tags.json`, `edit-log.jsonl`), each keyed by the photo's absolute path. Moving or renaming a
photo, or mounting its drive under another name, silently detaches all of it. A RAW+JPEG pair is one shot on the
card but two unrelated files after import. And nothing remembers which photos you have, so every session starts
with Open.

## Goals

- A photo's data travels with the photo: moves, renames of the folder, other drives, backups.
- The unit is the **shot** (RAW+JPEG pair, or a single file), as it already is on the card.
- One source of truth per shot, readable without Fulcrum.
- A fast library view built from an index that can always be thrown away and rebuilt.
- Migration loses nothing and can run twice safely.

## Non-goals

- Copying photos into a managed package. Originals stay ordinary files where you put them.
- Writing anything into the photo files themselves. Originals are never touched.
- A lifetime archive. Apple Photos remains that; Fulcrum is the working library.

## Concepts

| Term | Meaning |
| --- | --- |
| Library root | The import destination (`importRoot`, default `~/Pictures`). Shoots inside it appear in the library view. |
| Shot | Supported files in one folder sharing a basename, compared case-insensitively. `DSC_0412.ARW` + `DSC_0412.JPG` is one shot. |
| Source file | The file a shot's edit renders from: the RAW if there is one, otherwise HEIC/HEIF, JPEG, TIFF, PNG in that order. |
| Sidecar | `<basename>.fulcrum` next to the shot's files. The source of truth for that shot. |
| Index | `library.sqlite` in Application Support. A cache of sidecars for browsing and filtering. |

Photos opened from outside the library root (Finder's Open With, Desktop, Downloads) are still shots and still get
a sidecar. They just don't appear in the library view unless they're moved into the root.

## Sidecar format

UTF-8 JSON, keys sorted, pretty-printed, so it diffs cleanly and is readable by hand.

```json
{
  "format": "fulcrum.shot",
  "version": 1,
  "id": "8F0C2E5A-3B7D-4A61-9C1E-2D4B6F8A0E13",
  "created": "2026-11-14T09:12:44Z",
  "modified": "2026-11-19T16:03:10Z",
  "files": [
    { "name": "DSC_0412.ARW", "role": "source", "bytes": 25165824 },
    { "name": "DSC_0412.JPG", "role": "companion", "bytes": 6291456 }
  ],
  "edit": { "exposure": 0.3, "contrast": 18 },
  "variations": [
    { "id": "…", "number": 1, "date": "2026-11-15T10:00:00Z", "settings": { "contrast": 30 } }
  ],
  "tags": { "favourite": true, "labels": ["coast", "portfolio"] },
  "uploads": {
    "apple":  { "date": "2026-11-16T12:00:00Z", "version": "…" },
    "google": null
  }
}
```

Notes on the fields:

- `id` is generated once and never changes. The index, the edit log and anything else that refers to a shot uses
  it, never a path.
- `files` records names only, relative to the sidecar's folder, so the whole folder can move.
- `edit` and `variations[].settings` are `EditSettings` as encoded today. Its decoder already falls back to
  defaults for missing keys, so a sidecar written before a new setting existed still loads.
- `edit` is absent when the shot has never been edited. The default Look is applied at load time, as now, and
  isn't written until you change something.
- `uploads.*.version` is the existing `Uploader.version(settings, format)` string, so "edited since upload"
  keeps working.
- `edit` holds every setting, defaults included, so sidecars are long. Readable, but not compact.
- Not stored: thumbnails, measured medians, anything Fulcrum can recompute.

### Writing rules

- Write atomically (temp file + rename), debounced 0.5 s, as `EditStore` does today.
- Only write a sidecar once a shot has something to save. Opening a photo in Downloads to look at it must not
  leave a file behind. If a shot's sidecar becomes empty again (edit reset, no tags, no variations, no uploads),
  delete it.
- Before writing, compare the sidecar's modification date with the one read at load. If it changed on disk
  (another Mac via a synced drive, a restore), reload and reapply the pending change rather than overwrite.
- `version` higher than Fulcrum understands: open the shot read-only and say so plainly.

### When the folder can't be written

Read-only volumes, locked folders, or files opened from inside another app's package. The sidecar goes to
`Application Support/Fulcrum/Sidecars/<id>.fulcrum` instead, found through `Sidecars/index.json` (source path →
id). Fulcrum isn't sandboxed, so a path is enough; no bookmark is needed. The shot works normally. The UI doesn't
yet say that its edits are stored with Fulcrum rather than beside the photo.

### Visible or hidden

Draft decision: visible (`DSC_0412.fulcrum`), like Lightroom's `.xmp`. It's honest about where data lives and
backs up with any tool. The alternative, `.DSC_0412.fulcrum`, keeps Finder tidy but is easy to lose when copying
with tools that skip dotfiles.

## Index

`Application Support/Fulcrum/library.sqlite` (`LibraryIndex` in FulcrumCore, `Library` in the app).

```
folders(path PRIMARY KEY, mtime)
shots(folder, basename, source, kinds, id, capture, edited, favourite, labels,
      uploaded_apple, uploaded_google, sidecar_mtime, PRIMARY KEY(folder, basename))
```

- The library root is the import folder (`importRoot`, default `~/Pictures/Fulcrum`). Every non-hidden folder
  under it is indexed; packages such as `.photoslibrary` are skipped. A different root starts the index again.
- Only folders whose modification date changed are re-read. Adding, removing or saving a sidecar (an atomic
  rename) all change it. Within a changed folder, shots whose source and sidecar date are unchanged reuse their
  row, so EXIF and JSON are only read for what's new.
- Refreshes run on a background queue: at launch, when Fulcrum becomes active, after an import, and for one
  folder right after Fulcrum saves or removes a sidecar there. There's no FSEvents watcher; becoming active
  catches changes made in Finder.
- `capture` is EXIF `DateTimeOriginal`, else the file's modification date.
- No thumbnail cache: rows use QuickLook, which keeps its own.
- Deleting the database is always safe: the next refresh rebuilds it from the folders and sidecars.
- `FULCRUM_LIBRARY_DIR` overrides the root for testing without changing the import setting.

### In the sidebar

A collapsible **Library** section above the photo list:

- **Favourites**: every favourite in the library.
- **To Upload**: edited shots never uploaded to either service. It doesn't catch shots edited again after
  uploading; the upload sheet's "skip already uploaded" still handles those.
- One row per shoot (folder with photos), newest first, with its shot count.

Clicking a row replaces the photo list with those shots in capture order. Opening photos by hand switches
back to an "Opened" list. Both smart rows hide when empty.

## Apple Photos "Edit With"

Photos copies the photo to `<library>.photoslibrary/private/com.apple.Photos/ExternalEditSessions/<uuid>/` and
opens that copy in Fulcrum. It takes whatever is saved over the copy as the photo's edit, and Revert to
Original in Photos still works afterwards.

- **File → Save to Photos (⌘S)**, enabled only for these copies. It renders the edit at full size in the copy's
  own format (JPEG, HEIC, PNG, TIFF) and quality 0.95. It uses Display P3 if the original's profile is P3, else
  sRGB, and writes into the same file under file coordination. RAW copies are refused, with a pointer to Export.
- The first save keeps a pristine copy in `Application Support/Fulcrum/PhotosSessions/<uuid>/`. From then on,
  rendering, exporting, uploading and saving all decode that copy, so saving again doesn't stack the edit on
  an already-edited file. Copies older than three days are removed at launch.
- Sidecars for anything inside a `.photoslibrary` package go to `Application Support/Fulcrum/Sidecars/`, never
  into the library.
- The window subtitle says "From Photos · not saved (⌘S)" or "From Photos · saved". Quitting with unsaved
  Photos edits asks: Save to Photos, Cancel, or Don't Save.
- Limits: "saved" state is kept in memory only, so after relaunching Fulcrum a photo shows as not saved. A new
  Edit With session is a new copy at a new path, so it starts without the previous session's Fulcrum edit; a
  Look carries it across. Photos hands over its current, already-edited version, so re-editing in a later
  session starts from the saved result. Avoiding that needs a Photos editing extension.

## Edit log

Stays app-wide in `edit-log.jsonl`; it describes how you edit, not one photo. New entries gain a `shot` field
with the shot `id`. Existing entries keep their `file` path and are not rewritten.

## Migration from the current stores

Runs once at launch, before any store is read. Idempotent: safe to run again if interrupted.

1. Read `edits.json`, `snapshots.json` and `tags.json`. Missing files count as empty.
2. Take every path that appears in any of them. Split into paths that exist and paths that don't.
3. Group existing paths into shots (folder + case-insensitive basename), also pulling in any companion files in
   that folder that weren't in the stores.
4. For each shot:
   - If a sidecar already exists, skip it. That's what makes a re-run safe.
   - `edit`: the source file's edit if it has one, otherwise any other file's edit.
   - If the RAW and the JPEG were edited **differently**, the source's edit wins and each other edit becomes a
     variation, so nothing is lost.
   - `variations`: all snapshots from all of the shot's files, oldest first, renumbered from 1 (as `saveSnapshot` numbers them), followed by any differing edits from
     the step above.
   - `tags.favourite`: true if any file was a favourite. `labels`: union.
   - `uploads`: per service, the most recent date with its version.
   - Write the sidecar (or the fallback location if the folder isn't writable).
5. Entries for paths that no longer exist go into `Migration/unmatched.json`, untouched, so they can be re-attached
   by hand or by a later "find missing" pass.
6. Move the three old files into `Migration/v0/`. Don't delete them.
7. Write `Migration/v1.done`. If it's present, skip the migration.

Current data on this Mac (19 Nov 2026): 5 edited files, 3 tagged, no snapshots, every path still exists. They're in
`~/Desktop` and `~/Downloads`, so their sidecars will appear there, and those shots won't show in the library view
until moved into the library root.

## Code changes

As built:

- `FulcrumCore/Shot.swift`: `ShotSidecar`, `ShotGrouping`, `ShotMigration` (pure, tested by `fulcrum-check`).
- `Fulcrum/ShotStore.swift`: `ShotStore` (load, debounced write, reload-if-changed, delete-when-empty, fallback),
  `LegacyMigration`, `RecentLabels`. `AppModel.init` touches `ShotStore.shared` so migration runs at launch.
- `EditStore`, `SnapshotStore` and `TagStore` stay as thin wrappers over `ShotStore`, so call sites are unchanged.
  `Snapshot` is now `ShotSidecar.Variation`.
- Label suggestions are "recently used" (`RecentLabels`, in user defaults) rather than counted across every photo,
  since there's no longer one file holding every photo's labels. Migration seeds them most-used first.
- `AppModel.open` maps every file to its shot's source, so a pair is one sidebar row, labelled e.g. "ARW+JPG".
- Edit log entries carry `shot` once the shot has a saved sidecar.

Changed from the draft:

- Import doesn't write sidecars. Pairing comes from folder + basename, so an ID-only sidecar for every imported
  shot would only add files. A shot gets its sidecar when it first has something to save.
- No `capture` field yet; it's for the index, which isn't built.

Originally planned:

- `FulcrumCore`: `ShotSidecar: Codable` and a pure `ShotGrouping` (URLs → shots, source-file choice), so
  `fulcrum-check` can test them without the app.
- `Fulcrum`: `ShotStore` replaces `EditStore`, `SnapshotStore` and `TagStore`, keeping method shapes close
  (`settings(for: URL)`, `snapshots(for:)`, `tags(_:)`, `update(_:_:)`) so call sites mostly stay as they are. A URL
  resolves to its shot first.
- `AppModel.files` becomes a list of shots: one sidebar row per pair, rendering from the source file.

### Tests for `fulcrum-check`

- Sidecar round-trip, including an `EditSettings` with missing keys.
- Grouping: ARW+JPG, `.JPG` vs `.jpg`, lone HEIC, two different basenames in one folder.
- Migration: differing RAW/JPEG edits produce a variation; re-running changes nothing; missing paths land in
  `unmatched.json`.
- A sidecar with `version: 2` loads read-only.

## Open questions

1. Visible or hidden sidecars (draft: visible).
2. Should a file opened from outside the root get a sidecar beside it, or always use the Application Support
   fallback until it's moved into the library?
3. Re-attaching a shot whose photos moved without the sidecar: match on file size plus EXIF capture time and
   sub-seconds? Worth doing only if it happens in practice.
