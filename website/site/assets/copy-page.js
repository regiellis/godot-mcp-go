// Each page's llm.txt is also directly downloadable without JavaScript.
document.querySelectorAll(".copy-page").forEach(root => {
  root.querySelectorAll("button[data-copy]").forEach(button => {
    button.addEventListener("click", async () => {
      if (button.dataset.busy) return;
      button.dataset.busy = "1";
      const label = button.querySelector(".cp-label"), previous = label?.textContent;
      try {
        const response = await fetch(new URL("llm.txt", location.href), { cache: "no-cache" });
        if (!response.ok) throw new Error("Copy source unavailable");
        let text = await response.text();
        if (button.dataset.copy === "agent") {
          const source = document.querySelector('link[rel="canonical"]')?.href || location.href;
          text = `Swallowtail documentation\nSource: ${source}\n\n${text}`;
        }
        await navigator.clipboard.writeText(text);
        if (label) label.textContent = "Copied";
        button.classList.add("copied");
      } catch {
        if (label) label.textContent = "Copy failed";
        button.title = "Open the llm.txt link to read or copy this page.";
      } finally {
        setTimeout(() => {
          if (label) label.textContent = previous;
          button.classList.remove("copied"); delete button.dataset.busy;
        }, 1600);
      }
    });
  });
});
