# Book Helper

Book Helper is a native macOS app for identifying and renaming poorly named PDF and DRM-free EPUB books. PDFs can also be imported into Zotero.

Drop in one or more PDFs or EPUBs and Book Helper will:

- read embedded EPUB title, author, publisher, year and ISBN metadata;
- scan bounded EPUB text, PDF pages and filenames for identifiers when needed;
- look up title, authors, publisher, year, and ISBN;
- fall back to title/author filename matching or Library of Congress metadata;
- let you review and correct the title;
- rename the book while preserving its extension and contents; and
- optionally create a Zotero book item with a selected PDF attached.

EPUBs with an embedded title are ready to rename offline. EPUB import into Zotero is not available yet; EPUBs are excluded from the Zotero action even in mixed batches.

## Download

The current source build is **1.0 (20261005.1)** with EPUB support. This is the first stable release; earlier 1.1 and 1.2 labels were development builds.

Download the signed and notarized app from the [Book Helper 1.0 release](https://github.com/kvarnelis/book-helper/releases/tag/v1.0). Choose the DMG for drag-to-Applications installation or the ZIP for the app bundle.

Book Helper 1.0 requires macOS 13 or later on Apple silicon. Drag the app to Applications and open it normally.

## Use

1. Drop PDF or DRM-free EPUB files into Book Helper, or click **Add Books**.
2. Review the detected metadata. Enter an ISBN manually if none was found.
3. Select the books you want to process.
4. Choose **Rename Books**. For PDFs, you may also choose **Import PDFs to Zotero**.
5. Use **Clear completed** to remove renamed EPUBs or imported PDFs from the list without deleting their files.

Zotero must be open for import. Book Helper creates a book item and attaches the local PDF through Zotero's connector service.

## Metadata and privacy

Book Helper queries Open Library and Google Books for ISBN metadata, with a Library of Congress fallback. Zotero communication stays on the local machine at `127.0.0.1`. The app does not require or store Zotero credentials.

## EPUB limits

Supports EPUB 2/3 ZIP containers with stored or deflated entries. Encrypted/DRM content, ZIP64 and split archives are rejected with an explanation. Standard font obfuscation is accepted; fonts are never decoded or rendered.

The app reads book metadata and selected XHTML, not the whole book. Files above 128 MiB or exceeding the documented safety limits are rejected; oversized chapters are skipped. It does not rewrite embedded metadata, convert formats, render EPUB pages, or infer EPUB page counts. See [implementation limits](docs/ARCHITECTURE.md).

## Tests

Run `Tests/run.sh` with Xcode and Python 3 available. It generates disposable EPUB/PDF fixtures, checks parsing and safe renaming, intercepts all test Zotero requests locally, and renders the app view offscreen. It does not use personal books, online metadata services, or a live Zotero library. Test outputs live under `build/DerivedData/EPUBTests`.

## Build from source

Xcode 15 or later is required.

```bash
xcodebuild -project BookHelper.xcodeproj \
  -scheme BookHelper \
  -configuration Release \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

The canonical app bundle is `build/DerivedData/Build/Products/Release/Book Helper.app`; the repository-root `Book Helper.app` symlink points to it.

## License

MIT
