# Guide: Merging Multiple Feature Branches with Platform Implementations

This guide documents the process of merging multiple feature branches that modify platform implementations (Android/iOS) and Pigeon definitions.

## Context

This repo is a fork of flutter/packages with custom features added via feature branches. Common features involve:
- Platform interface changes (video_player_platform_interface)
- Android implementation (video_player_android)
- iOS implementation (video_player_avfoundation)
- Pigeon definitions and generated code
- Public API in video_player package

## Process Overview

### 1. Create Feature Branch Structure

Each feature should have its own branch from `main`:
```bash
git checkout -b feature/<name> main
```

Common feature branches:
- `feature/live` - Live stream detection
- `feature/pip` - Picture-in-Picture support
- `feature/audio` - Audio track selection
- `all_features` - Combined feature branch

### 2. Cherry-picking from Upstream PRs

When integrating features from upstream flutter/packages PRs:

```bash
# Add upstream remote (if not already added)
git remote add upstream https://github.com/flutter/packages.git

# Fetch specific PR
git fetch upstream pull/<PR_NUMBER>/head:pr-<PR_NUMBER>

# Check what files changed (filter for video_player only)
git diff --name-only main..pr-<PR_NUMBER> | grep video_player

# Checkout relevant package files
git checkout pr-<PR_NUMBER> -- packages/video_player/video_player_android/
git checkout pr-<PR_NUMBER> -- packages/video_player/video_player_avfoundation/
git checkout pr-<PR_NUMBER> -- packages/video_player/video_player/

# Commit
git add .
git commit -m "feat: Add <feature> from upstream PR #<PR_NUMBER>"
```

**Important**: For audio tracks or similar controller-level features, you need THREE PRs:
- Platform interface PR (usually already merged in main)
- Android implementation PR
- iOS implementation PR
- Main PR with controller API (cherry-pick only video_player package changes, not examples)

### 3. Regenerating Pigeon Files

After cherry-picking, always regenerate Pigeon files with your local version:

```bash
# Android
cd packages/video_player/video_player_android
dart run pigeon --input pigeons/messages.dart

# iOS
cd packages/video_player/video_player_avfoundation
dart run pigeon --input pigeons/messages.dart
```

Commit the regenerated files:
```bash
git add <pigeon_generated_files>
git commit -m "chore: Regenerate Pigeon files with local Pigeon version"
```

### 4. Merging Feature Branches

When merging multiple feature branches (e.g., into `all_features`):

```bash
git checkout all_features
git merge feature/<name> --no-edit
```

**You WILL get conflicts** in:
- `pigeons/messages.dart` files (source of truth)
- Generated Pigeon files (`.g.dart`, `.g.h`, `.g.m`, `Messages.kt`)
- Platform implementation files (`.dart`, `.java`, `.m`)
- `pubspec.yaml` files

### 5. Resolving Conflicts

#### A. Pigeon Definition Files (`pigeons/messages.dart`)

These are the source of truth. Conflicts happen in the API interface definitions.

**Strategy**: Keep ALL methods from both branches.

Example conflict:
```dart
@HostApi()
abstract class VideoPlayerInstanceApi {
  // ... existing methods ...

<<<<<<< HEAD
  bool isLive();
=======
  NativeAudioTrackData getAudioTracks();
  void selectAudioTrack(int groupIndex, int trackIndex);
>>>>>>> feature/audio
}
```

**Resolution**: Keep both:
```dart
@HostApi()
abstract class VideoPlayerInstanceApi {
  // ... existing methods ...

  bool isLive();
  NativeAudioTrackData getAudioTracks();
  void selectAudioTrack(int groupIndex, int trackIndex);
}
```

Do this for BOTH:
- `packages/video_player/video_player_android/pigeons/messages.dart`
- `packages/video_player/video_player_avfoundation/pigeons/messages.dart`

#### B. Platform Implementation Files

After resolving Pigeon definitions, resolve platform implementation conflicts.

**For Dart files** (e.g., `avfoundation_video_player.dart`):
- Merge override methods at the class level (AVFoundationVideoPlayer)
- Merge instance methods in _PlayerInstance class
- Keep ALL methods from both branches

**For Native files** (`.java`, `.m`):
- Usually auto-merge well
- If conflicts occur, keep both implementations

#### C. Generated Pigeon Files

**DO NOT manually resolve these conflicts!**

After resolving the source `pigeons/messages.dart` files:

```bash
# Regenerate Android
cd packages/video_player/video_player_android
dart run pigeon --input pigeons/messages.dart

# Regenerate iOS
cd packages/video_player/video_player_avfoundation
dart run pigeon --input pigeons/messages.dart

# Stage all files (regeneration resolves conflicts)
git add -A
```

#### D. pubspec.yaml Conflicts

Usually conflicts in dependency_overrides section.
Keep the version from your repo (HEAD) with correct relative paths.

### 6. Committing the Merge

```bash
git add -A
git commit -m "Merge feature/<name> into all_features

Combined features:
- Feature 1 description
- Feature 2 description
- Feature 3 description

Resolved conflicts by:
- Merging Pigeon definitions to include all methods
- Regenerating all Pigeon files
- Combining platform implementations"
```

### 7. Verification

Run analysis on all packages:

```bash
# iOS
cd packages/video_player/video_player_avfoundation
dart analyze lib/

# Android
cd packages/video_player/video_player_android
dart analyze lib/

# Main package
cd packages/video_player/video_player
dart analyze lib/
```

Minor linter warnings are okay (like `omit_obvious_local_variable_types`).
Fix any errors before proceeding.

