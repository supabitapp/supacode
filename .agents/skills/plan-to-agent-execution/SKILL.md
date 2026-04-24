---
name: plan-to-agent-execution
description: Converts any high-level implementation plan into an execution-ready, modular, rebase-safe workflow for coding agents, including fresh-context bootstraps, delivery slices, validation, and handoff artifacts.
---

# Plan to Agent Execution (Generic)

Use this skill whenever you already have a plan and want to execute it reliably across one or more fresh agent context windows.

## What this skill does

- Transforms a plan into concrete implementation slices.
- Defines minimal integration points to reduce merge conflicts.
- Creates a repeatable bootstrap for fresh context windows.
- Adds quality gates (build/tests/lint) and completion criteria.
- Produces a handoff summary that the next agent can continue from.

## Inputs expected

Before execution, capture these inputs in the first message of the run:

1. **Goal**: one-sentence outcome.
2. **Constraints**: architecture, style, performance, UX, deadline.
3. **Scope**: in/out of scope.
4. **Acceptance criteria**: testable bullets.
5. **Risk level**: low/medium/high.
6. **Integration surfaces**: files/modules likely touched.
7. **Rollout mode**: feature flag, staged, or immediate.

If any are missing, ask clarifying questions before coding.

## Planning normalization

Normalize any incoming plan into this structure:

1. **Architecture decision record (mini ADR)**
   - chosen approach
   - alternatives considered
   - why chosen
2. **Module map**
   - new modules/files
   - existing integration touchpoints
3. **Delivery slices** (small, independently reviewable)
4. **Validation matrix**
   - unit tests
   - integration tests
   - manual UX checks
5. **Risk/rollback**
   - likely failure modes
   - rollback path

## Slice design rules

For each slice:

- Keep diffs focused to one concern.
- Prefer additive changes over refactors.
- Keep public API stable when possible.
- Avoid broad formatting churn.
- Include tests for reducer/business logic changes.

Each slice should include:

- **Objective**
- **Files to add/edit**
- **Actions/commands to run**
- **Tests to add/update**
- **Definition of done**

## Fresh-context bootstrap (for every new agent window)

Run this checklist at the start of each new context window:

1. Confirm branch + clean state:

```bash
git branch --show-current
git status --short
```

2. Refresh repository map for current task:

```bash
rg -n "<feature terms>|<module names>|<integration points>" .
```

3. Re-read source-of-truth files for this slice.

4. Restate in 3-5 bullets:
   - current slice objective
   - exact acceptance criteria
   - files expected to change

5. Only then start edits.

## Branching and upstream sync

Use a dedicated branch per initiative (unless explicitly told otherwise):

```bash
git checkout -b feature/<short-name>
```

Sync often to reduce painful merges:

```bash
git fetch upstream
git rebase upstream/main
```

## Execution loop (repeat per slice)

1. Read files.
2. Implement minimal code changes.
3. Add/update tests.
4. Run fast local validation for touched areas.
5. Run full required validation gates.
6. Commit only relevant files with focused message.
7. Generate handoff note for next slice/context.

## Validation gates

Always run project-required gates before concluding a slice.

Generic template:

```bash
# format/lint if required
<format-command>
<lint-command>

# targeted tests first
<targeted-test-command>

# full build / full tests
<build-command>
<test-command>
```

If failures occur, include:
- failing command
- root cause
- fix applied
- re-run result

## Handoff artifact template

At the end of each slice, produce this handoff block:

1. **Completed**
   - bullet list of done items
2. **Changed files**
   - explicit paths
3. **Tests run**
   - commands + result
4. **Open risks / TODOs**
5. **Next slice recommendation**
6. **Exact next command to run**

## Final response footer requirement (required)

At the very end of the response, include a short paragraph (2-4 sentences max) for the next agent that explicitly states:

- where the short prompt is located (exact path)
- where the full plan is located (exact path)
- what slice/step to execute next

Use clear, copy-pastable paths.

## Commit strategy

- Commit small, coherent changes.
- One concern per commit.
- Do not stage unrelated files.
- Use descriptive messages:
  - `Add <feature> state and actions`
  - `Implement <behavior> with tests`
  - `Wire <module> into <integration point>`

## PR strategy

Prefer multiple small PRs over one large PR:

1. foundation/model
2. core behavior
3. integration
4. UX polish
5. hardening/tests

## Generic acceptance checklist

- [ ] Requirements mapped to implementation
- [ ] Edge cases handled
- [ ] Tests cover changed logic
- [ ] Build/lint/format/test gates pass
- [ ] Diff is modular and reviewable
- [ ] Handoff is sufficient for fresh context continuation

## Optional: plan manifest format

When helpful, keep a `PLAN_MANIFEST.md` in the branch root for continuity across contexts:

- Goal
- Slices with status (`todo / in-progress / done`)
- Decisions log
- Risk log
- Latest validation results
- Next action
