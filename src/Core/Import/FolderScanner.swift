// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// An explicit, non-destructive inventory for manual rescans. Unlike the import gatherer, errors are visible.
enum FolderScanner {
    struct Snapshot: Sendable {
        var files: [URL] = []
        var issues: [String] = []
        var cancelled = false
    }

    /// Lexical paths: don't lower-case (case-sensitive volumes exist) or infer roots from track parents.
    static func normalizedPaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.path }
            .filter { seen.insert($0).inserted }
    }

    /// Blocking; use a cancellable worker. Hidden files, packages and descendant symlinks are excluded.
    /// No deletions are derived from this snapshot, even when enumeration succeeds (it isn't atomic).
    static func scan(_ paths: [String]) -> Snapshot {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        var snapshot = Snapshot()
        var seen = Set<String>()
        for path in normalizedPaths(paths) {
            if Task.isCancelled { break }
            let root = URL(fileURLWithPath: path, isDirectory: true)
            do {
                let values = try root.resourceValues(forKeys: [.isDirectoryKey])
                guard values.isDirectory == true else {
                    snapshot.issues.append("\(path): not a directory")
                    continue
                }
                // Force an actual directory read: a missing/unreadable root must not look like an empty one.
                _ = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            } catch {
                snapshot.issues.append("\(path): \(error.localizedDescription)")
                continue
            }
            guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: Array(keys),
                                              options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                              errorHandler: { url, error in
                snapshot.issues.append("\(url.path): \(error.localizedDescription)")
                return !Task.isCancelled
            }) else {
                snapshot.issues.append("\(path): could not enumerate directory")
                continue
            }
            for case let url as URL in walker {
                if Task.isCancelled { break }
                do {
                    let values = try url.resourceValues(forKeys: keys)
                    if values.isSymbolicLink == true {
                        walker.skipDescendants()
                        continue
                    }
                    guard values.isRegularFile == true, AudioFileGatherer.isSupported(url) else { continue }
                    let file = url.standardizedFileURL
                    if seen.insert(file.path).inserted { snapshot.files.append(file) }
                } catch {
                    snapshot.issues.append("\(url.path): \(error.localizedDescription)")
                }
            }
        }
        snapshot.cancelled = Task.isCancelled
        snapshot.files.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return snapshot
    }
}
