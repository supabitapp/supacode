import ProjectDescription

let ghosttyXCFrameworkPath: Path = ".build/ghostty/GhosttyKit.xcframework"
let ghosttyResourcesPath: Path = ".build/ghostty/share/ghostty"
let ghosttyTerminfoPath: Path = ".build/ghostty/share/terminfo"
let ghosttyBuildScriptPath: Path = "scripts/build-ghostty.sh"
let verifyGitWtScriptPath: Path = "scripts/verify-git-wt.sh"
let zmxBuildScriptPath: Path = "scripts/build-zmx.sh"
let zmxBinaryPath: Path = ".build/zmx/bin/zmx"
let embedGhosttyResourcesScriptPath: Path = "scripts/embed-ghostty-resources.sh"
let embedRuntimeAssetsScriptPath: Path = "scripts/embed-runtime-assets.sh"

func shellScript(_ path: Path) -> String {
  "\"${SRCROOT}/\(path.pathString)\""
}

let ghosttyFingerprintInputScript = """
"${SRCROOT}/\(ghosttyBuildScriptPath.pathString)" --print-fingerprint
"""

let appResources: ResourceFileElements = [
  "tty7/AppIcon.icon",
  "tty7/Assets.xcassets",
  "tty7/notification.wav",
]

let appBuildableFolders: [BuildableFolder] = [
  "tty7/App",
  "tty7/Clients",
  "tty7/Commands",
  "tty7/Domain",
  "tty7/Features",
  "tty7/Infrastructure",
  "tty7/Support",
]

let appDependencies: [TargetDependency] = [
  .target(name: "Tty7SettingsShared"),
  .target(name: "Tty7SettingsFeature"),
  .target(name: "GhosttyKit"),
  .target(name: "tty7-cli"),
  .external(name: "ComposableArchitecture"),
  .external(name: "CustomDump"),
  .external(name: "Dependencies"),
  .external(name: "IdentifiedCollections"),
  .external(name: "Kingfisher"),
  .external(name: "OrderedCollections"),
  .external(name: "PostHog"),
  .external(name: "Sentry"),
  .external(name: "Sharing"),
  .external(name: "Sparkle"),
]

let testDependencies: [TargetDependency] = [
  .target(name: "GhosttyKit"),
  .target(name: "Tty7SettingsShared"),
  .target(name: "Tty7SettingsFeature"),
  .target(name: "tty7"),
  .external(name: "Clocks"),
  .external(name: "ComposableArchitecture"),
  .external(name: "ConcurrencyExtras"),
  .external(name: "CustomDump"),
  .external(name: "Dependencies"),
  .external(name: "DependenciesTestSupport"),
  .external(name: "IdentifiedCollections"),
  .external(name: "OrderedCollections"),
  .external(name: "Sharing"),
]

let embedGhosttyResourcesInputPaths: [FileListGlob] = [
  "$(SRCROOT)/\(ghosttyResourcesPath.pathString)",
  "$(SRCROOT)/\(ghosttyTerminfoPath.pathString)",
]

let embedGhosttyResourcesOutputPaths: [Path] = [
  "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/ghostty",
  "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/terminfo",
]

let embedRuntimeAssetsInputPaths: [FileListGlob] = [
  "$(SRCROOT)/Resources/git-wt/wt",
  "$(SRCROOT)/\(zmxBinaryPath.pathString)",
  "$(SRCROOT)/tty7/Resources/Themes/tty7 Light",
  "$(SRCROOT)/tty7/Resources/Themes/tty7 Dark",
  "$(BUILT_PRODUCTS_DIR)/tty7",
  "$(UNINSTALLED_PRODUCTS_DIR)/$(PLATFORM_NAME)/tty7",
]

let embedRuntimeAssetsOutputPaths: [Path] = [
  "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/git-wt/wt",
  "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/zmx/zmx",
  "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/tty7 Light",
  "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/tty7 Dark",
  "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/bin/tty7",
]

