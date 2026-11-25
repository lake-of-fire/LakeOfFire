#!/usr/bin/env python3
"""Exercise the V4 Reader publication-date metadata in a real browser.

Run with Python Playwright and its Chromium engine installed. Use
--chromium-executable or PLAYWRIGHT_CHROMIUM_EXECUTABLE for an existing
Chromium binary. The SwiftReadability checkout defaults to ../swift-readability.
"""

import argparse
import os
from pathlib import Path

from playwright.sync_api import sync_playwright


LAKE_ROOT = Path(__file__).resolve().parents[2]
ARTICLE_URL = "https://example.test/article"
ARTICLE_TITLE = "Reader date fixture"
ARTICLE_TEXT = (
    "This article has enough ordinary text for the reader to retain it. "
    "Its publication metadata is supplied separately from the visible body. "
    "Each paragraph contains several sentences and plain text."
)
ARTICLE_HTML = (
    f"<!doctype html><html><head><title>{ARTICLE_TITLE}</title></head>"
    f"<body><article><h1>{ARTICLE_TITLE}</h1>"
    + f"<p>{ARTICLE_TEXT}</p>" * 6
    + "</article></body></html>"
)
PAYLOAD_KEYS = {
    "pageURL",
    "windowURL",
    "readabilityContainerSelector",
    "title",
    "byline",
    "content",
    "inputHTML",
    "outputHTML",
}
DATE_CASES = (
    ("valid ISO date", "2024-01-02T12:00:00Z", "1/2/24"),
    ("missing metadata", None, None),
    ("empty metadata", "", None),
    ("invalid date with punctuation", "Edition <local> & print", "Edition <local> & print"),
    # The selected Readability parser decodes one layer of metadata entities.
    ("literal entity-like text", "Edition &amp;amp; print", "Edition &amp; print"),
)


def bundled_readability(lake_root, readability_root, initialization_template):
    resources = lake_root / "Sources/LakeOfFireContent/Resources"
    scripts = resources / "User Scripts"
    css = resources / "CSS"
    template = initialization_template or scripts / "readability_initialization.template.js"
    parser = readability_root / "Sources/SwiftReadability/Resources/Readability.js"

    def read(path):
        return path.read_text(encoding="utf-8")

    # Keep the load order and placeholder substitutions from ReadabilityScript.swift.
    styles = read(css / "Reader.css") + read(css / "SwiftReadability.css")
    reader_scripts = (
        read(scripts / "readability_view_original.js")
        + "\n;\n"
        + read(scripts / "readability_reader_mode.js")
    )
    initialization = (
        read(template)
        .replace("##CHAR_THRESHOLD##", "1")
        .replace("##CSS##", styles)
        .replace("##SCRIPT##", reader_scripts)
    )
    return read(parser) + read(scripts / "dompurify.min.js") + initialization


def serve_fixture(route):
    if route.request.url == ARTICLE_URL and route.request.is_navigation_request():
        route.fulfill(content_type="text/html; charset=utf-8", body=ARTICLE_HTML)
    else:
        route.abort()


def check_publication_date(context, source, name, metadata, expected_date):
    page = context.new_page()
    try:
        page.goto(ARTICLE_URL)
        page.evaluate(
            """metadata => {
                const messages = {}
                window.readerTestMessages = messages
                window.webkit = { messageHandlers: new Proxy({}, {
                    get: (_target, name) => ({
                        postMessage: payload => { messages[name] = payload }
                    })
                }) }
                if (metadata !== null) {
                    const meta = document.createElement('meta')
                    meta.setAttribute('property', 'article:published_time')
                    meta.setAttribute('content', metadata)
                    document.head.append(meta)
                }
            }""",
            metadata,
        )
        page.evaluate(source)
        page.evaluate("() => window.manabi_readability()")
        page.wait_for_function(
            """() => window.readerTestMessages.readabilityParsed
                || window.readerTestMessages.readabilityModeUnavailable""",
            timeout=5000,
        )
        payload = page.evaluate("window.readerTestMessages.readabilityParsed") or {}
        assert set(payload) == PAYLOAD_KEYS, (name, sorted(payload))
        assert payload["pageURL"] == payload["windowURL"] == ARTICLE_URL, name
        assert payload["readabilityContainerSelector"] is None, name
        assert payload["title"] == ARTICLE_TITLE, name
        assert ARTICLE_TEXT in payload["content"], name

        rendered = page.evaluate(
            """outputHTML => {
                const doc = new DOMParser().parseFromString(outputHTML, 'text/html')
                const metaLine = doc.querySelector('#reader-meta-line')
                const date = metaLine?.querySelector('#reader-publication-date')
                const original = metaLine?.querySelector('.reader-view-original')
                return {
                    readerTitle: doc.querySelector('#reader-title')?.textContent,
                    dateCount: doc.querySelectorAll('#reader-publication-date').length,
                    dateTag: date?.tagName ?? null,
                    dateText: date?.textContent ?? null,
                    dateChildren: date?.children.length ?? 0,
                    dateTextNodes: date
                        ? [...date.childNodes].filter(node => node.nodeType === Node.TEXT_NODE).length
                        : 0,
                    dividerCount: metaLine?.querySelectorAll('.reader-meta-divider').length ?? 0,
                    originalText: original?.textContent,
                    originalURL: original?.getAttribute('href'),
                }
            }""",
            payload["outputHTML"],
        )
        has_date = expected_date is not None
        assert rendered == {
            "readerTitle": ARTICLE_TITLE,
            "dateCount": int(has_date),
            "dateTag": "SPAN" if has_date else None,
            "dateText": expected_date,
            "dateChildren": 0,
            "dateTextNodes": int(has_date),
            "dividerCount": int(has_date),
            "originalText": "View Original",
            "originalURL": ARTICLE_URL,
        }, (name, rendered)
        print(f"PASS: {name}", flush=True)
    finally:
        page.close()


def main():
    options = argparse.ArgumentParser(description=__doc__)
    options.add_argument("--lake-root", type=Path, default=LAKE_ROOT)
    options.add_argument("--readability-root", type=Path)
    options.add_argument("--initialization-template", type=Path)
    options.add_argument(
        "--chromium-executable",
        default=os.environ.get("PLAYWRIGHT_CHROMIUM_EXECUTABLE"),
    )
    args = options.parse_args()
    source = bundled_readability(
        args.lake_root,
        args.readability_root or args.lake_root.resolve().parent / "swift-readability",
        args.initialization_template,
    )

    failures = []
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(headless=True, executable_path=args.chromium_executable)
        try:
            context = browser.new_context(locale="en-US", timezone_id="UTC", service_workers="block")
            context.route("**/*", serve_fixture)
            for case in DATE_CASES:
                try:
                    check_publication_date(context, source, *case)
                except AssertionError as error:
                    failures.append(str(error))
        finally:
            browser.close()
    if failures:
        raise AssertionError("\n".join(failures))


if __name__ == "__main__":
    main()
