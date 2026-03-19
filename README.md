<p align="center">
  <img src="Resources/AppIcon-Source.png" width="128" height="128" alt="FreeFlow icon">
</p>

<h1 align="center">FreeFlow</h1>

<p align="center">
  Free and open source macOS dictation with context-aware post-processing.
</p>

<p align="center">
  <a href="https://github.com/marcbodea/freeflow/releases/latest/download/FreeFlow.dmg"><b>Download FreeFlow.dmg</b></a><br>
  <a href="https://github.com/marcbodea/freeflow/releases/latest/download/FreeFlow.app.zip"><b>Download FreeFlow.app.zip</b></a>
</p>

This repository is the source of truth for the rebranded FreeFlow app. Signed and notarized releases are published from [`main`](https://github.com/marcbodea/freeflow/tree/main) to [`marcbodea/freeflow`](https://github.com/marcbodea/freeflow).

## Local Development

1. Generate the project if needed: `make xcodeproj`
2. Open `FreeFlow.xcodeproj`
3. Run the `FreeFlow Dev` scheme

`FreeFlow Dev` uses the bundle ID `com.marcbodea.freeflow.dev`, disables the updater, and signs ad hoc for local iteration. SwiftUI previews are available for the setup, settings, menu bar, and pipeline debug surfaces. For behavior work outside previews, use incremental Debug runs from Xcode.

Helpful commands:

- `make dev` builds the `FreeFlow Dev` app with `xcodebuild`
- `make test` runs the Debug test suite through the `FreeFlow Dev` scheme
- `make release-artifacts` creates unsigned local release artifacts in `build/`
- `make version` prints the current marketing version, build number, and release tag
- `make bump-build`, `make bump-patch`, `make bump-minor`, and `make bump-major` update `Config/Base.xcconfig`
- `make set-version VERSION=0.2.0` and `make set-build BUILD=42` set explicit values

## Release Pipeline

The canonical GitHub Actions workflow is [`.github/workflows/ci.yml`](./.github/workflows/ci.yml).

- The workflow runs only when started manually from the GitHub Actions UI
- Run `validate` to build and test without creating a release
- Run `release` from the `main` branch to build a signed universal release, notarize the DMG, and create a GitHub release
- Release tags use the format `vMARKETING_VERSION-bCURRENT_PROJECT_VERSION`
- Release assets are `FreeFlow.dmg` and `FreeFlow.app.zip`

Required GitHub secrets:

- `DEVELOPER_ID_CERTIFICATE_BASE64`
- `DEVELOPER_ID_CERTIFICATE_PASSWORD`
- `APPLE_ID`
- `APPLE_TEAM_ID`
- `APPLE_APP_PASSWORD`

## App Identity

The shipped app identity is now:

- Release: `com.marcbodea.freeflow`
- Development: `com.marcbodea.freeflow.dev`

This is a clean identity break. Existing `com.zachlatta.freeflow` installs do not migrate preferences, setup state, login-item registration, or keychain namespace automatically. Users upgrading from the old identity need to re-run setup and re-enable launch at login.

## Release Maintenance

- Regenerate the committed project with `make xcodeproj` after changing `project.yml`
- Local release packaging uses `xcodebuild`, `ditto`, and `hdiutil`; there is no `create-dmg` or `fileicon` dependency in CI
- `scripts/archive_release.sh` produces `build/FreeFlow.app` and `build/FreeFlow.app.zip`
- `scripts/package_dmg.sh` produces `build/FreeFlow.dmg`
- Bump the version before a release push with `make bump-build` or one of the semver bump targets
- Manual `release` runs fail if the computed tag already exists, so each shipped release needs a new version/build

## Attribution

This repo started from the original FreeFlow project by Zach Latta. The current shipped app, release pipeline, and bundle identity in this repository point entirely at `marcbodea/freeflow`.

## License

Licensed under the MIT license.
