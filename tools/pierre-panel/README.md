# Pierre Panel Asset Build

Build the panel assets from this directory:

```bash
bun install
bun run build
```

This writes:

- `supacode/Resources/PierrePanel/index.html`
- `supacode/Resources/PierrePanel/panel.css`
- `supacode/Resources/PierrePanel/panel.js`

To update Pierre, change `@pierre/diffs` in `package.json`, run the build again, and commit updated files in both `tools/pierre-panel/` and `supacode/Resources/PierrePanel/`.
