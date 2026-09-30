# Book Helper

A macOS app that renames book PDF files using ISBN metadata lookups.

Book Helper extracts ISBNs from filenames and looks up book metadata across multiple sources (Open Library, Google Books, Library of Congress). It then renames the file with standardized book information.

## Quick Start

### Build

```bash
xcodebuild -project BookHelper.xcodeproj \
  -scheme BookHelper \
  -configuration Release \
  -derivedDataPath build/DerivedData \
  build
```

### Launch

```bash
open build/DerivedData/Build/Products/Release/Book\ Helper.app
```

## Metadata Sources

1. **Open Library** — primary source, no auth required
2. **Google Books** — fallback, may require API key
3. **Library of Congress** — authoritative but slower
4. **Filename guess** — pattern-based search

## Project Structure

- **Sources/BookHelper/** — all app code and resources
  - **Models/** — BookMetadata data model
  - **Services/** — ISBN extraction, metadata lookup, file renaming
  - **Views/** — SwiftUI UI components
  - **Assets.xcassets/** — app icon and images

## Technology

- **Language:** Swift 5.0+
- **UI Framework:** SwiftUI
- **Minimum macOS:** 13.0
- **Build System:** Xcode, generated from XcodeGen project.yml

## Documentation

- **CLAUDE.md** — build notes, signing, versioning, provenance
- **AGENTS.md** — for agents: architecture, build procedure, signing details
