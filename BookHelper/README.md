# Book Helper

A small macOS app for identifying and renaming PDF and DRM-free EPUB books. PDFs can also be imported into Zotero.

## Workflow

1. Drop PDFs or DRM-free EPUBs into the app, or choose **Add Books**.
2. EPUBs use embedded metadata first, with bounded XHTML text and filename fallbacks. PDFs scan front and back pages for an ISBN.
3. An EPUB with a usable embedded title is ready offline. When a title is missing, the app uses the existing ISBN, Library of Congress and filename metadata lookups.
4. Review or edit the title.
5. Click **Rename Books** to rename the file without changing its contents or extension. **Import PDFs to Zotero** creates a book item and attaches a selected PDF. EPUBs are excluded from that action.
6. **Clear completed** removes renamed EPUBs and imported PDFs from the list, keeping their files.

Zotero must be open during import. Book Helper talks only to Zotero's local connector on this Mac; no Zotero account or API key is required.

Use **Book Helper → Settings** to remove successfully imported books from the list automatically. This never deletes the original PDF. After an import, the status bar can bring Zotero forward with the imported book selected.

If a PDF has no readable ISBN, enter one in the row and run the lookup manually.

EPUBs are not rendered or converted, and no EPUB page count is invented. DRM, malformed and unsupported archives show an error. See the [main README](../README.md) for limits and tests.

## Requirements

- macOS 13 or later
- Apple silicon Mac
- Zotero running locally when using **Import to Zotero**

## Privacy

Metadata lookups are sent directly to Open Library, Google Books, or the Library of Congress. Zotero imports use Zotero's connector service on `127.0.0.1`; Book Helper does not require a Zotero account or transmit Zotero credentials.

## Building

```bash
xcodebuild -project BookHelper.xcodeproj \
  -scheme BookHelper \
  -configuration Release \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```
