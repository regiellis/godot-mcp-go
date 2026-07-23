// @ts-check
import { defineConfig } from "astro/config";
import mdx from "@astrojs/mdx";
import expressiveCode from "astro-expressive-code";
import pagefind from "astro-pagefind";
import rehypeSlug from "rehype-slug";
import rehypeAutolinkHeadings from "rehype-autolink-headings";

// GitHub Pages project site. If the repo lands as something other than
// "godot-mcp-go", change `base` to match (or drop it for a custom domain).
const site = "https://regiellis.github.io";
const base = "/godot-mcp-go";
const basePrefix = base.replace(/\/$/, "");

// Prefix root-absolute hrefs/srcs in Markdown/MDX with the Pages base, so an
// author can write [Quickstart](/docs/quickstart) and it still resolves when
// the site is served under /<repo>/. Skips external, protocol-relative, and
// already-prefixed links. Walks hast without a helper dep.
// Drop the first top-level H1 from content. The layout renders the page title
// as its own heading, so a leading H1 in the body would duplicate it. Authored
// docs carry no body H1, so this only trims the craft docs' own title line.
function remarkStripFirstH1() {
  return (tree) => {
    const i = tree.children.findIndex((n) => n.type === "heading" && n.depth === 1);
    if (i !== -1) tree.children.splice(i, 1);
  };
}

function rehypeBaseLinks() {
  const fix = (node) => {
    if (node.type === "element") {
      const p = node.properties ?? {};
      for (const attr of ["href", "src"]) {
        const v = p[attr];
        if (
          typeof v === "string" &&
          v.startsWith("/") &&
          !v.startsWith("//") &&
          !v.startsWith(basePrefix + "/")
        ) {
          p[attr] = basePrefix + v;
        }
      }
    }
    if (Array.isArray(node.children)) node.children.forEach(fix);
  };
  return (tree) => fix(tree);
}

export default defineConfig({
  site,
  base,
  trailingSlash: "ignore",
  // Expressive Code options live in ec.config.mjs (required for the <Code> component).
  // pagefind indexes the built HTML after `astro build` and serves the index in dev
  // (after at least one build has produced dist/pagefind).
  integrations: [expressiveCode(), mdx(), pagefind()],
  markdown: {
    remarkPlugins: [remarkStripFirstH1],
    rehypePlugins: [
      rehypeSlug,
      [
        rehypeAutolinkHeadings,
        {
          behavior: "append",
          // dataPagefindIgnore keeps the "#" anchor text out of the search index
          // (it was polluting result excerpts and sub-result titles).
          properties: { className: ["heading-anchor"], ariaHidden: true, tabIndex: -1, dataPagefindIgnore: "all" },
          content: { type: "text", value: "#" },
        },
      ],
      rehypeBaseLinks,
    ],
  },
});
