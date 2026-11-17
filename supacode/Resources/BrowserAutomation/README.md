# Browser automation scripts

`playwright-injected.js` is the in-page script of `playwright-core` 1.60.0, unmodified. It is licensed
under Apache-2.0. See `LICENSE` and `NOTICE`.

- Source: the `injectedScriptSource` string literal in `lib/coreBundle.js` of the npm tarball.
- Tarball integrity: `sha512-9bW6zvX/m0lEbgTKJ6YppOKx8H3VOPBMOCFh2irXFOT4BbHgrx5hPjwJYLT40Lu+4qtD36qKc/Hn56StUW57IA==`
- File SHA-256: `7000b1119dc91aabdb4a19b0ebf9d3e1f02cdb59153cff8c3cdc690e503e944a`

`driver.js` is ours. It turns the engine's snapshot, selector, and element-state functions into the
commands the app sends to a page.
