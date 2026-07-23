// Prefix internal links with the configured base (GitHub Pages serves under
// /<repo>/). Use for every internal href so links work locally and deployed.
const BASE = import.meta.env.BASE_URL.replace(/\/$/, "");

export function withBase(path: string): string {
  if (/^(https?:)?\/\//.test(path) || path.startsWith("#")) return path;
  const clean = path.startsWith("/") ? path : `/${path}`;
  return `${BASE}${clean}` || "/";
}

// Build the URL for a docs slug ("" = overview root).
export function docsHref(slug: string): string {
  return withBase(slug ? `/docs/${slug}` : "/docs");
}
