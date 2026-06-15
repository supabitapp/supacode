import ProjectDescription

let workspace = Workspace(
  name: "tty7",
  projects: [
    ".",
  ],
  schemes: [
    .scheme(
      name: "tty7",
      buildAction: .buildAction(
        targets: [
          .project(path: "tty7.xcodeproj", target: "tty7"),
        ],
        runPostActionsOnFailure: true
      ),
      testAction: .targets(
        [
          .testableTarget(
            target: .project(path: "tty7.xcodeproj", target: "tty7Tests")
          ),
        ],
        configuration: .debug,
        expandVariableFromTarget: .project(path: "tty7.xcodeproj", target: "tty7")
      ),
      runAction: .runAction(
        configuration: .debug,
        executable: .executable(.project(path: "tty7.xcodeproj", target: "tty7")),
        expandVariableFromTarget: .project(path: "tty7.xcodeproj", target: "tty7")
      ),
      archiveAction: .archiveAction(configuration: .release),
      profileAction: .profileAction(
        configuration: .release,
        executable: .project(path: "tty7.xcodeproj", target: "tty7")
      ),
      analyzeAction: .analyzeAction(configuration: .debug)
    ),
  ]
)
