// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import iCanHazMusic

extension AllTests {
    @MainActor @Suite("Folder rescan")
    struct FolderRescanTests {
        @Test("overlapping roots deduplicate; hidden files, packages and symlinks stay outside the scan")
        func inventory() throws {
            let dir = try TempDir()
            try dir.write("music/10.MP3")
            try dir.write("music/2.mp3")
            try dir.write("music/.hidden.mp3")
            try dir.write("music/skip.app/inside.mp3")
            try dir.write("outside/extra.mp3")
            try FileManager.default.createSymbolicLink(at: dir.path("music/link"), withDestinationURL: dir.path("outside"))
            let result = FolderScanner.scan([dir.path("music").path, dir.path("music").path])
            #expect(dir.relative(result.files) == ["music/2.mp3", "music/10.MP3"])
            #expect(result.issues.isEmpty)
        }

        @Test("missing roots are errors, empty folders are successful inventories")
        func missingAndEmpty() throws {
            let dir = try TempDir()
            let empty = try dir.mkdir("empty")
            let result = FolderScanner.scan([empty.path, dir.path("disconnected").path])
            #expect(result.files.isEmpty)
            #expect(result.issues.count == 1)
            #expect(result.issues[0].contains("disconnected"))
        }

        @Test("rescan preserves duplicates, IDs, missing files and flat order; new files appear only once")
        func reconciliation() throws {
            let old = Playlist(albums: AlbumBuilder.build(from: [Make.entry("/Music/a.mp3"),
                Make.entry("/Music/a.mp3"), Make.entry("/Music/missing.mp3")], flat: true), isFlat: true)
            let results = [Make.result("/Music/a.mp3", title: "New title"), Make.result("/Music/b.mp3"),
                           Make.result("/Music/b.mp3"), Make.result("/Music/bad.mp3", status: .failed("offline"))]
            let updated = old.rescanning(results, folders: ["/Music"])
            #expect(updated.entries.map(\.path) == ["/Music/a.mp3", "/Music/a.mp3", "/Music/missing.mp3", "/Music/b.mp3"])
            #expect(Array(updated.entries.prefix(3).map(\.id)) == old.entries.map(\.id))
            #expect(updated.entries[0].title == "New title")
            #expect(updated.entries[1].title == "New title")
            #expect(updated.entries[3].id >= old.nextID)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            #expect(try encoder.encode(updated.rescanning(results, folders: ["/Music"]).entries) == encoder.encode(updated.entries))
            #expect(try encoder.encode(old.rescanning([], folders: ["/Music"]).entries) == encoder.encode(old.entries))
        }

        @Test("roots survive every playlist transformation and JSON reload, old files default to no roots")
        func persistence() throws {
            let old = Make.playlist([Make.entry("/Music/a.mp3"), Make.entry("/Music/b.mp3")])
                .settingSourceFolders(["/Music", "/Music/../Music", "relative"])
            let first = old.entries[0].id
            let variants = [old, old.settingFlat(true), old.removing(ids: [first]),
                            old.appending(Make.albums([Make.entry("/Music/c.mp3")])),
                            old.updatingTags(from: [Make.result("/Music/a.mp3")]),
                            try #require(old.movingTrack(id: first, toIndexInAlbum: 1)),
                            try #require(old.settingFlat(true).movingAlbum(0, to: 1)),
                            try #require(old.replacingTrack(id: first, duration: 42, codec: "MP3"))]
            let dir = try TempDir()
            for (i, playlist) in variants.enumerated() {
                #expect(playlist.sourceFolders == ["/Music"])
                let url = dir.path("\(i).json")
                try PlaylistFile.write(playlist, to: url)
                guard case .loaded(let loaded, _) = PlaylistFile.load(from: url) else {
                    Issue.record("playlist failed to load"); continue
                }
                #expect(loaded.sourceFolders == ["/Music"])
            }
            let legacy = try JSONDecoder().decode(PlaylistFile.self, from: Data(#"{"version":1,"tracks":[]}"#.utf8))
            #expect(legacy.sourceFolders.isEmpty)
        }

        @Test("store persists roots of empty imports; rescan preserves IDs and last played")
        func storeCommit() async throws {
            let dir = try TempDir()
            let paths = AppPaths(workDir: dir.url)
            let config = ConfigStore(paths: paths)
            let store = PlaylistStore(paths: paths, configStore: config)
            #expect(await waitUntil { !store.isLoading })
            await store.append([], to: store.activeName, sourceFolders: ["/Music"])
            #expect(store.activePlaylist.sourceFolders == ["/Music"])
            await store.append(Make.albums([Make.entry("/Music/a.mp3")]), to: store.activeName)
            #expect(store.activePlaylist.appendedFromRow == 0)
            let id = store.activePlaylist.entries[0].id
            store.playbackStarted(in: store.activeName)
            store.setLastPlayed(id)
            #expect(await store.applyRescan([Make.result("/Music/a.mp3"), Make.result("/Music/new.mp3")],
                                            folders: ["/Music"], to: store.activeName))
            #expect(store.activePlaylist.track(id: id) != nil)
            await store.flushWrites()
            let file = paths.playlistsDir.appendingPathComponent(store.activeName + ".json")
            guard case .loaded(let loaded, let last) = PlaylistFile.load(from: file) else {
                Issue.record("playlist failed to load"); return
            }
            #expect(last == id)
            #expect(loaded.sourceFolders == ["/Music"])
            #expect(loaded.trackCount == 2)
            #expect(await !store.applyRescan([], folders: [], to: "no such playlist"))
        }

        @Test("aborted rescan returns no changes")
        func cancellation() async throws {
            let dir = try TempDir()
            let session = ImportSession(coverStore: CoverStore(url: dir.path("covers.sqlite"), thumbnailPixels: 64),
                                        lyricsStore: LyricsStore(url: dir.path("lyrics.sqlite")))
            session.abort()
            let result = await session.rescan(folders: [dir.url.path])
            #expect(result.aborted)
            #expect(result.results.isEmpty)
        }
    }
}
