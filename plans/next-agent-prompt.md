# Next Agent Prompt (Short)

Please implement **Slice 1** of the Scratch Pad feature using this plan:

- `plans/scratchpad-implementation-plan.md`

Focus only on:
1. Foundation models (`ScratchPadScope`, `ScratchPadNote`, basic view mode/sync state)
2. `ScratchPadFeature` reducer skeleton + actions/state for tabs/scopes
3. `ScratchPadStorageClient` interface and initial persistence wiring
4. Unit tests for:
   - at least one tab always exists
   - blank untitled tab reuse
   - mode persistence behavior

Constraints:
- Keep changes modular under `supacode/Features/ScratchPad/*`
- Minimize edits outside integration touchpoints
- Use TCA `@ObservableState`
- Use `TestClock` for time-based tests
- Run `make build-app` before finishing

When done, provide:
- changed file list
- tests run + results
- next recommended slice
