# Freddie

Freddie is a macOS paper reader built with SwiftUI. The app bundle name is `Freddie`, while the project name remain `ReadPaper`.

It focuses on three practical reading workflows:

- import local PDFs with conservative metadata extraction
- import arXiv papers by ID or URL and prefer HTML reading when available
- translate papers through semantic HTML blocks or full-PDF BabelDOC output

## Features

- Local-first paper library backed by SwiftData
- Local PDF import with lightweight metadata detection from PDF info and early pages
- arXiv import with step-by-step progress feedback
- arXiv HTML fallback chain: `arxiv.org/html/{id}` first, then `ar5iv`
- Readability-based HTML extraction and localization for a cleaner reading view
- Incremental HTML translation with per-block persistence and refresh
- Multi-provider, multi-model OpenAI-compatible routing
- Full PDF translation via BabelDOC with structured progress reporting
- PDF, HTML, and dual-PDF reading modes in one app

## Screenshots

<img width="1624" height="977" alt="Image" src="https://github.com/user-attachments/assets/1f571a5f-c9b7-4b5e-8838-af7b7c1bad71" />
<img width="1624" height="977" alt="Image" src="https://github.com/user-attachments/assets/5786b4ec-febd-4340-b10d-2d0c8e3aca1d" />
<img width="1624" height="977" alt="Image" src="https://github.com/user-attachments/assets/bbd9c9fc-1626-4417-a6ea-da9f8255c5e9" />

## Requirements

- macOS 14.0+
- Xcode with Swift 6 support
- `xcodegen`

Xcode resolves the Swift packages from their GitHub repositories. The selected
branches are declared in `project.yml`; no sibling repository checkouts are
required. The `scripts/build` command also downloads or builds the
manifest-verified BabelDOC native runtime assets in Xcode's package checkout.

`create-dmg` is only needed if you want to build a distributable DMG locally.

## Getting Started

Clone the repository:

```sh
git clone <your-repo-url>
cd read-paper
```

Generate the Xcode project:

```sh
xcodegen generate
```

Open the project:

```sh
open ReadPaper.xcodeproj
```

Or build from the command line:

```sh
./scripts/build
```

The build script performs an unsigned Release build, verifies the embedded
BabelDOC runtime and helper, and writes the app to
`build/Release/Freddie.app`; compilation intermediates remain under
`/tmp/read-paper-derived-data`, so the repository and release directory stay
free of compilation intermediates. Run
`./scripts/build --help` for Debug builds, custom output paths, optional
XcodeGen project regeneration, and Xcode signing options.

Run tests:

```sh
xcodebuild -project ReadPaper.xcodeproj -scheme ReadPaper -destination 'platform=macOS' -derivedDataPath /tmp/read-paper-derived-data test
```

Enable the repository's Git hooks once per clone:

```sh
git config core.hooksPath .githooks
```

The pre-commit hook increments the marketing version and build number together,
then stages only those version fields in `project.yml` and the generated Xcode
project. The patch component runs from `0` through `20`, and the minor component
runs from `0` through `9`: `0.3.19` becomes `0.3.20`, `0.3.20` becomes `0.4.0`,
and `0.9.20` becomes `1.0.0`. To set an explicit version, change
`MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` together in `project.yml`;
the hook preserves and stages that change even if `project.yml` was not staged
yet.

## Project Structure

- `ReadPaper/Models`: SwiftData models and enums
- `ReadPaper/Views`: app UI, library, inspector, settings
- `ReadPaper/Readers`: PDF, HTML, and dual-PDF readers
- `ReadPaper/Services`: import, arXiv, HTML localization, translation, BabelDOC, storage
- `ReadPaperTests`: unit tests for import, storage, translation, routing, and subprocess behavior
- `project.yml`: XcodeGen project definition

## Notes on Scope

ReadPaper does not treat arbitrary PDF text extraction as a reliable full-document structure source.

- Local PDFs are used for reading and lightweight metadata identification
- arXiv papers prefer HTML as the structured reading and translation carrier
- full PDF translation is delegated to BabelDOC

## Data

Primary application data is stored under:

```text
~/Library/Application Support/ReadPaper/
```

Key locations there:

- `ReadPaper.store`: the SwiftData store for papers, attachments, translation cache, provider/model profiles, and app settings
- `Library/{paper UUID}/`: per-paper files such as `paper.pdf`, `paper.html`, `Resources/`, `translations/`, and `notes/`
- `Tools/`: legacy or optional app-managed external tool files

The native BabelDOC helper and its manifest-pinned MuPDF, zstd, layout model,
and font runtime are bundled with the app; no separate runtime install step is required.

Even though the app bundle name is `Freddie`, the on-disk application support directory currently remains `ReadPaper`.

Other system locations affected by the app:

- `~/.cache/babeldoc/`: BabelDOC may create or update its own cache outside the app support directory during PDF translation-related work
- macOS Keychain: provider API keys are stored as generic password items under the Keychain service `com.yiyan.ReadPaper`; SwiftData keeps only references such as `apiKeyRef`, not the raw keys themselves

## Release

The repository includes a GitHub Actions workflow that can generate an unsigned
macOS DMG artifact on tag push or manual dispatch. Xcode resolves the remote
Swift packages, then the workflow downloads/builds and verifies the native
runtime before the app build. Unsigned artifacts are intentionally not
published as GitHub Releases. Each artifact also includes
`build-provenance.txt` with the resolved source commits and runtime manifest hash.
Public distribution remains gated on signing, notarization, Corresponding
Source, and complete third-party notices.

## License

Copyright (c) 2026 SYYANI.

This project is licensed under the GNU Affero General Public License v3.0
(`AGPL-3.0-only`). See [LICENSE](LICENSE) for the full license text.

## Acknowledgements

Special thanks to the projects and ideas that helped shape ReadPaper:

- [Mercury](https://github.com/neolee/mercury) 
- [BabelDOC](https://github.com/funstory-ai/BabelDOC)
- [swift-readability](https://github.com/neolee/swift-readability)
