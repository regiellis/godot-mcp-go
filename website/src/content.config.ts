import { defineCollection, z } from "astro:content";
import { glob } from "astro/loaders";

// Authored docs pages.
const docs = defineCollection({
  loader: glob({ pattern: "**/*.{md,mdx}", base: "./src/content/docs" }),
  schema: z.object({
    title: z.string(),
    description: z.string().optional(),
    tableOfContents: z.boolean().default(true),
  }),
});

// The craft references, rendered straight from the skill so they stay the single
// source of truth. They carry no frontmatter; title and description come from
// src/config.ts (GUIDES). SKILL.md is the hub and is excluded.
const guides = defineCollection({
  loader: glob({ pattern: ["*.md", "!SKILL.md"], base: "../skills/godot-mcp" }),
  schema: z.object({}).passthrough(),
});

export const collections = { docs, guides };
