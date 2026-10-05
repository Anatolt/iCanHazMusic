# Build without installing Xcode

Verified locally on 2026-10-05: Apple Silicon, Swift 6.2.4, selected developer directory
`/Library/Developer/CommandLineTools`. The repository is a SwiftPM executable package,
with no Xcode project, storyboard compiler step or third-party package dependencies.
It targets macOS 15.4. `swift build -c debug --arch arm64` builds the app successfully.
`xcodebuild -version` fails with CLT selected; xcodebuild is not needed by this repo.

The tools-version declaration is 5.10, but a modern macOS SDK is required for the APIs,
and the test suite uses Swift Testing (Swift 6-era tooling). Do not assume an arbitrary
old Swift 5.10 installation will run the tests. Linux runners cannot build this AppKit,
SwiftUI and AVFoundation application. Fastlane does not replace the compiler/SDK; a
macOS job running SwiftPM directly is enough.

Both `build.sh` and `tests/prepare-fixtures.sh` were checked in as mode 100644 despite
the README's `./...` commands. This patch restores executable bits. For a checkout
without that fix, use `bash build.sh` and `sh tests/prepare-fixtures.sh` appropriately;
build.sh internally executes the fixture script directly, so its mode still matters.

## Local tests using this CLT installation

`swift test` alone cannot find `Testing`. Supplying the framework path exposes a second
CLT packaging issue: `_Testing_Foundation.framework/Modules` is a dangling symlink.
The installed Testing cross-import overlay refers to that unavailable module.
This command was validated on the combined feature prototype (782 tests, including
seven feature tests). This independent CI change retains the upstream test suite;
it uses the bundled Testing framework and disables that overlay:

```sh
./tests/prepare-fixtures.sh  # once; needs ffmpeg
SWIFT_BACKTRACE=enable=no swift test --disable-xctest \
  -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
  -Xlinker -rpath \
  -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  --filter AllTests
```

This is an installation-specific workaround, not a new package dependency or a
system-framework modification. Under a complete Xcode toolchain on CI use the normal
`swift test --filter AllTests`. Swift Testing distribution documentation is available
[in the Swift project](https://github.com/swiftlang/swift-testing/blob/main/Documentation/Distributions.md).

## Cloud builds

`.github/workflows/macos.yml` runs tests, compiles arm64 and x86_64 release binaries,
combines them with lipo, copies the same bundle resources as build.sh, ad-hoc signs,
verifies the signature and uploads a ZIP artifact. It uses `macos-15`; GitHub's current
[runner image catalog](https://github.com/actions/runner-images) lists its macOS/Apple
SDK toolchains. Hosted macOS machines already include Xcode; nothing needs installing
on the user's Mac. FFmpeg is installed if missing, for audio fixtures.

The workflow runs on push, pull requests and manual dispatch. Check the Actions run
for the current commit before relying on its uploaded artifact. It does not install
into /Applications, run the author's `share` tool, publish a release, or access signing
secrets. Local universal compilation is separate validation from a real CI run.

The ZIP is a development preview. Distribution needs Developer ID signing and
notarization (an Apple account/certificate and appropriately protected CI secrets).
Ad-hoc signing is sufficient for local development but the README notes system
notifications do not work with it. Last.fm remains unavailable unless the bundle is
built with the user's own API credentials. The CI preview deliberately has none.

`./build.sh dev-release` is unsuitable as a generic CI entry point: it replaces
/Applications/iCanHazMusic.app and uploads through the author's share command.
`release` additionally needs create-dmg; plain build.sh launches a foreground GUI
process, and all modes including test begin by clearing dist. The workflow therefore
calls the underlying tools explicitly and writes to its own ephemeral job directory.
