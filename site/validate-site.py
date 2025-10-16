#!/usr/bin/env python3
"""Check the dependency-free Pages site using only Python's standard library."""

from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urlsplit
import re
import sys
import xml.etree.ElementTree as ET


SITE = Path(__file__).resolve().parent


class SiteParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.ids = set()
        self.references = []
        self.errors = []
        self.headings = []

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        node_id = attrs.get("id")
        if node_id:
            if node_id in self.ids:
                self.errors.append(f"Duplicate id: {node_id}")
            self.ids.add(node_id)
        if tag in {"h1", "h2", "h3"}:
            self.headings.append(tag)
        if tag == "img" and "alt" not in attrs:
            self.errors.append("Image missing alt text")
        if tag == "html" and attrs.get("lang") != "en":
            self.errors.append("Expected English document language")
        if tag == "script":
            self.errors.append("Site should not require JavaScript")
        for name in attrs:
            if name.startswith("on"):
                self.errors.append(f"Inline event handler: {name}")
        for attr in ("href", "src"):
            if attrs.get(attr):
                self.references.append((tag, attr, attrs[attr]))


def main():
    parser = SiteParser()
    html = (SITE / "index.html").read_text(encoding="utf-8")
    parser.feed(html)
    errors = parser.errors
    if parser.headings.count("h1") != 1:
        errors.append("Expected exactly one h1")
    for tag, attr, reference in parser.references:
        url = urlsplit(reference)
        if url.scheme:
            if url.scheme != "https":
                errors.append(f"Unexpected URL scheme: {reference}")
            if attr == "src" or tag == "link" and attr == "href" and url.netloc != "abhinit21.github.io":
                errors.append(f"External runtime dependency: {reference}")
            continue
        if url.netloc:
            errors.append(f"Protocol-relative URL: {reference}")
            continue
        if url.path:
            target = SITE / unquote(url.path)
            if not target.is_file():
                errors.append(f"Missing local asset: {reference}")
        elif url.fragment and unquote(url.fragment) not in parser.ids:
            errors.append(f"Missing fragment target: {reference}")
    if not (SITE / ".nojekyll").is_file():
        errors.append("Missing .nojekyll")
    for path in SITE.glob("*.svg"):
        try:
            ET.parse(path)
        except ET.ParseError as error:
            errors.append(f"Invalid SVG {path.name}: {error}")
    inline_svgs = re.findall(r"<svg\b[^>]*>.*?</svg>", html, re.DOTALL)
    for index, svg in enumerate(inline_svgs, start=1):
        try:
            ET.fromstring(svg)
        except ET.ParseError as error:
            errors.append(f"Invalid inline SVG {index}: {error}")
    css = (SITE / "styles.css").read_text(encoding="utf-8")
    if "prefers-reduced-motion" not in css:
        errors.append("Missing reduced-motion support")
    if errors:
        print("Site checks failed:\n" + "\n".join(f"- {error}" for error in errors))
        return 1
    print(f"Site checks passed: {len(parser.references)} links/assets, unique IDs, SVG, single h1, no JavaScript, reduced motion.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