let project = Project(
  name: "tty7",
  settings: .settings(
    base: [
      "CLANG_ENABLE_MODULES": "YES",
      "CODE_SIGN_STYLE": "Automatic",
      "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
      "SWIFT_APPROACHABLE_CONCURRENCY": "YES",
      "SWIFT_DEFAULT_ACTOR_ISOLATION": "MainActor",
      "SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY": "YES",
      "SWIFT_VERSION": "6.0",
    ],
    configurations: [
      .debug(name: .debug, xcconfig: "Configurations/Project.xcconfig"),
      .release(name: .release, xcconfig: "Configurations/Project.xcconfig"),
    ],
    defaultSettings: .essential
  ),
  targets: [
    .target(
      name: "tty7-cli",
      destinations: .macOS,
      product: .commandLineTool,
      bundleId: "app.supabit.tty7.cli",
      deploymentTargets: .macOS("26.0"),
      infoPlist: .default,
      buildableFolders: [
        "tty7-cli",
      ],
      dependencies: [
        .external(name: "ArgumentParser"),
      ],
      settings: .settings(
        base: [
          "CODE_SIGNING_ALLOWED": "NO",
          "ENABLE_HARDENED_RUNTIME": "YES",
          "PRODUCT_MODULE_NAME": "tty7_cli",
          "PRODUCT_NAME": "tty7",
          "SKIP_INSTALL": "YES",
          "SWIFT_DEFAULT_ACTOR_ISOLATION": "MainActor",
        ],
        defaultSettings: .essential
      )
    ),
    .foreignBuild(
      name: "GhosttyKit",
      destinations: .macOS,
      script: """
        "${SRCROOT}/\(ghosttyBuildScriptPath.pathString)"
        """,
      inputs: [
        .file("mise.toml"),
        .file(ghosttyBuildScriptPath),
        .script(ghosttyFingerprintInputScript),
      ],
      output: .xcframework(path: ghosttyXCFrameworkPath, linking: .static)
    ),
    .target(
      name: "Tty7SettingsShared",
      destinations: .macOS,
      product: .staticFramework,
      bundleId: "app.supabit.tty7.settings-shared",
      deploymentTargets: .macOS("26.0"),
      infoPlist: .default,
      buildableFolders: [
        "Tty7SettingsShared",
      ],
      dependencies: [
        .external(name: "ComposableArchitecture"),
        .external(name: "Dependencies"),
        .external(name: "PostHog"),
        .external(name: "Sharing"),
      ],
      settings: .settings(
        base: [
          "SWIFT_DEFAULT_ACTOR_ISOLATION": "MainActor",
        ],
        defaultSettings: .essential
      )
    ),
    .target(
      name: "Tty7SettingsFeature",
      destinations: .macOS,
      product: .staticFramework,
      bundleId: "app.supabit.tty7.settings-feature",
      deploymentTargets: .macOS("26.0"),
      infoPlist: .default,
      buildableFolders: [
        "Tty7SettingsFeature",
      ],
      dependencies: [
        .target(name: "Tty7SettingsShared"),
        .external(name: "ComposableArchitecture"),
        .external(name: "Dependencies"),
        .external(name: "Sharing"),
      ],
      settings: .settings(
        base: [
          "SWIFT_DEFAULT_ACTOR_ISOLATION": "MainActor",
        ],
        defaultSettings: .essential
      )
    ),
    .target(
      name: "tty7",
      destinations: .macOS,
      product: .app,
      bundleId: "app.supabit.tty7",
      deploymentTargets: .macOS("26.0"),
      infoPlist: .file(path: "tty7/Info.plist"),
      resources: appResources,
      buildableFolders: appBuildableFolders,
      scripts: [
        .pre(
          script: shellScript(verifyGitWtScriptPath),
          name: "Verify git-wt",
          basedOnDependencyAnalysis: false
        ),
        .pre(
          script: shellScript(zmxBuildScriptPath),
          name: "Build zmx",
          basedOnDependencyAnalysis: false
        ),
        .post(
          script: shellScript(embedGhosttyResourcesScriptPath),
          name: "Embed Ghostty Resources",
          inputPaths: embedGhosttyResourcesInputPaths,
          outputPaths: embedGhosttyResourcesOutputPaths,
          basedOnDependencyAnalysis: false
        ),
        .post(
          script: shellScript(embedRuntimeAssetsScriptPath),
          name: "Embed Runtime Assets",
          inputPaths: embedRuntimeAssetsInputPaths,
          outputPaths: embedRuntimeAssetsOutputPaths,
          basedOnDependencyAnalysis: false
        ),
      ],
      dependencies: appDependencies,
      settings: .settings(
        base: [
          "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
          "ENABLE_HARDENED_RUNTIME": "YES",
          "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/../Frameworks",
          "OTHER_LDFLAGS": "$(inherited) -lc++",
          "TTY7_DISPLAY_NAME": "tty7",
        ],
        debug: [
          "CODE_SIGN_ENTITLEMENTS": "tty7/tty7Debug.entitlements",
          // Dev builds get their own bundle id + display name so they run
          // alongside the installed Release app instead of colliding on it via
          // LaunchServices. Safe: there is no single-instance lock, and the
          // agent-hook socket is keyed by pid
          // (/tmp/tty7-<uid>/agent-hook-<pid>.sock). PRODUCT_NAME stays
          // "tty7" so tty7Tests' hardcoded TEST_HOST still resolves.
          "PRODUCT_BUNDLE_IDENTIFIER": "app.supabit.tty7.dev",
          "TTY7_DISPLAY_NAME": "tty7 Dev",
        ],
        release: [
          "CODE_SIGN_ENTITLEMENTS": "tty7/tty7.entitlements",
        ],
        defaultSettings: .essential
      )
    ),
    .target(
      name: "tty7Tests",
      destinations: .macOS,
      product: .unitTests,
      bundleId: "app.supabit.tty7Tests",
      deploymentTargets: .macOS("26.1"),
      infoPlist: .default,
      buildableFolders: [
        "tty7Tests",
      ],
      dependencies: testDependencies,
      settings: .settings(
        base: [
          "BUNDLE_LOADER": "$(TEST_HOST)",
          "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/tty7.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/tty7",
        ],
        defaultSettings: .essential
      )
    ),
  ],
  additionalFiles: [
    "Configurations/**",
  ],
  resourceSynthesizers: []
)
