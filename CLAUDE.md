# CLAUDE.md

Guidance for agents working in this repo (the `scout_flutter` package on pub.dev).

## Releasing

scout-flutter is the **last** step of the mobile SDK release chain. Its native side pins artifacts
published from [scout-kotlin-multiplatform](https://github.com/base-14/scout-kotlin-multiplatform):

- `android/build.gradle` pins `implementation 'io.base14:scout-android:<Y>'` from Maven Central.
- `ios/scout_flutter/Package.swift` pins `revision: "ios-<Y>"`, a git tag in that repo.

The full order is in scout-kotlin-multiplatform's
[`RELEASING.md`](https://github.com/base-14/scout-kotlin-multiplatform/blob/main/RELEASING.md):

1. Release scout-core.
2. Update the scout-android and scout-ios pins to the new core.
3. Release scout-android and scout-ios, and wait until they are live on Maven Central.
4. Update the scout-kmp pins and release scout-kmp.
5. Update this repo's pins and release scout-flutter.

### Releasing this repo (step 5)

Only start once `io.base14:scout-android:<Y>` is live on Maven Central and the `ios-<Y>` tag exists:

```bash
curl -sfI https://repo1.maven.org/maven2/io/base14/scout-android/Y/scout-android-Y.pom >/dev/null && echo live
gh api repos/base-14/scout-kotlin-multiplatform/git/ref/tags/ios-Y >/dev/null && echo tagged
```

1. Make one release commit on `main` (`release <version>: pin scout-android Y and scout-ios Y`):
   - Update the two pins above.
   - Set the new version in both `pubspec.yaml` `version:` and `lib/src/scope.dart`
     `kScopeVersion`. `scope_version_sync_test.dart` enforces that they match.
   - In `CHANGELOG.md`, change `## Unreleased` to `## <version>`.
2. Run `make ci`, push, and wait for CI.
3. Get explicit human confirmation, then run `make release`. It tags `v<version>`, and
   `.github/workflows/publish.yml` publishes to pub.dev. This can't be undone.

A change that needs unreleased native APIs (for example a PR that bumps the pins) must not merge
before its native versions are published.

## Local build

- Use `make ci` (format check, analyze, test).
- To test against an unreleased KMP build, publish it to mavenLocal with a `-local` version and
  point the pin at it temporarily. Never commit a `-local` pin.
