# Releasing Book Helper

The app version and build number are authoritative in both configurations of `BookHelper.xcodeproj/project.pbxproj`. There is one source layout (`BookHelper/`) and one build location (`build/DerivedData`). The previous standalone repository's generated `project.yml` has been superseded by this checked-in project.

## Validation and artifacts

1. Update the marketing version and monotonically increasing `YYYYMMDD.N` build number, README, and changelog.
2. Run `Tests/run.sh`. Fixtures are generated only under `build/DerivedData`; never add PDFs, EPUBs, book lists, library exports, test outputs, or private logs to Git.
3. Build the `BookHelper` scheme in Release with `-derivedDataPath build/DerivedData ARCHS=arm64 CODE_SIGNING_ALLOWED=NO`.
4. Follow [SIGNING.md](../SIGNING.md): sign the resolved Release app with Developer ID, hardened runtime and timestamp; notarize the app archive, then staple and validate the app. Package the stapled app as ZIP and as a DMG containing only the app and an Applications shortcut. Sign and notarize the DMG, then staple and validate it.
5. Extract the final ZIP and mount the final DMG read-only. Verify each contained app's signature, notarization ticket, version/build, architecture, and allowed file inventory. Verify the DMG signature and ticket. Generate SHA-256 checksums after final stapling.
6. Publish the tested ZIP, DMG and checksums with the matching GitHub tag. Never label unsigned or unnotarized artifacts as a completed release.

## Source publication boundary

The development repository is on private Forgejo. GitHub's Book Helper repository has a separate clean history. A public release commit must descend from the current GitHub tip and contain only the audited application source, icons, tests, documentation, project and release-support files. Never merge or push private Forgejo history to GitHub. Review every newly reachable commit and blob before publishing, including existing history before changing visibility.

The public source tree excludes local agent configuration. Books and inventories are excluded from both destinations. Keep the original personal files untouched; do not remove them to prepare a release.
