struct WorktreeLoadingInfo: Hashable {
  let name: String
  let repositoryName: String?
  let kind: Kind

  // `.creating` is git-only — folder creation is rejected upstream
  // in the reducer. Archiving never surfaces here: it routes through
  // the terminal, so no `.archiving` case is needed.
  enum Kind: Hashable {
    case creating(Progress)
    case removing(isFolder: Bool)
  }

  struct Progress: Hashable {
    let statusTitle: String?
    let statusDetail: String?
    let statusCommand: String?
    let statusLines: [String]
  }

  var isFolder: Bool {
    kind == .removing(isFolder: true)
  }

  var progress: Progress? {
    if case .creating(let progress) = kind { progress } else { nil }
  }

  var actionLabel: String {
    switch kind {
    case .creating: "Creating"
    case .removing: "Removing"
    }
  }
}
