# Pierre Panel Asset Build

Build the panel assets from this directory:

```bash
bun install
bun run build
```

This writes:

- `Resources/PierrePanel/index.html`
- `Resources/PierrePanel/panel.css`
- `Resources/PierrePanel/panel.js`

To update Pierre, change `@pierre/diffs` in `package.json`, run the build again, and commit updated files in both `tools/pierre-panel/` and `Resources/PierrePanel/`.
