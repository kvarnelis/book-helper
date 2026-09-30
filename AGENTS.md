# Book Helper

Book Helper is a macOS app that renames book PDF files using ISBN metadata lookups. It is a standalone application with no dependency on ReadCube Papers or other external services beyond metadata APIs.

## Build Instructions for Agents

Before any structural change: read CLAUDE.md.

**Build the app:**

```bash
cd /Users/kazys/Developer/book-helper
xcodebuild -project BookHelper.xcodeproj \
  -scheme BookHelper \
  -configuration Release \
  -derivedDataPath build/DerivedData \
  build
```

**Canonical build location:** `build/DerivedData` — this is the only build directory.

**Regenerate the Xcode project from XcodeGen:**

```bash
/opt/homebrew/bin/xcodegen generate
```

Always `xcodegen generate` after editing `project.yml`, then commit both `project.yml` and the regenerated `.xcodeproj`.

## Architecture

**Metadata lookup chain (priority order):**
1. Open Library API (preferred, no auth required)
2. Google Books API (fallback, may need API key)
3. Library of Congress (authoritative, slower)
4. Filename-guess search

**Services:**
- **BookISBNExtractor** — extracts ISBN from filename patterns
- **BookMetadataLookupService** — queries metadata APIs in priority order
- **BookRenamer** — renames files based on fetched metadata
- **ZoteroClient** — integration point with Zotero library (optional)

**UI:**
- **BookHelperContentView** — main drag-drop interface
- **BookHelperViewModel** — UI state and business logic
- **BookDropZone** — drag-drop target for PDFs

**Data:**
- **BookMetadata** — book information (title, author, ISBN, etc.)

## Signing and Deployment

- **Developer ID:** PHCL25Z99X (Kazys Varnelis)
- **Certificates:** ~/Developer/certificates-keys/
- **Notarization:** machine-wide `notary` keychain profile (xcrun notarytool)
- **Deployment target:** macOS 13.0 minimum
- **Hardened runtime:** YES

## Provenance

Split from papers-helper at commit 38f6ad0 on 2026-09-30. The app is now independent with its own repository, build system, and release track.