## Common Patterns

### Platform Interface Already in Main

If the platform interface changes are already merged into `main` (common for flutter/packages PRs), you only need to cherry-pick:
1. Android implementation
2. iOS implementation
3. Controller-level API from main PR (video_player package only)

### Missing Controller-Level API

If you cherry-picked platform implementations but forgot the controller API:

```bash
# Fetch the main PR that has controller changes
git fetch upstream pull/<MAIN_PR>/head:pr-<MAIN_PR>

# Extract only the video_player package files (not examples!)
git show pr-<MAIN_PR>:packages/video_player/video_player/lib/video_player.dart > /tmp/controller.dart
cp /tmp/controller.dart packages/video_player/video_player/lib/video_player.dart

# Same for pubspec if version changed
git show pr-<MAIN_PR>:packages/video_player/video_player/pubspec.yaml > /tmp/pubspec.yaml
cp /tmp/pubspec.yaml packages/video_player/video_player/pubspec.yaml

git add packages/video_player/video_player/
git commit -m "feat(video_player): Add controller-level API"
```

### Testing Locally

The pubspec.yaml files have dependency_overrides for local testing:

```yaml
dependency_overrides:
  video_player_android:
    path: ../../video_player/video_player_android
  video_player_avfoundation:
    path: ../../video_player/video_player_avfoundation
  video_player_platform_interface:
    path: ../../video_player/video_player_platform_interface
```

Keep these - they're useful for testing changes across packages.

## Troubleshooting

### "The named parameter 'X' isn't defined"

This means the platform interface doesn't have the parameter yet.
- Check if you have the latest platform interface changes
- May need to cherry-pick platform interface PR first

### Pigeon generation fails

- Ensure pigeon is in dev_dependencies in pubspec.yaml
- Run `flutter pub get` first
- Check that the Pigeon definition syntax is correct (no merge markers!)

### Methods not available in controller

You need to cherry-pick the main PR's video_player package changes, not just platform implementations.

## Branch Structure

```
main (upstream flutter/packages fork)
├── feature/live (live stream detection)
├── feature/pip (Picture-in-Picture)
├── feature/audio (audio track selection)
└── all_features (combined branch)
    └── Contains: live + pip + audio
```

## File Structure Reference

```
packages/video_player/
├── video_player/                          # Public API package
│   ├── lib/video_player.dart             # Controller with public methods
│   └── pubspec.yaml
├── video_player_platform_interface/      # Platform interface
│   └── lib/video_player_platform_interface.dart
├── video_player_android/                 # Android implementation
│   ├── android/src/main/java/...         # Java/Kotlin native code
│   ├── android/src/main/kotlin/Messages.kt  # Generated
│   ├── lib/src/android_video_player.dart # Dart platform impl
│   ├── lib/src/messages.g.dart           # Generated
│   └── pigeons/messages.dart             # SOURCE OF TRUTH
└── video_player_avfoundation/            # iOS implementation
    ├── darwin/.../Sources/.../*.m        # Objective-C native code
    ├── darwin/.../include/.../messages.g.h  # Generated
    ├── darwin/.../messages.g.m           # Generated
    ├── lib/src/avfoundation_video_player.dart  # Dart platform impl
    ├── lib/src/messages.g.dart           # Generated
    └── pigeons/messages.dart             # SOURCE OF TRUTH
```

## Key Principles

1. **Pigeon definitions are source of truth** - Always resolve conflicts in `pigeons/messages.dart` first
2. **Regenerate, don't manually edit** - Never manually resolve conflicts in generated files
3. **Keep all methods** - When merging features, keep ALL methods from both branches
4. **Cherry-pick carefully** - For controller APIs, only take video_player package changes, not examples
5. **Test each package** - Run dart analyze on each modified package
6. **Commit strategically** - Separate commits for: feature cherry-pick, Pigeon regen, merge resolution

## Example: Full Workflow

```bash
# 1. Create feature branch
git checkout -b feature/audio main

# 2. Fetch and cherry-pick upstream PRs
git fetch upstream pull/10312/head:pr-10312  # Android
git fetch upstream pull/10313/head:pr-10313  # iOS
git fetch upstream pull/9925/head:pr-9925    # Main PR

# 3. Cherry-pick implementations
git checkout pr-10312 -- packages/video_player/video_player_android/
git add . && git commit -m "feat(android): Add audio track selection"

git checkout pr-10313 -- packages/video_player/video_player_avfoundation/
git add . && git commit -m "feat(ios): Add audio track selection"

# 4. Regenerate Pigeon
cd packages/video_player/video_player_android && dart run pigeon --input pigeons/messages.dart
cd ../video_player_avfoundation && dart run pigeon --input pigeons/messages.dart
cd ../..
git add . && git commit -m "chore: Regenerate Pigeon files"

# 5. Add controller API
git show pr-9925:packages/video_player/video_player/lib/video_player.dart > /tmp/controller.dart
cp /tmp/controller.dart packages/video_player/video_player/lib/video_player.dart
git add . && git commit -m "feat(video_player): Add controller-level audio API"

# 6. Merge into all_features
git checkout all_features
git merge feature/audio --no-edit
# ... resolve conflicts as per guide ...
git add -A && git commit -m "Merge feature/audio into all_features"

# 7. Verify
cd packages/video_player/video_player_avfoundation && dart analyze lib/
cd ../video_player_android && dart analyze lib/
cd ../video_player && dart analyze lib/
```

---

**Last Updated**: December 2024
**Maintainer**: For questions, see commit history
