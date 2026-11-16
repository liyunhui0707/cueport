# Versioning and releases

The owner selected MIT and the initial experimental version **0.1.0-alpha.1**.
The Git tag is `v0.1.0-alpha.1`; `VERSION` is the full release label. macOS's
numeric `CFBundleShortVersionString` is `0.1.0`; `BUILD_NUMBER` is explicitly
`1` for this first delivery. `AARReleaseVersion` preserves the full alpha label.
Neither app builds nor CI automatically increment these values.

Select future release scope/version and an increasing build number explicitly.
Never replace an existing published tag or silently overwrite a release asset.
Releases currently use ad-hoc signing, no notarization, manual installation and
app-only rollback. Prerelease channel status does not imply formal P0 acceptance.

The push/pull-request workflow runs source tests and builds only; it does not
publish, tag, upload assets or modify the repository. Remote CI is evidence only
after that exact source commit's run succeeds.
