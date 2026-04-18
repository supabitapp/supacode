import ProjectDescription

let ghosttyXCFrameworkPath: Path = ".build/ghostty/GhosttyKit.xcframework"
let ghosttyResourcesPath: Path = ".build/ghostty/share/ghostty"
let ghosttyTerminfoPath: Path = ".build/ghostty/share/terminfo"
let ghosttyBuildScriptPath: Path = "scripts/build-ghostty.sh"
let verifyGitWtScriptPath: Path = "scripts/verify-git-wt.sh"
let embedGhosttyResourcesScriptPath: Path = "scripts/embed-ghostty-resources.sh"
let embedRuntimeAssetsScriptPath: Path = "scripts/embed-runtime-assets.sh"

func shellScript(_ path: Path) -> String {
  "\"${SRCROOT}/\(path.pathString)\""
}

let ghosttyFingerprintInputScript = """
"${SRCROOT}/\(ghosttyBuildScriptPath.pathString)" --print-fingerprint
"""

let appResources: ResourceFileElements = [
  "supacode/Assets.xcassets",
  "supacode/notification.wav",
]

let appBuildableFolders: [BuildableFolder] = [
  "supacode/App",
  "supacode/Clients",
  "supacode/Commands",
  "supacode/Domain",
  "supacode/Features",
  "supacode/Infrastructure",
  "supacode/Support",
]

let appDependencies: [TargetDependency] = [
  .target(name: "SupacodeSettingsShared"),
  .target(name: "SupacodeSettingsFeature"),
  .target(name: "GhosttyKit"),
  .target(name: "supacode-cli"),
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
  .target(name: "SupacodeSettingsShared"),
  .target(name: "SupacodeSettingsFeature"),
  .target(name: "supacode"),
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
  "$(SRCROOT)/supacode/Resources/Themes/Supacode Light",
  "$(SRCROOT)/supacode/Resources/Themes/Supacode Dark",
  "$(BUILT_PRODUCTS_DIR)/supacode",
  "$(UNINSTALLED_PRODUCTS_DIR)/$(PLATFORM_NAME)/supacode",
]

let embedRuntimeAssetsOutputPaths: [Path] = [
  "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/git-wt/wt",
  "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/Supacode Light",
  "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/Supacode Dark",
  "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/bin/supacode",
]

let project = Project(
  name: "supacode",
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
      name: "supacode-cli",
      destinations: .macOS,
      product: .commandLineTool,
      bundleId: "app.supabit.supacode.cli",
      deploymentTargets: .macOS("26.0"),
      infoPlist: .default,
      buildableFolders: [
        "supacode-cli",
      ],
      dependencies: [
        .external(name: "ArgumentParser"),
      ],
      settings: .settings(
        base: [
          "CODE_SIGNING_ALLOWED": "NO",
          "ENABLE_HARDENED_RUNTIME": "YES",
          "PRODUCT_MODULE_NAME": "supacode_cli",
          "PRODUCT_NAME": "supacode",
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
      name: "SupacodeSettingsShared",
      destinations: .macOS,
      product: .staticFramework,
      bundleId: "app.supabit.supacode.settings-shared",
      deploymentTargets: .macOS("26.0"),
      infoPlist: .default,
      buildableFolders: [
        "SupacodeSettingsShared",
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
      name: "SupacodeSettingsFeature",
      destinations: .macOS,
      product: .staticFramework,
      bundleId: "app.supabit.supacode.settings-feature",
      deploymentTargets: .macOS("26.0"),
      infoPlist: .default,
      buildableFolders: [
        "SupacodeSettingsFeature",
      ],
      dependencies: [
        .target(name: "SupacodeSettingsShared"),
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
      name: "supacode",
      destinations: .macOS,
      product: .app,
      bundleId: "app.supabit.supacode",
      deploymentTargets: .macOS("26.0"),
      infoPlist: .file(path: "supacode/Info.plist"),
      resources: appResources,
      buildableFolders: appBuildableFolders,
      scripts: [
        .pre(
          script: shellScript(verifyGitWtScriptPath),
          name: "Verify git-wt",
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
        ],
        debug: [
          "CODE_SIGN_ENTITLEMENTS": "supacode/supacodeDebug.entitlements",
        ],
        release: [
          "CODE_SIGN_ENTITLEMENTS": "supacode/supacode.entitlements",
        ],
        defaultSettings: .essential
      )
    ),
    .target(
      name: "supacodeTests",
      destinations: .macOS,
      product: .unitTests,
      bundleId: "app.supabit.supacodeTests",
      deploymentTargets: .macOS("26.1"),
      infoPlist: .default,
      buildableFolders: [
        "supacodeTests",
      ],
      dependencies: testDependencies,
      settings: .settings(
        base: [
          "BUNDLE_LOADER": "$(TEST_HOST)",
          "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/supacode.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/supacode",
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
