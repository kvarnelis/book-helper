# Book identification and rename

Book Helper supports PDF and DRM-free EPUB 2/3 files. `BookFileFormat` is shared by the picker, drop handler, rename validation and Zotero eligibility.

## EPUB decisions

`EPUBExtractor` is an actor with a non-suspending extraction operation, so a batch cannot keep multiple expanded archives alive across awaits. It reads the package selected by `META-INF/container.xml`, then Dublin Core metadata. An embedded title is sufficient for offline review/rename; it is not overwritten with a potentially different catalog edition. EPUB 3 main-title/creator refinements and EPUB 2 author roles are handled. An ISBN is accepted only after the existing checksum validation.

If title or ISBN is absent, scan the first 10 and last 3 spine XHTML resources, deduplicated. Preserve inline text order; ignore head, script and style content. If there is still no title, use at most 5 ISBN and 5 LCCN candidates in the existing catalog lookup flow, then filename title/author matching. Remote resources are never fetched.

The original EPUB is moved, not rewritten or converted. It retains its extension, including case. Existing target names receive a numeric suffix. Renamed EPUBs can be cleared from the list without deleting files.

## Archive and XML bounds

`BoundedZIPArchive` uses system zlib; no package installation or external unzip process is required. No archive member is ever written to disk. ZIP directory and local headers, record bounds, duplicate names, overlapping entries, compression results and CRCs are checked. Reject absolute/traversing entry paths, special files/symlinks, ZIP encryption, unsupported compression, multiple volumes and ZIP64. URI references may use `..` only while remaining within the archive root. Stored and raw-deflate ZIP entries and data descriptors are supported.

- Archive input: at most 128 MiB and 10,000 entries.
- Declared expanded sizes: at most 32 MiB per entry and 256 MiB total.
- Expanded data actually read: at most 12 MiB per book; inflation output is bounded independently of declared size.
- Container/encryption XML: at most 256 KiB each; package XML: 1 MiB.
- XHTML: at most 2 MiB per chapter and 8 MiB total; oversized chapters are skipped.
- XML: UTF-8 or BOM-marked UTF-16; depth 64, 50,000 nodes per document. Custom entity declarations are rejected, and external entity resolution is disabled.
- Identifier matching: at most 256 matches per pattern and 64 unique candidates per text scan.

DRM/encryption and Adobe rights descriptors produce an unreadable-file state that cannot be bypassed by manual ISBN entry. Standard IDPF/Adobe font obfuscation is allowed only for declared font resources; fonts are neither decoded nor rendered. This is not a general EPUB reader or validator: unsupported formats and malformed selected content produce an error rather than being repaired.

## Zotero boundary

EPUB attachment integration is deferred. The interface says “Import PDFs to Zotero”; eligibility excludes EPUBs, and `ZoteroClient.importBook` rejects non-PDF input before any request. PDF page-count extraction and attachment payloads remain unchanged. No EPUB page count is inferred.

## Verification

`Tests/run.sh` generates synthetic archives and a one-page PDF under the canonical `build/DerivedData/EPUBTests` directory. Tests exercise metadata/text/filename paths, malformed and hostile archives, rename collisions and exact byte preservation, selection/status behavior, and PDF regressions. Catalog lookups use an injected stub. Zotero uses an injected URLSession with a capturing URLProtocol; no test reaches a live library. Offscreen NSHostingView snapshots verify the actual SwiftUI content without opening the installed app or sending desktop input.

## Release reconciliation

Version 1.0 merges the EPUB work with the standalone Book Helper branch’s PDF fixes: rename PDFs before attachment upload, ASCII-escape Unicode JSON in the attachment HTTP header, and honor the optional switch-to-Zotero preference after every selected PDF succeeds. Imports remain sequential so the last-book notice stays accurate, and the remove-imported preference remains available. EPUBs never enter this path. The offline regression suite uses injected preferences, app activation, and a capturing URLSession to verify these behaviors without opening Zotero.
