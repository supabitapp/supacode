import CompileTimeProfile
import Darwin
import Foundation

enum Command {
  case normalize(input: URL, output: URL, repoRoot: URL, top: Int)
  case compare(baseline: URL, current: URL, output: URL, repoRoot: URL, top: Int)
}

@main
struct CompileTimeProfileTool {
  static func main() {
    do {
      let command = try parse(arguments: Array(CommandLine.arguments.dropFirst()))
      switch command {
      case .normalize(let input, let output, let repoRoot, let top):
        let profiler = CompileTimeProfiler(repoRoot: repoRoot, topCount: top)
        let snapshot = try profiler.normalizeFile(input: input, output: output)
        FileHandle.standardOutput.write(Data((CompileTimeProfiler.render(snapshot: snapshot) + "\n").utf8))
      case .compare(let baseline, let current, let output, let repoRoot, let top):
        let profiler = CompileTimeProfiler(repoRoot: repoRoot, topCount: top)
        let comparison = try profiler.compareFiles(baseline: baseline, current: current, output: output)
        FileHandle.standardOutput.write(Data((CompileTimeProfiler.render(comparison: comparison) + "\n").utf8))
      }
    } catch let error as CompileTimeProfileError {
      FileHandle.standardError.write(Data((message(for: error) + "\n").utf8))
      Darwin.exit(exitCode(for: error))
    } catch {
      FileHandle.standardError.write(Data(("error: \(error.localizedDescription)\n").utf8))
      Darwin.exit(1)
    }
  }

  static func parse(arguments: [String]) throws -> Command {
    guard let command = arguments.first else {
      throw CompileTimeProfileError.invalidUsage(usage)
    }

    switch command {
    case "normalize":
      let values = try parseFlags(arguments: Array(arguments.dropFirst()))
      return .normalize(
        input: try requiredURL(flag: "--input", values: values),
        output: try requiredURL(flag: "--output", values: values),
        repoRoot: try requiredURL(flag: "--repo-root", values: values),
        top: int(flag: "--top", values: values) ?? 10
      )
    case "compare":
      let values = try parseFlags(arguments: Array(arguments.dropFirst()))
      return .compare(
        baseline: try requiredURL(flag: "--baseline", values: values),
        current: try requiredURL(flag: "--current", values: values),
        output: try requiredURL(flag: "--output", values: values),
        repoRoot: try requiredURL(flag: "--repo-root", values: values),
        top: int(flag: "--top", values: values) ?? 10
      )
    case "-h", "--help":
      throw CompileTimeProfileError.invalidUsage(usage)
    default:
      throw CompileTimeProfileError.invalidUsage(usage)
    }
  }

  static func parseFlags(arguments: [String]) throws -> [String: String] {
    var iterator = arguments.makeIterator()
    var values: [String: String] = [:]

    while let flag = iterator.next() {
      guard flag.hasPrefix("--") else {
        throw CompileTimeProfileError.invalidUsage(usage)
      }
      guard let value = iterator.next(), value.hasPrefix("--") == false else {
        throw CompileTimeProfileError.invalidUsage(usage)
      }
      values[flag] = value
    }

    return values
  }

  static func requiredURL(flag: String, values: [String: String]) throws -> URL {
    guard let value = values[flag] else {
      throw CompileTimeProfileError.invalidUsage(usage)
    }
    return URL(fileURLWithPath: value)
  }

  static func int(flag: String, values: [String: String]) -> Int? {
    guard let value = values[flag] else {
      return nil
    }
    return Int(value)
  }

  static func message(for error: CompileTimeProfileError) -> String {
    switch error {
    case .invalidUsage(let message):
      return message
    case .unreadableInput(let path):
      return "error: could not read \(path)"
    case .missingBuildTimingSummary:
      return "error: build timing summary was not found in the raw log"
    case .serializationFailed:
      return "error: failed to serialize output"
    }
  }

  static func exitCode(for error: CompileTimeProfileError) -> Int32 {
    switch error {
    case .invalidUsage:
      return 2
    case .unreadableInput, .missingBuildTimingSummary, .serializationFailed:
      return 1
    }
  }

  static let usage = """
    usage:
      compile-time-profile normalize --input <raw-log> --output <snapshot-json> --repo-root <repo-root> [--top <count>]
      compile-time-profile compare --baseline <baseline-json> --current <snapshot-json> --output <comparison-json> --repo-root <repo-root> [--top <count>]
    """
}
