"""Read-only checks for the static site. Uses only Python's standard library."""
from html.parser import HTMLParser
import json
from pathlib import Path
import re
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parent / "site"
BASE = "/godot-mcp-go/"


class Page(HTMLParser):
    def __init__(self, path):
        super().__init__(convert_charrefs=True)
        self.path = path
        self.ids = set()
        self.links = []
        self.feed(path.read_text(encoding="utf-8"))

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if "id" in attrs:
            self.ids.add(attrs["id"])
        for name in ("href", "src"):
            if attrs.get(name):
                self.links.append(attrs[name])
        if attrs.get("srcset"):
            self.links.extend(item.strip().split()[0] for item in attrs["srcset"].split(","))
        assert "data-code" not in attrs, f"{self.path}: stale hidden code-copy payload"
        assert not any(key.startswith("data-astro-") for key in attrs), self.path


def target(source, url):
    parts = urlsplit(url)
    if parts.scheme or parts.netloc:
        return None, ""
    route = unquote(parts.path)
    if route.startswith("/"):
        assert route.startswith(BASE), f"{source}: URL outside site base: {url}"
        path = ROOT / route[len(BASE):]
    else:
        path = source.parent / route if route else source
    path = path.resolve()
    assert path.is_relative_to(ROOT.resolve()), f"URL escapes site: {url}"
    if path.is_dir():
        path /= "index.html"
    return path, unquote(parts.fragment)


def main():
    pages = {path.resolve(): Page(path) for path in ROOT.rglob("*.html")}
    errors = []
    checked = 0
    for path, page in pages.items():
        for url in page.links:
            try:
                dest, anchor = target(path, url)
                if dest is None:
                    continue
                assert dest.is_file(), f"Missing target: {url}"
                if anchor and dest in pages:
                    assert anchor in pages[dest].ids, f"Missing anchor: {url}"
                checked += 1
            except AssertionError as error:
                errors.append(f"{path.relative_to(ROOT.resolve())}: {error}")
    for path in (ROOT / "assets").glob("*.css"):
        for url in re.findall(r"url\(\s*['\"]?([^)'\"]+)['\"]?\s*\)", path.read_text(encoding="utf-8")):
            dest, _ = target(path, url)
            if dest is not None and not dest.is_file():
                errors.append(f"{path.name}: missing CSS asset {url}")
    data = (ROOT / "assets/search-index.js").read_text(encoding="utf-8")
    index = json.loads(data.removeprefix("export default ").strip().removesuffix(";"))
    urls = [item["url"] for item in index]
    assert len(urls) == len(set(urls)), "Duplicate search routes"
    expected = {BASE + p.parent.relative_to(ROOT.resolve()).as_posix() + "/"
                for p in pages if p.is_relative_to((ROOT / "docs").resolve())}
    assert set(urls) == expected, "Search routes differ from documentation pages"
    for item in index:
        dest, _ = target(ROOT / "index.html", item["url"])
        llm = dest.with_name("llm.txt")
        assert llm.is_file(), f"Missing {llm}"
        markdown = llm.read_text(encoding="utf-8")
        assert markdown.startswith("# " + item["title"]), f"Title mismatch: {llm}"
        assert not re.search(r"</?(?:ShellTabs|Fragment|Card)\b|withBase\(|\{g\.title\}", markdown), f"Unresolved template in {llm}"
        assert item["text"].strip(), f"Empty search text: {item['url']}"
    assert not list(ROOT.rglob("*.astro")), "Unexpected Astro source in site"
    assert not (ROOT / "pagefind").exists(), "Unexpected generated search runtime"
    assert not (ROOT / "_astro").exists(), "Unexpected build asset directory"
    if errors:
        print("\n".join(errors))
        raise SystemExit(1)
    print(f"PASS {len(pages)} HTML pages, {len(index)} search entries/llm.txt files, {checked} local links/assets and all CSS URLs")


if __name__ == "__main__":
    main()
