# Contributing to Supacode

Thanks for your interest in Supacode. This project is reviewed personally, line by line,
and the bar for merging is high. A clear issue is worth more than a large pull request, so
the process below front-loads the conversation before any code is written.

By taking part you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## The short version

1. **Open an issue first.** Bugs and features both start as an issue. Blank issues are
   disabled, so pick the bug or feature form.
2. **Wait for `ready`.** Bug reports are marked `ready` automatically. Feature requests are
   marked `ready` by a maintainer once the direction is agreed. Do not open a feature pull
   request before then.
3. **Open a focused pull request** that links the issue with `Closes #<number>`.
4. **You sign your work.** Using AI tools is welcome, and you can disclose them in the pull
   request. An AI agent just cannot be the author or co-author of a commit: a human is
   accountable for every line.

Contributors with write access to the repository are exempt from the automated checks below.

## Reporting a bug

Use the **Bug report** form. It asks for the Supacode version and build, your macOS version,
your locale, and a reliable set of reproduction steps. Those details are what make a bug
fixable, so please fill them in. A bug is `ready` the moment it is filed, which means you can
open a fix straight away and link it with `Closes #<number>`.

## Requesting a feature

Use the **Feature request** form and describe the problem you are trying to solve, not just
the solution you have in mind. Feature requests are discussed before code is written. A
maintainer adds the `ready` label once the feature is approved.

**Please do not open a feature pull request until the issue is `ready`.** A pull request
linked to a feature that is not yet `ready` is moved to draft and labeled `invalid` until the
label is added. Once the feature is `ready`, mark your pull request ready for review and the
check clears.

## Opening a pull request

Every pull request must be linked to a single issue. Keep the `Closes #<number>` line in the
description. A status check enforces the policy below (write-access contributors are exempt).
When it fails, the pull request is moved to draft, labeled `invalid`, and a comment lists every
reason. Fix the points, mark it ready for review, and the check clears. A pull request left
`invalid` and inactive is closed automatically after a few days; reopen it once fixed.

- **A linked issue is required.** Link a valid, open issue in this repository with
  `Closes #<number>`.
- **The issue must be `ready`.** For bugs this is automatic. For features a maintainer adds it
  after approval.
- **Assigned issues are reserved.** If the linked issue is assigned to someone, only that
  person may open the pull request. If they have stopped working on it, ask a maintainer to
  reassign the issue to you first.
- **You are the author.** No commit may be authored or co-authored by an AI agent. Using AI
  tools is welcome; disclose them in the description instead.

Keep pull requests small and focused: one issue, one pull request. Before you push, run:

```bash
make check   # swift-format + swiftlint
make test    # the test suite
```

See the [README](README.md) and [AGENTS.md](AGENTS.md) for how to build and run the app,
including the Xcode 26.3 requirement on macOS 26.4+.

## AI tools and accountability

Supacode is built with AI assistance and you are welcome to use it too. The rule is about
accountability, not tooling:

- **A human is the author of record.** The person who opens the pull request is accountable
  for every line in it and should be able to explain and defend the change in review.
- **No AI agent as a git author or co-author.** Commits must not carry an AI agent in the
  `Author:` field or in a `Co-authored-by:` trailer. Accountability is to a human, and a
  co-author line names the agent as a contributor of record. Pull requests whose commits do
  this are moved to draft and labeled `invalid` automatically, with a comment explaining how to
  fix it (reset the commit author or drop the trailer, then mark ready for review).
- **Disclosure is welcome.** If you used AI tools, note the model and harness in the optional
  disclosure section of the pull request. Disclosing your tools keeps review honest; it is
  never held against you. Please disclose there rather than in a commit trailer.

## License

By contributing, you agree that your contributions are licensed under the same terms as the
project (see [LICENSE](LICENSE)).
