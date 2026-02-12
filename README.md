# Supacode

A macOS app for running multiple coding agents in isolated worktrees.

<img width="3600" height="2260" alt="image" src="https://github.com/user-attachments/assets/31eb062c-f2d6-406d-8c60-d2f1664a0c21" />

## Technical Stack

- [The Composable Architecture](https://github.com/pointfreeco/swift-composable-architecture)
- [libghostty](https://github.com/ghostty-org/ghostty)

## Requirements

- macOS 26.0+
- [mise](https://mise.jdx.dev/) (for dependencies)

## Building

```bash
make build-ghostty-xcframework  # Build GhosttyKit from Zig source
make build-app                   # Build macOS app (Debug)
make run-app                     # Build and launch
```

## Development

```bash
make check     # Run swiftformat and swiftlint
make test      # Run tests
make format    # Run swift-format
```

## Contributing

Be civilized, I review every single line personally, so I assume you have done the same urself before submitting a PR.

