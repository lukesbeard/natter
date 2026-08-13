# Fork changes

Personal fork of [iannuttall/natter](https://github.com/iannuttall/natter) with a
few dictation workflow changes.

## Features added

- **Fn (Globe) as a wake key.** New `ModifierHotKey.function` case (keycode 63,
  `.maskSecondaryFn`) so the Fn/Globe key can drive dictation, selectable in
  Settings → Dictation key.
- **Push-to-talk.** Hold the wake key to record, release to stop and send,
  replacing the double-tap-to-start / tap-to-stop gesture
  (`ModifierHotKeyMonitor.handle()`).
- **Media ducking during dictation.** On record start the default output device
  is muted and any now-playing media is paused; both restore the moment the key
  is released (`MediaInterruptionController.swift`, wired into
  `DictationCoordinator`). Muting uses CoreAudio; pausing uses the private
  MediaRemote framework and is best-effort.

## Build note: mlx-swift on Xcode's stock Swift

Upstream depends on `mlx-swift` 0.31.6, whose `Package.swift` declares
`swift-tools-version: 6.3`. Xcode 26.3 ships Swift 6.2.4, so a stock build cannot
resolve it. Rather than install a separate Swift 6.3 toolchain, this fork vendors
a patched copy at `vendor/mlx-swift` and overrides the dependency to it in
`Package.swift`. The three patches are:

1. `Package.swift` line 1: `swift-tools-version` 6.3 → 6.1 (drops the
   experimental `experimentalCGen` trait; the actual code builds fine on 6.2).
2. Remove the `CudaBuild` build-tool plugin from the Cmlx target — it runs `nvcc`
   at build time and is irrelevant on Apple Silicon / Metal.
3. `Source/Encuda/encuda-compile.swift`: split one large array-concatenation
   expression that the 6.2 type-checker could not check in reasonable time.

`vendor/mlx-swift` keeps its upstream `LICENSE` files (MLX and mlx-c are MIT).

Build with `make build` (stock Xcode, no extra toolchain). `build-app.sh` also
passes `-toolchain` through when `TOOLCHAINS` is set, for building against an
explicit toolchain if ever needed.
