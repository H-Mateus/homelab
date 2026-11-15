# Docs site

This repo's documentation as a browsable website: `docs/*.md`, the
architecture diagrams and every stack README, with a sidebar and search.
Tailnet-only, at `https://docs.<tailnet>.ts.net`.

## How it works

```
push to main ──► GitHub Actions: quarto render ──► docs-html branch (HTML only)
                                                        │  every 5 min
TrueNAS: docs-site-sync (git fetch) ──► html volume ──► nginx ──► tailscale serve
```

- **Source**: the Markdown stays where it is. `_quarto.yml` at the repo
  root lists what goes on the site; `index.qmd` pulls in the top-level
  README as the home page. The Markdown still reads normally on GitHub
  (```` ```mermaid ```` fences are turned into diagrams by
  `docs/_quarto/mermaid.lua`; the other filters there take page titles
  from the leading `# Heading` and point links to non-page files, like
  `main.tf`, at GitHub).
- **Build**: `.github/workflows/docs-site.yml` renders on every push to main
  that touches Markdown or the site config, and force-pushes `_site/` as a
  single orphan commit to `docs-html`. Pull requests get a render-only check.
- **Serve**: this stack. `docs-site-sync` shallow-fetches `docs-html` every
  `DOCS_SYNC_INTERVAL` seconds; nginx serves the result behind a userspace
  Tailscale sidecar.

The repo is public, so `docs-html` is public too. That's the same content
as the Markdown it's built from. **GitHub Pages stays off**: the site is
only *hosted* on the tailnet. `docs/private/` is gitignored, so it never
reaches GitHub, CI or this box (CI also fails the build if it shows up).

Rendering in CI rather than on TrueNAS keeps this stack to two tiny images
(no ~1 GB Quarto/pandoc image or render job on the NAS) and doubles as a
check that the docs still build.

## Deploy

1. **Tailscale**: it's an admin-only page, so it uses the existing
   `tag:ts-apps` (no ACL change). Create a single-use, pre-approved,
   non-ephemeral auth key tagged `tag:ts-apps`.
2. **First build**: push to main (or run the *docs-site* workflow by hand
   from the Actions tab) so the `docs-html` branch exists. Check the repo's
   Settings → Pages is still *disabled*.
3. **Dockhand**: add the stack pointed at this directory, fill `.env` from
   `.env.example`, deploy. `docker logs docs-site-sync` should print
   `docs-site: now serving <sha>` within a few seconds.
4. Open `https://docs.<tailnet>.ts.net`.

## Day to day

- **Adding a page**: new `docs/*.md` files are picked up by the render glob,
  but add them to a sidebar section in `_quarto.yml` so they're easy to
  find. **New stack READMEs must be added to `project.render` by name**:
  Quarto skips `README.md` in globs. CI's render-list check fails until
  you do.
- **Preview locally**: `quarto preview` from the repo root.
- **Force a refresh**: `docker restart docs-site-sync`.
- **Upgrades**: Renovate bumps the image tags in `docker-compose.yml` and the
  Quarto version in the workflow.
