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

  func installState(_ agent: SkillAgent) throws -> ComponentInstallState {
    let files = plannedFiles(for: agent)
    // Throws when a file exists but can't be read, so a denied read is never
    // reported as a missing skill.
    let onDisk = try files.map { try AgentFileProbe.text(at: $0.url) }
    if onDisk.allSatisfy({ $0 == nil }) { return .notInstalled }
    // A bundled resource we can't read leaves the state undeterminable, same as
    // an unreadable file on disk. `install` throws on it too.
    let upToDate = try zip(files, onDisk).allSatisfy { file, disk in
      guard let disk else { return false }
      return try disk == file.content()
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
