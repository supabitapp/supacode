import ProjectDescription

let workspace = Workspace(
  name: "supacode",
  projects: [
    ".",
  ],
  schemes: [
    .scheme(
      name: "supacode",
      buildAction: .buildAction(
        targets: [
          .project(path: "supacode.xcodeproj", target: "supacode"),
        ],
        runPostActionsOnFailure: true
      ),
      testAction: .targets(
        [
          .testableTarget(
            target: .project(path: "supacode.xcodeproj", target: "supacodeTests")
          ),
        ],
        configuration: .debug,
        expandVariableFromTarget: .project(path: "supacode.xcodeproj", target: "supacode")
      ),
      runAction: .runAction(
        configuration: .debug,
        executable: .executable(.project(path: "supacode.xcodeproj", target: "supacode")),
        expandVariableFromTarget: .project(path: "supacode.xcodeproj", target: "supacode")
      ),
      archiveAction: .archiveAction(configuration: .release),
      profileAction: .profileAction(
        configuration: .release,
        executable: .project(path: "supacode.xcodeproj", target: "supacode")
      ),
      analyzeAction: .analyzeAction(configuration: .debug)
    ),
  ]
)
