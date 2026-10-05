// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import iCanHazMusic

extension AllTests {
    @MainActor @Suite("Space key behavior")
    struct SpaceKeyTests {
        @Test("Space keeps the legacy default and persists independently of the queue")
        func spaceSetting() throws {
            for json in ["{}", #"{"general":{"space_plays_pauses":"invalid"}}"#] {
                #expect(try !JSONDecoder().decode(AppConfig.self, from: Data(json.utf8)).general.spacePlaysPauses)
            }
            let dir = try TempDir()
            let config = ConfigStore(paths: AppPaths(workDir: dir.url))
            let settings = WindowSettings(configStore: config)
            settings.spacePlaysPauses = true
            config.update { $0.general.queueEnabled = false }
            config.flush()
            let reloaded = ConfigStore(paths: AppPaths(workDir: dir.url))
            #expect(WindowSettings(configStore: reloaded).spacePlaysPauses)
            #expect(!reloaded.config.general.queueEnabled)
        }

    }
}
