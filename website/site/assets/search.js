// Search the checked-in JavaScript index. No service or build runtime.
(() => {
  const indexURL = new URL("search-index.js", document.currentScript.src).href;
  const modal = document.getElementById("search-modal");
  const trigger = document.getElementById("search-open");
  const input = document.getElementById("search-input");
  const results = document.getElementById("search-results");
  if (!modal || !trigger || !input || !results) return;
  let indexPromise, debounce, previousFocus;
  let active = -1, generation = 0;
  const normalize = text => text.normalize("NFKD").replace(/[\u0300-\u036f]/g, "").toLowerCase();
  const rows = () => [...results.querySelectorAll(".sm-row")];
  input.setAttribute("role", "combobox");
  input.setAttribute("aria-controls", "search-results");
  input.setAttribute("aria-autocomplete", "list");
  input.setAttribute("aria-expanded", "false");
  function message(text) {
    const p = document.createElement("p");
    p.className = "sm-empty"; p.setAttribute("role", "status"); p.textContent = text;
    results.replaceChildren(p); active = -1;
    input.removeAttribute("aria-activedescendant");
  }
  function select(index) {
    const list = rows(); if (!list.length) return;
    active = (index + list.length) % list.length;
    list.forEach((row, i) => {
      row.classList.toggle("active", i === active);
      row.setAttribute("aria-selected", String(i === active));
    });
    input.setAttribute("aria-activedescendant", list[active].id);
    list[active].scrollIntoView({ block: "nearest" });
  }
  function excerpt(text, terms) {
    const first = Math.max(0, normalize(text).indexOf(terms[0]));
    const start = Math.max(0, first - 65);
    const snippet = (start ? "…" : "") + text.slice(start, start + 220);
    const span = document.createElement("span"); span.className = "sm-excerpt";
    const escaped = terms.map(term => term.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"));
    let cursor = 0;
    for (const match of snippet.matchAll(new RegExp(escaped.join("|"), "gi"))) {
      span.append(document.createTextNode(snippet.slice(cursor, match.index)));
      const mark = document.createElement("mark"); mark.textContent = match[0]; span.append(mark);
      cursor = match.index + match[0].length;
    }
    span.append(document.createTextNode(snippet.slice(cursor))); return span;
  }
  async function search(query, version) {
    const terms = [...new Set(normalize(query.trim()).split(/\s+/).filter(Boolean))];
    if (!terms.length) {
      results.replaceChildren(); active = -1; input.removeAttribute("aria-activedescendant"); return;
    }
    message("Searching…");
    try {
      indexPromise ??= import(indexURL).then(module => module.default);
      const index = await indexPromise;
      if (version !== generation) return;
      const matches = index.map(doc => {
        const title = normalize(doc.title), text = normalize(doc.text);
        if (!terms.every(term => title.includes(term) || text.includes(term))) return null;
        const score = terms.reduce((sum, term) => sum + (title.includes(term) ? 30 : 0)
          + Math.min(10, text.split(term).length - 1), 0);
        return { ...doc, score };
      }).filter(Boolean).sort((a, b) => b.score - a.score || a.title.localeCompare(b.title)).slice(0, 8);
      if (!matches.length) return message(`No results for "${query}".`);
      results.replaceChildren();
      matches.forEach((doc, i) => {
        const row = document.createElement("a"); row.className = "sm-row"; row.id = `search-result-${i}`;
        row.href = doc.url; row.setAttribute("role", "option");
        const title = document.createElement("span"); title.className = "sm-title"; title.textContent = doc.title;
        row.append(title, excerpt(doc.text, terms));
        row.addEventListener("mousemove", () => select(i)); results.append(row);
      });
      select(0);
    } catch {
      indexPromise = undefined;
      if (version === generation) message("Search could not load. Check your connection and try again.");
    }
  }
  function open() {
    if (modal.open) return;
    previousFocus = document.activeElement === document.body ? trigger : document.activeElement; modal.showModal();
    input.setAttribute("aria-expanded", "true"); input.focus(); input.select();
  }
  trigger.addEventListener("click", open);
  modal.addEventListener("click", event => { if (event.target === modal) modal.close(); });
  modal.addEventListener("close", () => {
    if (modal.open) return;
    input.setAttribute("aria-expanded", "false"); previousFocus?.focus();
  });
  input.addEventListener("input", () => {
    clearTimeout(debounce); const version = ++generation;
    debounce = setTimeout(() => search(input.value, version), 120);
  });
  modal.addEventListener("keydown", event => {
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault(); select(active + (event.key === "ArrowDown" ? 1 : -1));
    } else if (event.key === "Enter" && rows()[active]) {
      event.preventDefault(); rows()[active].click();
    } else if (event.key === "Escape") {
      event.preventDefault();
      if (input.value) {
        input.value = ""; clearTimeout(debounce); search("", ++generation);
      } else {
        modal.close(); previousFocus?.focus();
      }
    }
  });
  window.addEventListener("keydown", event => {
    const element = document.activeElement;
    const typing = element instanceof HTMLInputElement || element instanceof HTMLTextAreaElement || element?.isContentEditable;
    if (((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === "k") || (event.key === "/" && !typing && !modal.open)) {
      event.preventDefault(); open();
    }
  });
})();
