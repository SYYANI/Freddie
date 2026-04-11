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

## Requirements

- macOS 14.0+
- Xcode with Swift 6 support
- `xcodegen`
- `swift-readability` checked out at `./swift-readability`

`create-dmg` is only needed if you want to build a distributable DMG locally.

## Getting Started

Clone the repository:

```sh
git clone <your-repo-url>
cd read-paper
```

If `swift-readability` is missing, clone it into the expected local path:

```sh
git clone https://github.com/SYYANI/swift-readability.git swift-readability
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
xcodebuild -project ReadPaper.xcodeproj -scheme ReadPaper -destination 'platform=macOS' -derivedDataPath .DerivedData build
```

Run tests:

```sh
xcodebuild -project ReadPaper.xcodeproj -scheme ReadPaper -destination 'platform=macOS' -derivedDataPath .DerivedData test
```

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

## Release

The repository includes a GitHub Actions workflow that can generate an unsigned macOS DMG on tag push or manual dispatch.

## License

This project is released under the MIT License. See [LICENSE](LICENSE).

## Acknowledgements

Special thanks to the projects and ideas that helped shape ReadPaper:

- [Mercury](https://github.com/neolee/mercury) 
- [BabelDOC](https://github.com/funstory-ai/BabelDOC)
- [swift-readability](https://github.com/neolee/swift-readability)
