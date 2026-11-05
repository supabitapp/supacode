import Foundation
import SupacodeSettingsShared
import Testing

@testable import supacode

struct ProgramStatusReportTests {
  private typealias Limits = ProgramStatusReport.Limits

  private func base64(_ text: String) -> String {
    Data(text.utf8).base64EncodedString()
  }

  // MARK: - Whole reports.

  @Test func parsesEveryKeyOfABlockedReport() {
    let body =
      "state=blocked:id=deploy/us-east:kind=permission:progress=40:app=claude-code"
      + ":title=\(base64("Deploy")):msg=\(base64("Approve the write?"))"

    let report = ProgramStatusReport.parse(body: body)

    #expect(
      report
        == ProgramStatusReport(
          state: .blocked,
          id: "deploy/us-east",
          kind: .permission,
          progress: 40,
          app: "claude-code",
          title: "Deploy",
          message: "Approve the write?"
        )
    )
    #expect(report?.isRoot == false)
    #expect(report?.agent == .claude)
  }

  @Test func bareStateIsARootReportWithNothingElse() {
    let report = ProgramStatusReport.parse(body: "state=idle")

    #expect(report == ProgramStatusReport(state: .idle))
    #expect(report?.isRoot == true)
    #expect(report?.agent == nil)
  }

  @Test(arguments: ProgramStatusReport.State.allCases)
  func parsesEveryState(_ state: ProgramStatusReport.State) {
    #expect(ProgramStatusReport.parse(body: "state=\(state.rawValue)")?.state == state)
  }

  @Test func codexStyleReportParses() {
    let report = ProgramStatusReport.parse(body: "state=working:app=codex")

    #expect(report?.state == .working)
    #expect(report?.agent == .codex)
    #expect(report?.progress == nil)
  }

  @Test func clearWithAnIDAddressesThatRecord() {
    let report = ProgramStatusReport.parse(body: "state=clear:id=agent/sub")

    #expect(report?.state == .clear)
    #expect(report?.id == "agent/sub")
    #expect(report?.isRoot == false)
  }

  // MARK: - Discarded reports.

  @Test func supportQueryIsNotAReport() {
    #expect(ProgramStatusReport.parse(body: "?") == nil)
  }

  @Test(arguments: ["", "app=codex", "state=", "state=sleeping", "state=IDLE", "state=idle,working"])
  func missingOrUnknownStateDiscardsTheReport(_ body: String) {
    #expect(ProgramStatusReport.parse(body: body) == nil)
  }

  @Test func unknownStateIsNeverGuessedEvenAfterAKnownOne() {
    // Last value wins, and the last one is unknown.
    #expect(ProgramStatusReport.parse(body: "state=idle:state=paused") == nil)
  }

  @Test func bodyOverTheSequenceLimitIsDiscarded() {
    let filler = String(repeating: "a", count: Limits.maxBodyBytes)
    #expect(ProgramStatusReport.parse(body: "state=idle:x=" + filler) == nil)
  }

  @Test func bodyAtTheSequenceLimitParses() {
    let prefix = "state=idle:x="
    let filler = String(repeating: "a", count: Limits.maxBodyBytes - prefix.utf8.count)
    #expect(ProgramStatusReport.parse(body: prefix + filler)?.state == .idle)
  }

  @Test func overlongKeyDiscardsTheReportEvenWhenUnknown() {
    let key = String(repeating: "k", count: Limits.maxKeyBytes + 1)
    #expect(ProgramStatusReport.parse(body: "state=idle:\(key)=1") == nil)
    let fits = String(repeating: "k", count: Limits.maxKeyBytes)
    #expect(ProgramStatusReport.parse(body: "state=idle:\(fits)=1")?.state == .idle)
  }

  // MARK: - Forgiving pair handling.

  @Test func malformedAndUnknownPairsAreSkipped() {
    #expect(ProgramStatusReport.parse(body: "state=idle:future=yes:oops") == ProgramStatusReport(state: .idle))
  }

  @Test func lastValueWins() {
    let report = ProgramStatusReport.parse(body: "state=working:app=codex:state=blocked:app=pi:kind=auth")

    #expect(report?.state == .blocked)
    #expect(report?.app == "pi")
    #expect(report?.kind == .auth)
  }

  @Test func keysAndValuesAreTrimmed() {
    let report = ProgramStatusReport.parse(body: " state = working : app =\tcodex ")

    #expect(report?.state == .working)
    #expect(report?.app == "codex")
  }

  @Test func prefixOfAKeyDoesNotMatchIt() {
    #expect(ProgramStatusReport.parse(body: "state=idle:application=codex")?.app == nil)
  }

  // MARK: - id.

  @Test(arguments: ["a", "deploy/us-east", "a.b/c_d/e-f/g+h", "1/2/3/4/5/6/7/8"])
  func validIDsParse(_ id: String) {
    #expect(ProgramStatusReport.parse(body: "state=working:id=\(id)")?.id == id)
  }

  @Test(arguments: ["/a", "a/", "a//b", "a,b", "a=b", "a@b", "a%20b", "a/b/c/d/e/f/g/h/i", "a*b"])
  func malformedIDDiscardsTheReport(_ id: String) {
    // Falling back to the root would let `state=clear` remove every record.
    #expect(ProgramStatusReport.parse(body: "state=clear:id=\(id)") == nil)
  }

  @Test func malformedIDIsNeverReplacedByALaterValidOne() {
    #expect(ProgramStatusReport.parse(body: "state=clear:id=a@b:id=a") == nil)
  }

  @Test func emptyIDIsMalformed() {
    #expect(ProgramStatusReport.parse(body: "state=clear:id=") == nil)
  }

  @Test func idLimits() {
    let segment = String(repeating: "s", count: Limits.maxIDSegmentBytes)
    #expect(ProgramStatusReport.parse(body: "state=idle:id=\(segment)")?.id == segment)
    #expect(ProgramStatusReport.parse(body: "state=idle:id=\(segment)s") == nil)

    let longest = [segment, segment, segment, String(repeating: "s", count: 29)].joined(separator: "/")
    #expect(longest.utf8.count == Limits.maxIDBytes)
    #expect(ProgramStatusReport.parse(body: "state=idle:id=\(longest)")?.id == longest)
    #expect(ProgramStatusReport.parse(body: "state=idle:id=\(longest)/s") == nil)
  }

  @Test func isValidIDMatchesTheGrammar() {
    #expect(ProgramStatusReport.isValidID("root/child"))
    #expect(!ProgramStatusReport.isValidID(""))
    #expect(!ProgramStatusReport.isValidID("root/"))
    #expect(!ProgramStatusReport.isValidID("ro ot"))
  }

  // MARK: - app.

  @Test(arguments: [
    ("claude-code", SkillAgent.claude), ("codex", .codex), ("omp", .omp), ("opencode", .opencode), ("pi", .pi),
  ])
  func appNamesTheAgent(_ app: String, _ agent: SkillAgent) {
    #expect(ProgramStatusReport.parse(body: "state=idle:app=\(app)")?.agent == agent)
  }

  @Test func unknownAppIsKeptButNamesNoAgent() {
    let report = ProgramStatusReport.parse(body: "state=working:app=cargo")

    #expect(report?.app == "cargo")
    #expect(report?.agent == nil)
  }

  @Test(arguments: ["a,b", "a/b", "a=b"])
  func appOutsideTheNameCharacterSetIsAbsent(_ app: String) {
    let report = ProgramStatusReport.parse(body: "state=idle:app=\(app)")

    #expect(report?.state == .idle)
    #expect(report?.app == nil)
  }

  @Test func appLimitAppliesEvenToAValueWithADisallowedByte() {
    let longest = String(repeating: "a", count: Limits.maxAppBytes)
    #expect(ProgramStatusReport.parse(body: "state=idle:app=\(longest)")?.app == longest)
    #expect(ProgramStatusReport.parse(body: "state=idle:app=\(longest)a") == nil)
    #expect(ProgramStatusReport.parse(body: "state=idle:app=@\(longest)") == nil)
  }

  // MARK: - kind and progress.

  @Test(arguments: ProgramStatusReport.Kind.allCases)
  func blockedReadsEveryKind(_ kind: ProgramStatusReport.Kind) {
    #expect(ProgramStatusReport.parse(body: "state=blocked:kind=\(kind.rawValue)")?.kind == kind)
  }

  @Test func unknownKindReadsAsNil() {
    let report = ProgramStatusReport.parse(body: "state=blocked:kind=coffee")

    #expect(report?.state == .blocked)
    #expect(report?.kind == nil)
  }

  @Test(arguments: [ProgramStatusReport.State.idle, .working, .done, .error, .clear])
  func kindIsOnlyReadWhenBlocked(_ state: ProgramStatusReport.State) {
    #expect(ProgramStatusReport.parse(body: "state=\(state.rawValue):kind=permission")?.kind == nil)
  }

  @Test(arguments: [("0", 0), ("40", 40), ("100", 100), ("007", 7)])
  func progressReadsWholeNumbersUpToAHundred(_ raw: String, _ expected: Int) {
    #expect(ProgramStatusReport.parse(body: "state=working:progress=\(raw)")?.progress == expected)
    #expect(ProgramStatusReport.parse(body: "state=blocked:progress=\(raw)")?.progress == expected)
  }

  @Test(arguments: ["101", "-1", "+5", "4_0", "4.5", "", "1e2", "99999999999999999999"])
  func malformedProgressIsIndeterminate(_ raw: String) {
    let report = ProgramStatusReport.parse(body: "state=working:progress=\(raw)")

    #expect(report?.state == .working)
    #expect(report?.progress == nil)
  }

  @Test(arguments: [ProgramStatusReport.State.idle, .done, .error, .clear])
  func progressIsOnlyReadWhenWorkingOrBlocked(_ state: ProgramStatusReport.State) {
    #expect(ProgramStatusReport.parse(body: "state=\(state.rawValue):progress=50")?.progress == nil)
  }

  // MARK: - title and msg.

  @Test func textDecodesUnicode() {
    let body = "state=done:title=\(base64("安全な☀️")):msg=\(base64("Fertig ✓"))"
    let report = ProgramStatusReport.parse(body: body)

    #expect(report?.title == "安全な☀️")
    #expect(report?.message == "Fertig ✓")
  }

  @Test func paddingIsOptional() {
    // "ab" encodes to "YWI=".
    #expect(ProgramStatusReport.parse(body: "state=done:msg=YWI")?.message == "ab")
    #expect(ProgramStatusReport.parse(body: "state=done:msg=YWI=")?.message == "ab")
  }

  @Test func emptyTextIsAbsent() {
    let report = ProgramStatusReport.parse(body: "state=done:title=:msg=")

    #expect(report?.state == .done)
    #expect(report?.title == nil)
    #expect(report?.message == nil)
  }

  @Test(arguments: ["A===", "Y", "YW=I", "QQ="])
  func invalidBase64DiscardsTheReport(_ encoded: String) {
    #expect(ProgramStatusReport.parse(body: "state=done:msg=\(encoded)") == nil)
    #expect(ProgramStatusReport.parse(body: "state=done:title=\(encoded)") == nil)
  }

  @Test(arguments: ["line\nbreak", "\u{07}bell", "\u{1B}]9;osc\u{1B}\\", "del\u{7F}", "c1\u{85}"])
  func textWithAControlCharacterDiscardsTheReport(_ text: String) {
    #expect(ProgramStatusReport.parse(body: "state=done:msg=\(base64(text))") == nil)
  }

  @Test func textThatIsNotUTF8DiscardsTheReport() {
    let invalid = Data([0xFF, 0xFE, 0xFD]).base64EncodedString()
    #expect(ProgramStatusReport.parse(body: "state=done:msg=\(invalid)") == nil)
  }

  @Test func titleLimits() {
    let longest = String(repeating: "t", count: Limits.maxTitleBytes)
    #expect(ProgramStatusReport.parse(body: "state=done:title=\(base64(longest))")?.title == longest)
    #expect(ProgramStatusReport.parse(body: "state=done:title=\(base64(longest + "t"))") == nil)
  }

  @Test func messageLimits() {
    let longest = String(repeating: "m", count: Limits.maxMessageBytes)
    #expect(base64(longest).utf8.count <= Limits.maxMessageEncodedBytes)
    #expect(ProgramStatusReport.parse(body: "state=done:msg=\(base64(longest))")?.message == longest)
    #expect(ProgramStatusReport.parse(body: "state=done:msg=\(base64(longest + "mmm"))") == nil)
  }

  @Test func overlongTextIsCheckedEvenWhenALaterPairReplacesIt() {
    let tooLong = String(repeating: "A", count: Limits.maxTitleEncodedBytes + 4)
    #expect(ProgramStatusReport.parse(body: "state=done:title=\(tooLong):title=\(base64("ok"))") == nil)
  }

  @Test func textWithADisallowedByteIsSkipped() {
    let report = ProgramStatusReport.parse(body: "state=done:msg=!!!!")

    #expect(report?.state == .done)
    #expect(report?.message == nil)
  }

  @Test func onlyTheLastTextIsDecoded() {
    // An earlier invalid value within the limits is replaced, not decoded.
    #expect(ProgramStatusReport.parse(body: "state=done:msg=A===:msg=\(base64("ok"))")?.message == "ok")
  }
}

struct SkillAgentProgramStatusTests {
  @Test(arguments: SkillAgent.allCases)
  func programStatusAppRoundTrips(_ agent: SkillAgent) {
    guard let app = agent.programStatusApp else { return }
    #expect(SkillAgent(programStatusApp: app) == agent)
  }

  @Test func onlyTheAgentsThatReportOverOSC7501HaveAnApp() {
    let reporting = SkillAgent.allCases.filter { $0.programStatusApp != nil }
    #expect(Set(reporting) == [.claude, .codex, .omp, .opencode, .pi])
  }

  @Test(arguments: ["", "claude", "Claude-Code", "cargo", "codex "])
  func unknownAppNamesNoAgent(_ app: String) {
    #expect(SkillAgent(programStatusApp: app) == nil)
  }
}
