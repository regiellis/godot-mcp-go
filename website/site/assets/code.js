// Copy displayed code so HTML edits cannot leave hidden clipboard text stale.
document.querySelectorAll('.expressive-code').forEach(frame => {
  const pre = frame.querySelector('pre'), button = frame.querySelector('.copy button');
  if (!pre) return;
  function overflow() {
    if (pre.scrollWidth > pre.clientWidth) {
      pre.setAttribute('tabindex', '0'); pre.setAttribute('role', 'region'); pre.setAttribute('aria-label', 'Code example');
    } else {
      pre.removeAttribute('tabindex'); pre.removeAttribute('role'); pre.removeAttribute('aria-label');
    }
  }
  new ResizeObserver(overflow).observe(pre); overflow();
  button?.addEventListener('click', async () => {
    const lines = [...pre.querySelectorAll('.ec-line')];
    const text = lines.length ? lines.map(line => (line.querySelector('.code') || line).textContent).join('\n') : pre.textContent;
    const title = button.title;
    try {
      await navigator.clipboard.writeText(text);
      button.title = 'Copied!'; button.setAttribute('aria-label', 'Copied!');
    } catch { button.title = 'Copy failed; select the code to copy it.'; }
    setTimeout(() => { button.title = title; button.removeAttribute('aria-label'); }, 1600);
  });
});
