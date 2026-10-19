# Build traceability

Every ControlWard.app built by `bin/build-native-app` can be traced to a commit.

`bin/stamp-build-info` stamps the copy of `Info.plist` inside the bundle before code signing. The source `native-crm/Resources/Info.plist` is never edited. It writes:

| Key | Value |
| --- | --- |
| `CFBundleVersion` | base build + number of commits since the base commit |
| `ControlWardGitCommit` | full SHA of `HEAD` |
| `ControlWardGitDirty` | `true` if tracked files had uncommitted changes |

The base is in `native-crm/Resources/build-number-base` (`<commit> <build>`), starting at `001c7cd 103`, the build installed from PR #14. Each merge to `main` raises the build number with no manual edit. Builds from other branches get their own numbers, so the commit SHA is the identity; the build number is for ordering.

The stamp refuses to run outside a git checkout or when the base commit is missing (shallow clone). Fetch full history in CI (`fetch-depth: 0`).

`bin/package-native-app` names archives `ControlWard-<version>-<build>-<short sha>-macOS.zip`.

Check an installed app:

```sh
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' -c 'Print :ControlWardGitCommit' -c 'Print :ControlWardGitDirty' /Applications/ControlWard.app/Contents/Info.plist
```

It is also shown under ControlWard → About ControlWard, for example `1.1.1 (104, 1a2b3c4)`.

To raise the marketing version, edit `CFBundleShortVersionString` as before. To reset build numbering, update `build-number-base` deliberately; keep the number higher than any shipped build.

Tests: `bin/test-native-app` runs `BuildInfoTests` (parsing and the About line) and `bin/test-build-stamp` (the stamping script, against a throwaway repo).
