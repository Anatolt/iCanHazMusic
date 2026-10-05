# FSEvents backend design (not implemented)

### Product contract and identity

Keep ordinary playlists manual. Automatic updating should be a per-playlist explicit
opt-in over selected source roots, with visible last successful scan and root status.
Do not silently convert all historical imports to watched folders. A future strict
folder-mirror mode would be a separate mode with explicit removal semantics, not a
consequence of pressing Rescan. The initial automatic mode should also be additive.
For automatic mode remember manual removals as exclusions, scoped to source/file
identity. A manual rescan must offer whether to include excluded tracks again.

Promote roots to records with stable source UUID, user-visible path, resolved bookmark,
volume UUID, filesystem identity of root, display name, monitoring policy and generation.
Use stable playlist UUIDs before background work can outlive playlist rename/delete;
the current name is not a sufficient job identifier. On upgrade, create source records
only from explicit `source_folders` (introduced by the separate manual-rescan change). Share a scan for identical roots subscribed by
multiple playlists, but keep each playlist's membership/order/exclusions independent.
Do not infer roots by longest common prefix of tracks.

### Components and ownership

- `Core/Library/FolderMonitor`: thin CoreServices FSEvents adapter, dedicated serial
  dispatch queue, callbacks copied into immutable event batches. No tag parsing, I/O
  scans, or playlist mutations inside callbacks. Stop/invalidate/release streams in
  order; callback context lives until invalidation drains the queue.
- `ScanCoordinator` actor: source state machine, generations, cancellation and bounded
  dirty-path set; merges manual and automatic jobs. One reconciliation per source,
  global I/O limits, separate metadata-parser limits (reuse existing setting).
- `DirectoryInventory`: worker-side inventory with per-subtree completeness and errors,
  volume/file resource IDs, relative paths, size, mtime and optional content fingerprint.
  Never reuse AudioFileGatherer for destructive reconciliation: it hides enumeration
  errors. The companion manual-rescan change introduces FolderScanner as an additive starting point, not a complete snapshot engine.
- `LibraryIndex`: SQLite transactional inventories, source state, exclusions and cursors.
  UI gets immutable status/progress snapshots on MainActor. PlaylistStore remains the
  only writer of playlist content; monitor does not directly edit playlist JSON.

State machine: idle -> debouncing -> scanning -> committing -> idle. Independent
unavailable / permissionRequired / retryWaiting states retain the previous good
inventory. Events during scanning go into a subsequent dirty generation. Cancelling
or deleting a source bumps its generation; stale worker completions cannot commit.

### Event treatment

FSEvents notifications are hints to reconcile filesystem state, not a reliable sequence
of file mutations. Apple documents coalescing, dropped-event recovery, root changes,
and the need to start monitoring before the initial scan. It recommends per-device
streams for persistent history and periodic full scans. See the [Apple programming
guide](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html).

Proposed stream policy: per local volume, use FileEvents + WatchRoot + UseCFTypes,
with an FSEventStreamSetDispatchQueue adapter. Verify API flag support for the
per-device form against the SDK and in integration tests; maintain a root descriptor
and mount notifications independently of event delivery. Never reuse a device number
as persistent identity. Network/unreliable volumes use the degraded policy below.

| Signal | Scheduled reconciliation |
| --- | --- |
| Ordinary file event | Dirty containing directory; compare inventory before parsing |
| Directory create/remove/rename | Dirty relevant parent and subtree; reconcile both known and discovered paths |
| MustScanSubDirs | Recursive inventory of affected source intersection, including ancestor events |
| UserDropped / KernelDropped | Full inventory of every source attached to that stream |
| EventIdsWrapped / invalid journal identity | Discard cursor; rebuild baseline |
| RootChanged (event ID can be zero) | Re-resolve root identity/bookmark; do not treat old path as empty or zero as a checkpoint |
| Mount/unmount or wake | Revalidate volume/root and force reconciliation as needed |
| Duplicate/spurious event | No inventory diff => no playlist write or parser work |

Debounce proposal: 750 ms quiet interval, capped at 5 seconds so continuous writes do
not starve reconciliation. Collapse child dirty paths into dirty ancestors. Bound the
set (e.g. 4096 paths), promoting overflow to full source rescan. Do not ignore all
own-process events: future app operations might affect music. Explicitly exclude app
cache/work directories if a user selects an overly broad root.

