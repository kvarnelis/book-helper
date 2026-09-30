# Book Helper

Book Helper is a macOS app that renames book PDF files using ISBN metadata. It uses Open Library, Google Books, and Library of Congress APIs with fallback, plus filename-guess search. It does not authenticate with or import into ReadCube Papers.

## Project Structure

- **Sources/BookHelper/** — all app source code and resources
  - **BookHelperApp.swift** — app entry point
  - **Info.plist** — app metadata
  - **Models/** — data models (BookMetadata.swift)
  - **Services/** — business logic (BookISBNExtractor, BookMetadataLookupService, BookRenamer, ZoteroClient)
  - **Views/** — SwiftUI views (BookHelperContentView, BookHelperViewModel, BookDropZone)
  - **Assets.xcassets/** — app icon and image assets
- **project.yml** — XcodeGen specification; source of truth for build configuration
- **BookHelper.xcodeproj/** — generated Xcode project (commit both project.yml and .xcodeproj)

## Build

The canonical build output is `build/DerivedData` under the repo root. This is the only build location.

Build Book Helper from the repo root:

```bash
xcodebuild -project BookHelper.xcodeproj \
  -scheme BookHelper \
  -configuration Release \
  -derivedDataPath build/DerivedData \
  build
```

The repo-root symlink `Book Helper.app` points at the canonical Release product:

```bash
ln -s build/DerivedData/Build/Products/Release/Book\ Helper.app "Book Helper.app"
```

If the build location or product name changes, update the symlink in the same commit.

## XcodeGen

The project is generated from `project.yml` with XcodeGen. To regenerate after editing `project.yml`:

```bash
/opt/homebrew/bin/xcodegen generate
```

Then review and commit both the updated `project.yml` and generated `.xcodeproj`.

## Signing and Notarization

Book Helper uses Developer ID Application signing with the team ID PHCL25Z99X. Signing material (certificates) is located at `~/Developer/certificates-keys/`. Notarization uses the machine-wide `notary` keychain profile.

For development builds, signing may be automatic. For release builds, follow the signing procedure documented in the project's release scripts.

## Provenance

This repository was split from papers-helper at commit 38f6ad0 on 2026-09-30.

Files duplicated from papers-helper code that can now drift independently:
- Sources/BookHelper/Assets.xcassets (also used by papers-helper's PapersImporter target)

## Deployment Target

macOS 13.0 minimum.

## Version

- Product version: 1.0
- Build version: 20260811.1

These are set in `project.yml` and should be updated there before building a new release.
