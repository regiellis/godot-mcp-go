(() => {
    const links = Array.from(document.querySelectorAll("[data-toc]"));
    if (!links.length) return;
    const map = new Map(links.map((l) => [l.getAttribute("data-toc"), l]));
    const targets = links
      .map((l) => document.getElementById(l.getAttribute("data-toc")))
      .filter(Boolean);
    const obs = new IntersectionObserver(
      (entries) => {
        for (const e of entries) {
          if (e.isIntersecting) {
            links.forEach((l) => l.classList.remove("active"));
            map.get(e.target.id)?.classList.add("active");
          }
        }
      },
      { rootMargin: "-80px 0px -70% 0px", threshold: 0 }
    );
    targets.forEach((t) => obs.observe(t));
  })();