Start stream before initial inventory. Record the starting high-water mark, buffer
new events, inventory, then drain dirty generations until covered. HistoryDone ends
replay, not a guarantee that an inventory was fully committed. A manual scan joins the
same scheduler as a forced full inventory, bypassing debounce/backoff but never
bypassing permission or consistency checks. Give the user a progress summary.

### Rename, writes, removal and failure

Match same-volume moves by volume + file resource identity and update paths while
preserving TrackID, order, queued references and selection. A rename event is not
necessarily a paired old/new notification. Reconcile from actual inventories. Account
for inode reuse with fingerprints/generation evidence; ambiguous matches are new
files plus missing old entries. Cross-volume moves are not stable-ID renames.
Hardlinks require a declared policy: keep paths as separate playlist entries unless
user explicitly chooses otherwise. Symlink directories are not followed by default;
explicit alias roots need identity-based deduplication and cycle/escape protection.

Before parsing a file, sample size/mtime; after parsing sample again. If changed, defer
with bounded retry instead of persisting half-written metadata. For new large copies,
require two stable observations (e.g. 1 second apart), still treating decode errors as
retryable. Fingerprints are an optimization; manual full rescan bypasses them. Watch
folder cover files too, invalidating relevant album artwork without requiring an audio
file's timestamp to change.

No deletion follows permission failure, timeout, root loss, dropped history, cancellation,
or a partial subtree scan. Classify missing, permission and transient I/O separately.
Even for future mirror mode, mark a track missing first, verify complete successful
coverage and stable volume identity before offering removal. Never unlink user files.
An already open playing file may continue; inability to open the next track uses the
existing playback failure policy, independently of inventory status.

Retry transient faults with jittered exponential backoff: 1, 2, 4, 8... seconds, capped
at 5 minutes, reset after a successful scan. Permission denial enters a user-action
state rather than repeatedly popping dialogs. Reauthorize a root with NSOpenPanel;
security-scoped bookmark/access lifetime if sandboxing is added. Unmount pauses work;
remount only resumes after volume identity is verified (same mount path is insufficient).

SMB/NFS: do not promise complete remote-writer notifications from FSEvents. Treat any
received events as acceleration, plus configurable low-frequency inventory polling
(e.g. 60 seconds while online, backoff while unavailable) and scan on reconnect/wake.
Expose “Periodic checks” versus “Live monitoring” accurately. Run network scans in a
helper process if a hard cancellation/timeout guarantee is required: a Swift timeout
cannot kill a blocked Foundation/POSIX syscall. Late helper replies carry generations.

### Persistence and crash recovery

Persist per-volume journal UUID/cursor, per-source root identity, latest fully committed
scan generation/time, inventory, incomplete scopes and exclusions. SQLite commits
inventory + cursor together only after reconciliation work is durable. Never checkpoint
an event merely because its callback ran. Invalid/missing database, expired/purged
journal, volume replacement, or unexplained gaps trigger full inventory.

Playlist JSON and SQLite are not one transaction. Use a durable outbox: atomically
record intended playlist edits plus inventory, apply idempotent edits through
PlaylistStore, atomically write each playlist, acknowledge the outbox, then advance the
covered cursor. Retain unacknowledged jobs across crash/restart and replay them by
source/playlist UUID + generation. A crash at any boundary repeats work safely rather
than skipping events or allocating duplicate tracks. Make write failures observable:
current PlaylistStore.save only logs errors and must gain an acknowledged result API.

Keep a periodic full reconciliation (proposal: daily while available) even with healthy
local streams, and always on user Rescan. Store migration version and invalidation
reasons, but never credentials in monitoring logs. Large inventories should be streamed
in bounded batches; final membership changes become visible together.

### Validation before enabling automatic monitoring

Inject event source, filesystem/inventory provider, clock and persistence to test:
coalescing; repeated events; overflow promotion; lost history; rename with stable and
reused IDs; file changes during parse; edits/deletion/rename of a playlist mid-scan;
crash between outbox/JSON/ack/cursor; full scan plus concurrent events; unmount/remount
at same path with different volume; denial in one subtree; symlink loops; cancellation;
queue/playing ID preservation; millions of files and constrained memory.

Run real integration tests on APFS case-sensitive and case-insensitive volumes,
removable disks, SMB with changes from a second client, sleep/wake and permission
revocation. CI synthetic event tests alone cannot establish network-volume correctness.
