# Supacode

Native terminal coding agents command center.

![screenshot](https://www.supacode.sh/screenshot.png)

## Technical Stack

- [The Composable Architecture](https://github.com/pointfreeco/swift-composable-architecture)
- [libghostty](https://github.com/ghostty-org/ghostty)

## Requirements

- macOS 26.0+
- [mise](https://mise.jdx.dev/) (for pinned toolchain dependencies, including Tuist)

## Building

```bash
make build-ghostty-xcframework   # Build GhosttyKit from Zig source
make generate-project            # Install packages and generate when manifest inputs changed
make build-app                   # Generate if needed, then build macOS app (Debug)
make profile-compile             # Force a clean profiled Debug build and write compile hotspot reports
make run-app                     # Generate if needed, then build and launch
```

`supacode.xcworkspace` and `supacode.xcodeproj` are generated outputs and stay out of git.

## Development

```bash
make check     # Run swiftformat and swiftlint
make test      # Generate if needed, then run tests
make format    # Run swift-format
make profile-compile-update-baseline  # Refresh the tracked compile-time baseline
```

## Contributing

- I actual prefer a well written issue describing features/bugs u want rather than a vibe-coded PR
- I review every line personally and will close if I feel like the quality is not up to standard
