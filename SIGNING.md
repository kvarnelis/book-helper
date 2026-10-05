# Book Helper release signing

Book Helper public releases must be built from the canonical `build/DerivedData` output and signed with:

`Developer ID Application: Kazys Varnelis (PHCL25Z99X)`

Use hardened runtime and a secure timestamp. Submit the signed app archive and DMG with the machine-wide `notary` keychain profile, wait for acceptance, staple the app and DMG, and validate both staples. Verify the final app with `codesign --verify --deep --strict`, `spctl --assess --type execute`, and a second verification after mounting or extracting each published artifact.

The public GitHub history must never receive raw private Forgejo history. Build a clean public commit descending from the existing public GitHub tip and include only audited application source, documentation, and release-support files. Exclude personal library exports, local agent configuration, credentials, diagnostic probes containing personal identifiers, unrelated binaries, build products, and private logs.
