(() => {
    const toggle = document.getElementById("sidebar-toggle");
    const sidebar = document.getElementById("sidebar");
    const scrim = document.getElementById("sidebar-scrim");
    if (!toggle || !sidebar || !scrim) return;
    const open = () => { sidebar.classList.add("open"); scrim.classList.add("show"); };
    const close = () => { sidebar.classList.remove("open"); scrim.classList.remove("show"); };
    toggle.addEventListener("click", () => sidebar.classList.contains("open") ? close() : open());
    scrim.addEventListener("click", close);
  })();
