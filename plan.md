# macOS 13.0 Compatibility Plan

## Context
Supacode currently targets macOS 26.0+. The goal is to lower the deployment target to macOS 13.0 (Ventura).

## Implementation Progress

### Task 1: Lower deployment targets in Project.swift
- [ ] Change all .macOS("26.0") → .macOS("13.0")
- [ ] Change test target .macOS("26.1") → .macOS("13.0")

### Task 2: Create GlassEffectCompat modifier
- [ ] New file: Support/GlassEffectCompat.swift
- macOS 16+: .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
- macOS 13-15: .visualEffect(.material(.regular).blendingMode(.withinWindow)) + .clipShape(.rect(cornerRadius:))

### Task 3: Update SidebarCardView
- [ ] Replace .glassEffect → .glassEffectCompat(cornerRadius: 10)

### Task 4: Guard macOS 15.0+ modifiers
- [ ] scrollBounceBehavior (7 files)
- [ ] scrollContentBackground (1)
- [ ] scrollIndicators (1)
- [ ] fileImporter (2)
- [ ] onDragSessionUpdated (1)
- [ ] contentShape(.interaction/dragPreview) (4)

### Task 5: Guard macOS 16.0+ modifiers
- [ ] phaseAnimator (2)
- [ ] toolbarBackgroundVisibility (1)
- [ ] toolbarBackground (1)
- [ ] windowToolbarStyle (3)
- [ ] toolbarColorScheme (1)

### Task 6: Guard macOS 14.0 APIs
- [ ] TimelineView (2)
- [ ] searchable(placement:) (1)

### Task 7: Guard macOS 26.0 APIs
- [ ] clipShape(.rect(cornerRadius:)) (3)
- [ ] background(in: .rect) (1)
- [ ] buttonBorderShape (1)

## Verification
1. make format
2. make lint
3. make build-app
4. make test
