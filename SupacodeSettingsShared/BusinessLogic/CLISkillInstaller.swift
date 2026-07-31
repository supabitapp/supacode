import Foundation

private nonisolated let skillInstallerLogger = SupaLogger("Settings")

/// Installs the generated agent skills (`supacode-cli` and `supacode-deeplinks`)
/// into a coding agent's config directory. Both skills install, update, and
/// uninstall together as one component.
nonisolated struct CLISkillInstaller {
  let homeDirectoryURL: URL

  init(homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser) {
    self.homeDirectoryURL = homeDirectoryURL
  }

  // MARK: - Planned files.

  /// One installable markdown file: destination plus its bundled content.
  private struct PlannedFile {
    let url: URL
    let content: () throws -> String
  }

  private func skillDir(for agent: SkillAgent, skillName: String) -> URL {
    homeDirectoryURL
      .appending(path: "\(agent.configDirectoryName)/skills/\(skillName)", directoryHint: .isDirectory)
  }

  private func plannedFiles(for agent: SkillAgent) -> [PlannedFile] {
    let cliDir = skillDir(for: agent, skillName: CLISkillContent.cliSkillName)
    let deeplinksDir = skillDir(for: agent, skillName: CLISkillContent.deeplinksSkillName)
    return [
      PlannedFile(url: cliDir.appending(path: "SKILL.md", directoryHint: .notDirectory)) {
        try CLISkillContent.cliSkill()
      },
      PlannedFile(url: deeplinksDir.appending(path: "SKILL.md", directoryHint: .notDirectory)) {
        try CLISkillContent.deeplinksSkill()
      },
    ]
  }

  // MARK: - Check.

  private enum OnDiskFile {
    case missing
    case unreadable
    case content(String)

    var isMissing: Bool {
      if case .missing = self { return true }
      return false
    }
  }

  private static func onDiskFile(at url: URL) -> OnDiskFile {
    do {
      return .content(try String(contentsOf: url, encoding: .utf8))
    } catch {
      let path = url.path(percentEncoded: false)
      guard FileManager.default.fileExists(atPath: path) else { return .missing }
      skillInstallerLogger.error("Skill file at \(path) exists but is unreadable: \(error)")
      return .unreadable
    }
  }

  func installState(_ agent: SkillAgent) -> ComponentInstallState {
    let files = plannedFiles(for: agent)
    let onDisk = files.map { Self.onDiskFile(at: $0.url) }
    if onDisk.allSatisfy(\.isMissing) { return .notInstalled }
    let upToDate = zip(files, onDisk).allSatisfy { file, disk in
      guard case .content(let disk) = disk else { return false }
      guard let expected = try? file.content() else {
        // Never silent: a broken bundle would otherwise hide behind "Installed".
        skillInstallerLogger.error(
          "Bundled markdown unreadable for \(file.url.lastPathComponent); falling back to existence-only state.")
        return true
      }
      return disk == expected
    }
    return upToDate ? .installed : .outdated
  }

  // MARK: - Install.

  func install(_ agent: SkillAgent) throws {
    // Render everything up front so a missing bundled resource fails before any write.
    let rendered = try plannedFiles(for: agent).map { (url: $0.url, content: try $0.content()) }
    var written: [(url: URL, previous: Data?)] = []
    do {
      for file in rendered {
        let dir = file.url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let previous = try? Data(contentsOf: file.url)
        try file.content.write(to: file.url, atomically: true, encoding: .utf8)
        written.append((file.url, previous))
        guard agent == .codex else { continue }
        if let pruned = pruneLegacyAgentsMd(in: dir) {
          written.append(pruned)
        }
      }
    } catch {
      // Best-effort rollback so a partial write never masquerades as installed.
      for file in written.reversed() {
        if let previous = file.previous {
          try? previous.write(to: file.url)
        } else {
          try? FileManager.default.removeItem(at: file.url)
        }
      }
      throw error
    }
  }

  /// Removes the AGENTS.md sidecar older versions installed for Codex and
  /// returns its rollback entry so a failed install restores it.
  private func pruneLegacyAgentsMd(in dir: URL) -> (url: URL, previous: Data?)? {
    let legacyAgentsMd = dir.appending(path: "AGENTS.md", directoryHint: .notDirectory)
    let previous = try? Data(contentsOf: legacyAgentsMd)
    do {
      try FileManager.default.removeItem(at: legacyAgentsMd)
      return (legacyAgentsMd, previous)
    } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
      // Absent is the normal case.
      return nil
    } catch {
      skillInstallerLogger.error("Pruning legacy AGENTS.md failed: \(error)")
      return nil
    }
  }

  // MARK: - Uninstall.

  func uninstall(_ agent: SkillAgent) throws {
    for skillName in [CLISkillContent.cliSkillName, CLISkillContent.deeplinksSkillName] {
      do {
        try FileManager.default.removeItem(at: skillDir(for: agent, skillName: skillName))
      } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
        // Nothing to remove, including dangling symlinks a fileExists guard would miss.
      }
    }
  }
}
