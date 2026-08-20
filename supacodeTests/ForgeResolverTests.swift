import SupacodeSettingsShared
import Testing

@testable import supacode

struct ForgeResolverTests {
  private let github = ForgeResolver.Candidate(
    id: .github,
    authenticatedHosts: ["github.com", "github.acme.com"],
    knownHostSubstrings: ["github"]
  )
  private let gitlab = ForgeResolver.Candidate(
    id: ForgeID(rawValue: "gitlab"),
    authenticatedHosts: ["gitlab.com", "git.acme.com"],
    knownHostSubstrings: ["gitlab"]
  )

  @Test func overrideWinsOverEverything() {
    let resolved = ForgeResolver.resolve(
      host: "github.com",
      override: "gitlab",
      candidates: [github, gitlab]
    )
    #expect(resolved == ForgeID(rawValue: "gitlab"))
  }

  @Test func noneOverrideDisablesResolution() {
    let resolved = ForgeResolver.resolve(
      host: "github.com",
      override: ForgeResolver.noneSettingsID,
      candidates: [github, gitlab]
    )
    #expect(resolved == nil)
  }

  @Test func unknownOverrideResolvesToNothing() {
    let resolved = ForgeResolver.resolve(
      host: "github.com",
      override: "bitbucket",
      candidates: [github, gitlab]
    )
    #expect(resolved == nil)
  }

  @Test func authenticatedHostMembershipBeatsSubstrings() {
    // A self-managed GitLab on a host with no identifying substring resolves
    // through the CLI's own authenticated-host set.
    let resolved = ForgeResolver.resolve(
      host: "git.acme.com",
      override: nil,
      candidates: [github, gitlab]
    )
    #expect(resolved == ForgeID(rawValue: "gitlab"))
  }

  @Test func knownHostSubstringIsTheFastPathFallback() {
    let resolved = ForgeResolver.resolve(
      host: "github.example.io",
      override: nil,
      candidates: [
        ForgeResolver.Candidate(id: .github, authenticatedHosts: [], knownHostSubstrings: ["github"]),
        gitlab,
      ]
    )
    #expect(resolved == .github)
  }

  @Test func hostsCompareCaseInsensitively() {
    let resolved = ForgeResolver.resolve(
      host: "GitHub.ACME.com",
      override: nil,
      candidates: [github, gitlab]
    )
    #expect(resolved == .github)
  }

  @Test func unknownHostNeverFallsBackToADefaultForge() {
    let resolved = ForgeResolver.resolve(
      host: "gerrit.internal.corp",
      override: nil,
      candidates: [
        ForgeResolver.Candidate(id: .github, authenticatedHosts: [], knownHostSubstrings: ["github"]),
        ForgeResolver.Candidate(
          id: ForgeID(rawValue: "gitlab"), authenticatedHosts: [], knownHostSubstrings: ["gitlab"]),
      ]
    )
    #expect(resolved == nil)
  }

  @Test func missingHostResolvesToNothing() {
    #expect(ForgeResolver.resolve(host: nil, override: nil, candidates: [github]) == nil)
    #expect(ForgeResolver.resolve(host: "", override: nil, candidates: [github]) == nil)
  }
}

struct ForgeCapabilitiesTests {
  @Test func githubVocabularyMatchesShippedStrings() {
    let vocabulary = ForgeVocabulary.github
    #expect(vocabulary.noun == "Pull Request")
    #expect(vocabulary.abbreviation == "PR")
    #expect(vocabulary.numberSigil == "#")
    #expect(vocabulary.ciNoun == "Checks")
    #expect(vocabulary.destinationName == "GitHub")
  }

  @Test func githubCapabilitiesOfferEveryMergeStrategy() {
    let capabilities = ForgeCapabilities.github
    #expect(capabilities.mergeStrategies == [.merge, .squash, .rebase])
    #expect(capabilities.canMarkReady)
    #expect(capabilities.canRerunChecks)
    #expect(capabilities.canCopyCIFailureLogs)
  }
}
