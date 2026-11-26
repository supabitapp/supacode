# Supacode website

This directory contains the landing page and the Cloudflare Pages Worker that
serves `/download/*` from this repository's GitHub Releases. The Worker also
serves `/.well-known/search`, which lets agents search the landing page by
section and get Markdown results. It accepts `GET ?q=` and `QUERY` requests
with a plain-text or JSON `{"q"}` body, and the page advertises it through
`agent:*` meta tags.
Install the Bun version in [`package.json`](package.json) and the Node version in
[`.node-version`](.node-version). Run from this directory:

```bash
bun install --frozen-lockfile --ignore-scripts
bun run dev    # http://localhost:3002
bun run check-types
bun run test
bun run build  # out/
```

To run the static export and the download Worker together, start a local Pages
preview after building:

```bash
bunx wrangler@4.164.0 pages dev out
```

The [website workflow](../../.github/workflows/website.yml) builds the export on
website changes. For deployments, set `CLOUDFLARE_ACCOUNT_ID` and
`CLOUDFLARE_API_TOKEN` in the `supacode-pages-preview` and
`supacode-pages-production` GitHub environments. Restrict the production
environment to `main` and confirm that `main` is the production branch of the
existing `supacode` Pages project. Set the repository variable
`SUPACODE_PAGES_PREVIEW_ENABLED` to `true` to deploy previews for PRs from this
repository. Set `SUPACODE_PAGES_PRODUCTION_ENABLED` to `true` to enable production
deploys. With that variable enabled, website changes on `main` deploy
automatically and dispatching the workflow from `main` deploys manually.
Pages deploy tokens have account-wide Pages access. Enable PR previews only
when everyone with write access to this repository is trusted to deploy the site.

On a preview deployment, request `/download/latest/appcast.xml` on the preview
host to exercise its Worker. The homepage's Download button points to
`supacode.sh`, and purchase links use the production license service.

If a production deployment fails its checks, disable
`SUPACODE_PAGES_PRODUCTION_ENABLED` and select the previous production
deployment in the [Cloudflare Pages deployment history](https://developers.cloudflare.com/pages/configuration/rollbacks/).
