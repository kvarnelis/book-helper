# Changelog

## 1.0.1 — 2026-10-05

Build: `20261005.2`.

- Import DRM-free EPUBs into Zotero as book items with the original EPUB attached, including mixed PDF/EPUB batches.
- Preserve format-specific attachment MIME, skip EPUB page counts, and validate EPUBs before creating Zotero items.
- Keep renamed books available until imported; clear only successfully imported books.
- Report a partial import when Zotero does not create the attachment, including HTTP 200 responses from libraries that disallow files.
- Extend offline regression coverage for EPUB attachment contents, parent linkage, mixed batches, completion and error handling.

## 1.0 — 2026-10-05

Build: `20261005.1`. First stable release; supersedes the internal 1.1 and 1.2 development labels.

- Add DRM-free EPUB 2/3 metadata extraction, bounded text/filename fallbacks, title review and extension-preserving rename.
- Keep EPUBs out of Zotero import, with clear UI labels and a service-level guard. PDF import remains available.
- Reject protected, malformed or oversized EPUB archives without extracting files to disk.
- Add synthetic EPUB/PDF regression tests and offscreen UI verification.
- Preserve rename-before-import, Unicode-safe PDF attachment headers, and the optional switch to Zotero after a successful batch from the standalone Book Helper branch.

## 1.1 development build — 2026-08-27

- Add a native Settings window from the app menu.
- Add an option to remove successfully imported books from Book Helper's list without deleting their PDF files.
- Show a persistent import-success bar with a shortcut that activates Zotero on the imported book.
- Process batch imports sequentially so the success shortcut matches the most recently imported book.

## 1.0-beta1 — 2026-08-11

- Replace the original illustrated app icon with a restrained monochromatic geometric mark.
- Remove the icon background so the mark renders cleanly against the system and website surfaces.
- Ship the beta as a Developer ID signed, notarized, and stapled macOS release.

## 0.2.0 — 2026-08-09

- Add direct Zotero book import with PDF attachment through Zotero's local connector.
- Preserve the rename-first workflow and allow renamed PDFs to be imported afterward.
- Report Zotero availability and attachment errors in the app.
- Ship a Developer ID signed, notarized, and stapled macOS release.

## 0.1.0 — 2026-07-03

- Initial public release.
- Extract ISBNs from PDF text and filenames.
- Look up metadata through Open Library, Google Books, and Library of Congress.
- Review titles and rename PDFs.
