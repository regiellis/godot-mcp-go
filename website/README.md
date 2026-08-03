# godot-mcp docs site

The public documentation site, deployed to GitHub Pages by `.github/workflows/docs.yml`
on every push to `main`. Plain **Astro** with MDX, Expressive Code, and Pagefind search.

## Running it

```sh
pnpm install
pnpm dev      # local preview
pnpm build    # production build into dist/
```

Search is generated post-build from `dist/`, so it only works in dev after one `pnpm build`.

## Where things live

| Path | What it holds |
| --- | --- |
| `src/config.ts` | Site metadata, the sidebar, and the craft-guide list |
| `src/content/docs/` | Authored pages (`.mdx` for callouts and cards, `.md` otherwise) |
| `src/components/` | The shell: topbar, sidebar, TOC, callouts, cards, code frames |
| `src/styles/theme.css` | Design tokens; light and dark switch on `:root[data-theme]` |
| `public/brand/` | The master mark; raster copies come from `tools/render-mark.mjs` |

The craft guides are not authored here. They are glob-imported from `skills/godot-mcp/*.md`
at the repo root and keyed by the `GUIDES` list in `src/config.ts`, so the published pages
and the shipped agent skill can never drift apart. To add one, write the Markdown there and
add its entry here.

Adding a docs page: create `src/content/docs/<slug>.mdx` with `title` and `description`
frontmatter, then list it in a `SIDEBAR` group in `src/config.ts`.

## Links

Author internal links root-absolute (`/docs/quickstart`). A rehype plugin prefixes them with
the Pages `base` at build time, so never hard-code the repo path.
