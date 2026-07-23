import { defineEcConfig } from "astro-expressive-code";

// Expressive Code lives here (not inline in astro.config) so the <Code>
// component can use the same options, including the themeCssSelector function.
export default defineEcConfig({
  themes: ["github-dark", "github-light"],
  themeCssSelector: (theme) => `[data-theme="${theme.type}"]`,
  useDarkModeMediaQuery: false,
  styleOverrides: {
    borderRadius: "10px",
    borderColor: "var(--border)",
    codeFontFamily: "var(--font-mono)",
    uiFontFamily: "var(--font-sans)",
    frames: {
      shadowColor: "transparent",
      editorTabBarBackground: "var(--bg-subtle)",
      terminalTitlebarBackground: "var(--bg-subtle)",
    },
  },
  defaultProps: { wrap: false },
});
