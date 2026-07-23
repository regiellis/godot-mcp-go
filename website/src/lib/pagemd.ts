// Turn a page's raw MD/MDX body into clean Markdown for the copy-page buttons.
// Guides are already plain Markdown; authored pages are MDX, so flatten the few
// components we use (Callout, Card, CardGrid) and drop import/JSX lines.

import { SITE } from "../config";

export function cleanBody(body: string): string {
  let s = body;

  // Drop import lines and bare JSX expression/map lines (the guides index).
  s = s
    .split("\n")
    .filter((line) => !/^\s*import\s/.test(line))
    .filter((line) => !/^\s*\{[A-Z0-9_]+\.(map|filter)\(/.test(line))
    .filter((line) => !/^\s*<\/?section>\s*$/.test(line))
    .join("\n");

  // Flatten each callout to a proper labelled blockquote (title + body).
  s = s.replace(/<Callout\b([^>]*)>([\s\S]*?)<\/Callout>/g, (_m, attrs, inner) => {
    const title = (attrs.match(/title="([^"]*)"/) || [])[1];
    const type = (attrs.match(/type="([^"]*)"/) || [])[1] || "note";
    const label = title || cap(type);
    const bodyLines = inner.trim().split("\n").map((l) => `> ${l.trim()}`.trimEnd());
    return `\n> **${label}**\n>\n${bodyLines.join("\n")}\n`;
  });

  // Flatten cards to a list.
  s = s.replace(/<Card[^>]*\btitle="([^"]*)"[^>]*>/g, "- **$1**: ");
  s = s.replace(/<\/?CardGrid>/g, "");
  s = s.replace(/<\/Card>/g, "");

  // Collapse runs of blank lines.
  s = s.replace(/\n{3,}/g, "\n\n");
  return s.trim();
}

function cap(s: string): string {
  return s.charAt(0).toUpperCase() + s.slice(1);
}

export function humanMarkdown(title: string, description: string | undefined, body: string): string {
  const head = description ? `# ${title}\n\n${description}\n` : `# ${title}\n`;
  return `${head}\n${cleanBody(body)}\n`;
}

export function agentMarkdown(
  title: string,
  description: string | undefined,
  body: string,
  url: string,
): string {
  const preamble =
    `The following is documentation for ${SITE.name}. It is a Go CLI and GDScript ` +
    `editor addon that drive a running Godot 4.7 editor over WebSocket (312 commands ` +
    `across 49 groups), for building and playtesting games.\n\n` +
    `Page: ${title}\nSource: ${url}\n\n---\n\n`;
  return preamble + humanMarkdown(title, description, body);
}
