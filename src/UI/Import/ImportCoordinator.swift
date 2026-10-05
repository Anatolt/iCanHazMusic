// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import UniformTypeIdentifiers

/// Entry points for adding files to the active playlist (File menu, drag and drop) and for re-reading the tags of
/// files that are in it. Runs one `ImportSession` at a time behind a modal progress sheet.
@MainActor
@Observable
final class ImportCoordinator {
    static let shared = ImportCoordinator()

    /// The running import, if any. Menu items and drops are ignored while this is set.
    private(set) var session: ImportSession?
    private var isChoosingRescanFolders = false

    /// An import is running, or the active playlist is still loading (adding to it would be unsafe).
    var isBusy: Bool { session != nil || isChoosingRescanFolders || PlaylistStore.shared.isLoading }

    private init() {}

    // MARK: - Entry points

    /// The dialog exposes the exact roots and the additive policy before a potentially long scan.
    /// A legacy/file-only playlist chooses roots explicitly; changing roots never removes existing tracks.
    func rescanFolders() async {
        let store = PlaylistStore.shared
        guard !isBusy, !(store.isQueueShown && PlaybackState.shared.queue.isEnabled),
              let window = await MainWindowOpener.shared.show(), window.attachedSheet == nil,
              !isBusy else { return }
        let name = store.activeName
        var folders = store.activePlaylist.sourceFolders
        isChoosingRescanFolders = true
        defer { isChoosingRescanFolders = false }

        if !folders.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Rescan Folders — \(name)"
            alert.informativeText = "Add new tracks and refresh existing tags from:\n\n"
                + folders.joined(separator: "\n")
                + "\n\nMissing tracks are kept. Tracks removed from this playlist may be added again."
            alert.addButton(withTitle: "Rescan")
            alert.addButton(withTitle: "Choose Folders…")
            alert.addButton(withTitle: "Cancel")
            let response = await alert.beginSheetModal(for: window)
            if response == .alertThirdButtonReturn { return }
            if response != .alertFirstButtonReturn { folders = [] }
        }
        if folders.isEmpty {
            let panel = NSOpenPanel()
            panel.message = "Choose folders for this playlist. Rescans add new tracks and refresh tags; missing tracks are kept."
            panel.prompt = "Rescan"
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = true
            guard await panel.beginSheetModal(for: window) == .OK else { return }
            folders = FolderScanner.normalizedPaths(panel.urls.map(\.path))
        }
        guard !folders.isEmpty, store.activeName == name, !store.isLoading else { return }
        let session = ImportSession(tagParsingConcurrency: store.effectiveTagParsingConcurrency)
        self.session = session
        let sheet = ImportProgressSheet(session: session)
        sheet.present(on: window)
        let outcome = await session.rescan(folders: folders)
        var message: String?
        if !outcome.aborted {
            let old = store.activePlaylist
            let readable = Set(outcome.results.filter { AlbumBuilder.isUsable($0.status) }
                .map { $0.url.standardizedFileURL.path })
            let refreshed = old.entries.filter { readable.contains($0.url.standardizedFileURL.path) }.count
            if await store.applyRescan(outcome.results, folders: folders, to: name) {
                let added = store.activePlaylist.trackCount - old.trackCount
                message = "Added: \(added). Refreshed: \(refreshed). Files found: \(outcome.fileCount)."
                    + "\nMissing tracks were kept."
                if session.failed > 0 {
                    message! += "\n\(session.failed) file(s) were unreadable or had no tags; existing entries were kept."
                }
                if !outcome.issues.isEmpty {
                    message! += "\n\nScan incomplete:\n" + outcome.issues.prefix(8).joined(separator: "\n")
                    if outcome.issues.count > 8 { message! += "\n… and \(outcome.issues.count - 8) more errors." }
                }
            } else {
                message = "The playlist changed during the scan. No scan results were applied; please rescan again."
            }
            for issue in outcome.issues { Log.error("rescan: \(issue)") }
        }
        CoverCache.reset()
        LyricsService.shared.refreshCurrent()
        await sheet.dismiss()
        self.session = nil
        if let message { await Dialogs.showInfo(message, title: "Rescan Folders — \(name)") }
    }

    func addDirectory() async {
        let panel = NSOpenPanel()
        panel.message = "Choose directories to add to the playlist"
        panel.prompt = "Add"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        await runPanel(panel)
    }

    func addFiles() async {
        let panel = NSOpenPanel()
        panel.message = "Choose files to add to the playlist"
        panel.prompt = "Add"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = AudioFileGatherer.supportedExtensions.sorted()
            .compactMap { UTType(filenameExtension: $0) }
        await runPanel(panel)
    }

    func importPlaylists() async {
        let panel = NSOpenPanel()
        panel.message = "Choose playlist files to add to the playlist"
        panel.prompt = "Import"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = PlaylistFormat.allCases.compactMap { UTType(filenameExtension: $0.fileExtension) }
        await runPanel(panel, playlists: true)
    }

    /// Files and/or directories dropped on the window. Returns whether the drop was accepted.
    ///
    /// Playlist files are only imported if nothing but playlist files was dropped. In a mix with audio files or
    /// directories they are ignored, as albums often carry a playlist of their own and importing it as well would
    /// add every track twice.
    @discardableResult
    func handleDrop(_ urls: [URL]) -> Bool {
        let urls = urls.filter(\.isFileURL)
        // Files go into the active playlist, which isn't what the queue view shows.
        let showsQueue = PlaylistStore.shared.isQueueShown && PlaybackState.shared.queue.isEnabled
        guard !isBusy, !showsQueue, !urls.isEmpty else { return false }
        let playlistsOnly = urls.allSatisfy(PlaylistExchange.isPlaylistFile)
        Task { await start(urls, playlists: playlistsOnly) }
        return true
    }

    /// Reads the tags of these files again (and their album art), then takes them over into the active playlist,
    /// which is regrouped, as the new tags can put a track into another album. Files that can't be read keep
    /// their old values.
    func reloadTags(of files: [URL]) async {
        guard !isBusy, !files.isEmpty, let window = Dialogs.hostWindow else { return }

        let store = PlaylistStore.shared
        let name = store.activeName
        let session = ImportSession(tagParsingConcurrency: store.effectiveTagParsingConcurrency)
        self.session = session
        let sheet = ImportProgressSheet(session: session)
        sheet.present(on: window)

        let outcome = await session.reload(files: files)
        CoverCache.reset()
        LyricsService.shared.refreshCurrent()
        if !outcome.aborted {
            await store.applyTags(outcome.results, to: name)
        }

        await sheet.dismiss()
        self.session = nil

        if !outcome.aborted, session.failed > 0 {
            await Dialogs.showError(
                "\(session.failed) of \(files.count) file(s) couldn't be read or have no tags. They keep their previous tags.",
                title: "Reload Incomplete"
            )
        }
    }

    /// Reads exactly these files, in this order, into the active playlist (the playlist of the previous version,
    /// see `MigrationActions`). Returns how many files there were and how many of them couldn't be read, `nil` if the
    /// import didn't happen or was aborted.
    func importList(_ files: [URL]) async -> (total: Int, failed: Int)? {
        guard !isBusy, !files.isEmpty, let window = Dialogs.hostWindow else { return nil }

        let session = ImportSession(tagParsingConcurrency: PlaylistStore.shared.effectiveTagParsingConcurrency)
        self.session = session
        let sheet = ImportProgressSheet(session: session)
        sheet.present(on: window)

        let outcome = await session.run(files: files)
        CoverCache.reset()
        LyricsService.shared.refreshCurrent()
        if !outcome.aborted {
            await PlaylistStore.shared.append(outcome.albums, to: PlaylistStore.shared.activeName)
        }

        await sheet.dismiss()
        self.session = nil
        return outcome.aborted ? nil : (outcome.fileCount, session.failed)
    }

    // MARK: - Internals

    private func runPanel(_ panel: NSOpenPanel, playlists: Bool = false) async {
        guard !isBusy, let window = await MainWindowOpener.shared.show() else { return }
        guard !isBusy else { return }
        guard await panel.beginSheetModal(for: window) == .OK else { return }
        await start(panel.urls, playlists: playlists)
    }

    /// `playlists`: `urls` are playlist files whose entries are imported; otherwise they are audio files and
    /// directories (playlist files among them are ignored by the gatherer).
    private func start(_ urls: [URL], playlists: Bool = false) async {
        guard !isBusy, !urls.isEmpty, let window = Dialogs.hostWindow else { return }

        let session = ImportSession(tagParsingConcurrency: PlaylistStore.shared.effectiveTagParsingConcurrency)
        self.session = session
        let sheet = ImportProgressSheet(session: session)
        sheet.present(on: window)

        let name = PlaylistStore.shared.activeName
        let roots = playlists ? [] : await Task.detached(priority: .userInitiated) {
            urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }.map(\.path)
        }.value
        let outcome = playlists ? await session.run(playlists: urls) : await session.run(inputs: urls)
        CoverCache.reset()   // the import may have found art for albums that currently show a placeholder
        LyricsService.shared.refreshCurrent()
        if !outcome.aborted {
            await PlaylistStore.shared.append(outcome.albums, to: name, sourceFolders: roots)
        }

        await sheet.dismiss()
        self.session = nil

        if outcome.fileCount == 0, !outcome.aborted {
            await Dialogs.showError(
                playlists ? "The playlist(s) don't list any supported audio files." : "No supported audio files were found.",
                title: "Nothing to Add"
            )
        }
    }
}
