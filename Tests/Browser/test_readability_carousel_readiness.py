#!/usr/bin/env python3
"""Exercise the bundled Reader carousel controls in offline Chromium."""

import argparse
import os
from pathlib import Path
import shutil

from playwright.sync_api import sync_playwright


ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "Sources/LakeOfFireContent/Resources/User Scripts/readability_reader_mode.js"
ORIGIN = "https://reader.example.test"
GALLERY = """
<section data-readability-carousel="true">
  <div data-readability-carousel-track>
    <figure data-readability-carousel-slide>Image one</figure>
    <figure data-readability-carousel-slide>Image two</figure>
  </div>
</section>
"""


def check_controls(document):
    first = document.locator("[data-readability-carousel]").first
    status = first.locator("[data-readability-carousel-status]")
    previous = first.get_by_role("button", name="Previous image")
    next_image = first.get_by_role("button", name="Next image")
    assert first.locator("[data-readability-carousel-controls]").count() == 1
    assert status.inner_text() == "1 / 2"
    assert previous.is_disabled()
    next_image.click()
    document.wait_for_function("""() =>
        document.querySelector('[data-readability-carousel-status]').textContent === '2 / 2'
    """)
    assert next_image.is_disabled()
    assert previous.is_enabled()

    # An observer scan must wire a newly inserted carousel exactly once.
    document.evaluate("markup => document.body.insertAdjacentHTML('beforeend', markup)", GALLERY)
    document.locator("[data-readability-carousel]").last.locator(
        "[data-readability-carousel-controls]"
    ).wait_for()
    assert first.locator("[data-readability-carousel-controls]").count() == 1
    assert document.locator("[data-readability-carousel-controls]").count() == 2


def exercise(browser, source, case):
    page = browser.new_page()
    page.set_default_timeout(4000)
    pending_images = []
    loading_scripts = """
<script src="/carousel.js"></script>
<script src="/carousel.js"></script>
<script>
  window.readerBeforeDOMContentLoaded = {
    readyState: document.readyState,
    controlCount: document.querySelectorAll('[data-readability-carousel-controls]').length,
  }
</script>
""" if case == "loading" else ""
    document = f"""<!doctype html>
<style>
  [data-readability-carousel-track] {{ display: flex; overflow-x: auto; width: 240px }}
  [data-readability-carousel-slide] {{ flex: 0 0 240px; margin: 0; height: 60px }}
</style>
<script>
  document.addEventListener('DOMContentLoaded', () => {{ window.readerSawDOMContentLoaded = true }})
</script>
<body class="{'readability-mode' if case != 'mode-activation' else ''}">
{GALLERY}
{'<img alt="" src="/slow.svg">' if case == 'interactive-child' else ''}
{loading_scripts}
"""

    def serve(route):
        if route.request.url == f"{ORIGIN}/container":
            route.fulfill(content_type="text/html", body='<iframe name="reader" src="/reader"></iframe>')
        elif route.request.url == f"{ORIGIN}/reader":
            route.fulfill(content_type="text/html", body=document)
        elif route.request.url == f"{ORIGIN}/carousel.js":
            route.fulfill(content_type="text/javascript", body=source)
        elif route.request.url == f"{ORIGIN}/slow.svg":
            pending_images.append(route)
        else:
            route.abort()

    page.route("**/*", serve)
    try:
        if case == "interactive-child":
            page.goto(f"{ORIGIN}/container", wait_until="domcontentloaded")
            reader = page.frame(name="reader")
            assert reader is not None
            reader.wait_for_function("window.readerSawDOMContentLoaded === true")
            assert pending_images and reader.evaluate("document.readyState") == "interactive"
            reader.evaluate(source)
        else:
            page.goto(f"{ORIGIN}/reader", wait_until="load")
            reader = page
            if case == "loading":
                assert reader.evaluate("window.readerBeforeDOMContentLoaded") == {
                    "readyState": "loading",
                    "controlCount": 0,
                }
            else:
                assert reader.evaluate("document.readyState") == "complete"
                reader.evaluate(source)
            if case == "mode-activation":
                assert reader.locator("[data-readability-carousel-controls]").count() == 0
                reader.evaluate("markup => { document.body.outerHTML = '<body>' + markup + '</body>' }", GALLERY)
                reader.evaluate("document.body.classList.add('readability-mode')")
                reader.locator("[data-readability-carousel-controls]").wait_for()

        check_controls(reader)
        if case == "interactive-child":
            # The Reader replaces the markup and can run the same bundle again
            # without navigating the child document.
            reader.evaluate("""({ markup, source }) => {
                document.body.outerHTML = '<body class="readability-mode">' + markup + '</body>'
                new Function(source)()
                new Function(source)()
            }""", {"markup": GALLERY, "source": source})
            check_controls(reader)
    finally:
        page.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=SOURCE)
    parser.add_argument("--browser", default=os.environ.get("CHROMIUM_PATH") or shutil.which("chromium"))
    args = parser.parse_args()
    source = args.source.read_text(encoding="utf-8")
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(executable_path=args.browser, headless=True)
        try:
            for case in ("loading", "complete", "mode-activation", "interactive-child"):
                exercise(browser, source, case)
                print(f"PASS {case}")
        finally:
            browser.close()


if __name__ == "__main__":
    main()
