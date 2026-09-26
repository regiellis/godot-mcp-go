# Swallowtail static website

The files in `site/` are the website. Edit them directly; publishing uploads that
folder to GitHub Pages. There is no build step, package install, Node requirement,
or framework runtime.

## Files to edit

| Path | Purpose |
| --- | --- |
| `site/index.html` | Homepage |
| `site/docs/<page>/index.html` | Documentation pages |
| `site/assets/*.css` | Shared, homepage, docs and code styles |
| `site/assets/*.js` | Small browser scripts and the search index |
| `site/assets/search-index.js` | Search entries with `url`, `title` and plain `text` |
| `site/docs/<page>/llm.txt` | Plain Markdown copied by the page's copy buttons |
| `site/llm.txt` | Directory of all plain-text documentation files |
| `site/brand/`, `site/reports/` | Branding and downloadable reports |
| `site/licenses/` | Licenses for bundled fonts and preserved code styles |

When changing a page, update its HTML, adjacent `llm.txt`, and entry in the search
index together. Copy for agents adds the page's source URL to the same text file.
Code-block copy buttons read the displayed code directly.

To add a page, copy a similar page directory, replace the title, description,
content and text file, then update navigation, pagination and search entries.
Shared navigation is ordinary HTML repeated across the docs pages; update those
copies together. Keep the existing element IDs and `data-scope-*` attributes when
reusing styled markup. The CSS files are plain CSS, including native nesting.

The root `CHANGELOG.md` and `skills/swallowtail/*.md` remain the canonical release
history and agent guides. Update their corresponding HTML, text files and search
entries when their published content changes. No generator synchronizes them.

## Preview and check

Any static HTTP server can serve `site/` at `/godot-mcp-go/`. An optional preview
server and read-only validator use Python's standard library only:

```sh
python website/serve.py
python website/check.py
```

Open `http://127.0.0.1:4321/godot-mcp-go/`. Use HTTP preview for search and clipboard
checks; opening an HTML file directly has browser module/clipboard restrictions.
Neither command produces the website or runs during deployment.

Keep internal URLs under `/godot-mcp-go/`; that is the current Pages base. Root
navigation, docs routes, search entries and asset URLs need to change together if
the hosting base changes. Relative `llm.txt` links follow their containing page.

## Deployment

`.github/workflows/docs.yml` uploads `website/site` and deploys it to Pages.
Only published files live in that folder. Preview/check scripts, design references
and maintenance instructions live outside it. Framework source from before this
conversion remains available in Git history.
