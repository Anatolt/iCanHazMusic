# Manual folder rescans

Rescan Folders is available in the main toolbar and Playlist menu. It is disabled
while the queue is shown or an import is running.

The current product has manually editable playlists and a transient queue of
(playlist name, TrackID). It has no library database or retained directory provenance.
This change adds optional `source_folders` to version-1 playlist JSON. Old files load
with no roots. Old binaries can read the extension but drop it on their next save;
returning to an old binary therefore loses only the rescan configuration.

Explicit Add Directory and dropped directories remember roots, including empty roots.
Loose files and M3U/PLS imports do not imply a subscription to their parent directories.
Rescan displays the roots and offers Choose Folders to replace them. Old playlists
ask for roots first. Roots belong to that playlist, follow rename/copy of its JSON,
and disappear with that playlist. Changing roots does not change existing membership.
No special playlist type is necessary for this additive operation.

A manual scan always recursively enumerates the chosen roots and rereads metadata/art
through ImportSession, regardless of future watcher cursors or metadata fingerprints.
It respects current import format/tag rules (untagged or unreadable files are not new
tracks), skips hidden/package contents and descendant symlinks, and deduplicates
lexically normalized absolute paths, including overlaps between roots. Paths are not
lowercased; different aliases/hardlinks are not automatically merged.

Readable existing paths refresh metadata while preserving every ID and intentional
duplicate. New paths are appended once. Album regrouping follows the existing tag
reload behavior; flat playlists retain their order. Missing/unreadable tracks remain,
including tracks outside the roots. Playing/queued IDs remain valid. A user-removed
file still present on disk is eligible to be added again: the dialog states this.
Rename currently appears as new path plus retained old entry. This is explicitly an
additive rescan, not a folder mirror or missing-file cleanup. No music files are changed.

The sheet is cancellable and commits the playlist only on completion. Existing cache
writes (cover/lyrics) can have happened before cancellation, as with current imports.
Partial enumeration reports errors; a disconnected root never empties a playlist.
The summary gives new/refreshed/file counts and errors, with full errors in the log.
The main-actor store reconciles against its latest immutable playlist; if that object
changes during the detached transformation, it rejects the result and asks to retry.
A roots-only import preserves the existing append/scroll marker semantics.

Current limits: a filesystem syscall blocked by an SMB/NFS server cannot be forcibly
cancelled by Swift Task cancellation; Abort takes effect when it returns. There is no
automatic watcher or background retry in this patch. This manual flow is intentionally
separate from the backend below.
