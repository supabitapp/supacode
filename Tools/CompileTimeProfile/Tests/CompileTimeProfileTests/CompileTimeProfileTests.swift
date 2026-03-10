import Foundation
import Testing

@testable import CompileTimeProfile

struct CompileTimeProfileTests {
  @Test func normalizeCapturesLocalFunctionHotspotsAndBuildSummary() throws {
    let profiler = CompileTimeProfiler(repoRoot: URL(fileURLWithPath: "/repo"), topCount: 10)
    let snapshot = try profiler.normalize(
      log: """
        120.50ms\t/repo/supacode/Features/Slow.swift:10:12\tinstance method supacode.(file).SlowFeature.render()@/repo/supacode/Features/Slow.swift:10:12
        12.50ms\t/repo/Tuist/.build/checkouts/Foo/Sources/Foo.swift:1:1\tglobal function Foo.(file).helper()@/repo/Tuist/.build/checkouts/Foo/Sources/Foo.swift:1:1

        Build Timing Summary

        SwiftCompile (4 tasks) | 3.250 seconds
        Ld (1 task) | 0.500 seconds

        ** BUILD SUCCEEDED **
        """)

    #expect(snapshot.entries.count == 1)
    #expect(snapshot.entries[0].kind == .functionBody)
    #expect(snapshot.entries[0].scope == .local)
    #expect(snapshot.entries[0].location?.path == "supacode/Features/Slow.swift")
    #expect(snapshot.summary.totalBuildDurationMilliseconds == 3750)
    #expect(snapshot.summary.swiftCompileDurationMilliseconds == 3250)
    #expect(snapshot.summary.topLocalFiles.first?.path == "supacode/Features/Slow.swift")
  }

  @Test func normalizeCapturesExpressionWarnings() throws {
    let profiler = CompileTimeProfiler(repoRoot: URL(fileURLWithPath: "/repo"), topCount: 10)
    let snapshot = try profiler.normalize(
      log: """
        /repo/supacode/Features/Slow.swift:42:19: warning: expression took 213.7ms to type-check (limit: 5ms)

        Build Timing Summary

        SwiftCompile (1 task) | 1.000 seconds

        ** BUILD SUCCEEDED **
        """)

    #expect(snapshot.entries.count == 1)
    #expect(snapshot.entries[0].kind == .expressionTypeCheck)
    #expect(snapshot.entries[0].durationMilliseconds == 213.7)
    #expect(snapshot.summary.localExpressionTypeCheckDurationMilliseconds == 213.7)
  }

  @Test func normalizeDeduplicatesRepeatedExpressionWarningsByKeepingTheSlowestSample() throws {
    let profiler = CompileTimeProfiler(repoRoot: URL(fileURLWithPath: "/repo"), topCount: 10)
    let snapshot = try profiler.normalize(
      log: """
        /repo/supacode/Features/Slow.swift:42:19: warning: expression took 12ms to type-check (limit: 5ms)
        /repo/supacode/Features/Slow.swift:42:19: warning: expression took 18ms to type-check (limit: 5ms)

        Build Timing Summary

        SwiftCompile (1 task) | 1.000 seconds

        ** BUILD SUCCEEDED **
        """)

    #expect(snapshot.entries.count == 1)
    #expect(snapshot.entries[0].symbol == "expression type-check")
    #expect(snapshot.entries[0].durationMilliseconds == 18)
  }

  @Test func compareReportsRegressionsImprovementsAddedAndRemoved() {
    let baseline = ProfileSnapshot(
      generatedAt: "2026-03-10T12:00:00.000Z",
      buildSteps: [BuildStepTiming(name: "SwiftCompile", taskCount: 1, durationMilliseconds: 1000)],
      entries: [
        CompileTimeEntry(
          identity: "functionBody|supacode/A.swift|1|1|foo()",
          kind: .functionBody,
          scope: .local,
          durationMilliseconds: 50,
          location: .init(path: "supacode/A.swift", line: 1, column: 1),
          symbol: "foo()"
        ),
        CompileTimeEntry(
          identity: "functionBody|supacode/B.swift|2|1|bar()",
          kind: .functionBody,
          scope: .local,
          durationMilliseconds: 60,
          location: .init(path: "supacode/B.swift", line: 2, column: 1),
          symbol: "bar()"
        ),
      ],
      summary: ProfileSummary(
        totalBuildDurationMilliseconds: 1000,
        swiftCompileDurationMilliseconds: 1000,
        localFunctionBodyDurationMilliseconds: 110,
        localExpressionTypeCheckDurationMilliseconds: 0,
        localEntryCount: 2,
        topLocalFiles: [],
        topLocalFunctions: [],
        topLocalExpressions: []
      )
    )
    let current = ProfileSnapshot(
      generatedAt: "2026-03-10T12:05:00.000Z",
      buildSteps: [BuildStepTiming(name: "SwiftCompile", taskCount: 1, durationMilliseconds: 1100)],
      entries: [
        CompileTimeEntry(
          identity: "functionBody|supacode/A.swift|1|1|foo()",
          kind: .functionBody,
          scope: .local,
          durationMilliseconds: 80,
          location: .init(path: "supacode/A.swift", line: 1, column: 1),
          symbol: "foo()"
        ),
        CompileTimeEntry(
          identity: "expressionTypeCheck|supacode/C.swift|3|1|expression type-check",
          kind: .expressionTypeCheck,
          scope: .local,
          durationMilliseconds: 40,
          location: .init(path: "supacode/C.swift", line: 3, column: 1),
          symbol: "expression type-check"
        ),
      ],
      summary: ProfileSummary(
        totalBuildDurationMilliseconds: 1100,
        swiftCompileDurationMilliseconds: 1100,
        localFunctionBodyDurationMilliseconds: 80,
        localExpressionTypeCheckDurationMilliseconds: 40,
        localEntryCount: 2,
        topLocalFiles: [],
        topLocalFunctions: [],
        topLocalExpressions: []
      )
    )

    let profiler = CompileTimeProfiler(repoRoot: URL(fileURLWithPath: "/repo"), topCount: 10)
    let comparison = profiler.compare(baseline: baseline, current: current)

    #expect(comparison.regressions.count == 1)
    #expect(comparison.regressions[0].deltaMilliseconds == 30)
    #expect(comparison.improvements.isEmpty)
    #expect(comparison.added.count == 1)
    #expect(comparison.removed.count == 1)
    #expect(comparison.summary.totalBuildDurationDeltaMilliseconds == 100)
    #expect(comparison.summary.swiftCompileDurationDeltaMilliseconds == 100)
    #expect(comparison.summary.localFunctionBodyDurationDeltaMilliseconds == -30)
    #expect(comparison.summary.localExpressionTypeCheckDurationDeltaMilliseconds == 40)
  }
}
