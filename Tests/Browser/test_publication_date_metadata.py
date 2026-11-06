#!/usr/bin/env python3
"""Exercise complete Reader resources and rendered output in Playwright's three engines.

Requires Python Playwright and its installed Chromium, Firefox and WebKit engines.
Run: python Tests/Browser/test_publication_date_metadata.py --baseline REF --output FILE
This verifies JS resource behavior; it does not compile Swift or execute WKWebView.
"""
import argparse
import asyncio
import hashlib
import json
import subprocess
from pathlib import Path

from playwright.async_api import async_playwright

ROOT = Path(__file__).resolve().parents[2]
RESOURCES = "Sources/LakeOfFireContent/Resources/"
FILES = ["User Scripts/Readability.js", "User Scripts/dompurify.min.js",
         "User Scripts/readability_initialization.template.js",
         "User Scripts/readability_view_original.js", "User Scripts/readability_reader_mode.js",
         "CSS/Reader.css", "CSS/SwiftReadability.css"]
VALUES = ['<span id="date-injected">not a date</span>',
          '<img src="missing" onerror="dateProbe=1">invalid',
          'unknown & pending <time>', '2026-10-22', '']
BRIDGE = """window.dateProbe=0; window.__parsed=null; window.__unavailable=false;
window.webkit={messageHandlers:new Proxy({}, {get:(_,name)=>({postMessage(value) {
 if(name==='readabilityParsed') window.__parsed=value;
 if(name==='readabilityModeUnavailable') window.__unavailable=true;
}})})};"""
ARTICLE = ("<!doctype html><html><head><title>Reader date fixture</title></head><body>"
           "<article><h1>Reader date fixture</h1>" +
           "<p>This is a substantive article paragraph with several sentences, written to test date "
           "metadata. It contains enough ordinary text to retain the article when parsed for reading.</p>" * 12 +
           "</article></body></html>")


def git(*args):
    return subprocess.check_output(["git", "-C", str(ROOT), *args]).decode().strip()


def compose(ref):
    resources = {name: (subprocess.check_output(["git", "-C", str(ROOT), "show", f"{ref}:{RESOURCES}{name}"])
                        if ref else (ROOT / RESOURCES / name).read_bytes()) for name in FILES}
    text = {name: data.decode() for name, data in resources.items()}
    # Match ReadabilityScript.swift's load order and literal substitutions.
    css = text["CSS/Reader.css"] + text["CSS/SwiftReadability.css"]
    scripts = text["User Scripts/readability_view_original.js"] + "\n;\n" + text["User Scripts/readability_reader_mode.js"]
    template = (text["User Scripts/readability_initialization.template.js"]
                .replace("##CHAR_THRESHOLD##", "1").replace("##CSS##", css).replace("##SCRIPT##", scripts))
    source = text["User Scripts/Readability.js"] + text["User Scripts/dompurify.min.js"] + template
    return source, {name: hashlib.sha256(data).hexdigest() for name, data in resources.items()}


async def observe(browser, source, value):
    context = await browser.new_context(locale="en-US", timezone_id="UTC")
    try:
        await context.add_init_script(BRIDGE)
        page = await context.new_page()
        await page.route("**/*", lambda route: route.fulfill(content_type="text/html", body=ARTICLE))
        await page.goto("https://reader.example/article")
        await page.evaluate("""value => {
            const meta=document.createElement('meta');
            meta.setAttribute('property', 'article:published_time');
            meta.setAttribute('content', value); document.head.append(meta);
        }""", value)
        expected = await page.evaluate("""value => {
            if (!value) return null;
            const parsed=new Date(value);
            if(Number.isNaN(parsed.getTime())) return value;
            try {return new Intl.DateTimeFormat(undefined,{dateStyle:'short'}).format(parsed);}
            catch (_) {return parsed.toLocaleDateString();}
        }""", value)
        await page.evaluate(source)
        await page.evaluate("window.manabi_readability(); void 0")
        await page.wait_for_function("window.__parsed || window.__unavailable")
        payload = await page.evaluate("window.__parsed")
        assert payload and isinstance(payload.get("outputHTML"), str), "No production output payload"
        rendered = await context.new_page()
        await rendered.route("**/*", lambda route: route.abort())
        await rendered.goto("about:blank")
        await rendered.evaluate(BRIDGE)
        await rendered.set_content(payload["outputHTML"], wait_until="load")
        result = await rendered.evaluate("""() => {
            const date=document.getElementById('reader-publication-date');
            return {text:date?.textContent ?? null, present:!!date,
                children:date?.children.length || 0,
                injectedNodes:document.querySelectorAll('#date-injected,img[onerror]').length,
                dateProbe:window.dateProbe};
        }""")
        result.update(value=value, expected=expected, payloadDate=payload.get("publishedTime"),
                      payloadHasDate="publishedTime" in payload)
        result["checks"] = {
            "text": result["text"] == expected,
            "presence": result["present"] == bool(value),
            "noChildElements": result["children"] == 0,
            "noInjectedNodes": result["injectedNodes"] == 0,
            "noExecution": result["dateProbe"] == 0,
            "payload": result["payloadHasDate"] and result["payloadDate"] == expected,
        }
        result["passed"] = all(result["checks"].values())
        return result
    finally:
        await context.close()


async def run(args):
    sources = {"candidate": compose(None), "baseline": compose(args.baseline)}
    report = {"head": git("rev-parse", "HEAD"), "tree": git("rev-parse", "HEAD^{tree}"),
              "baseline": git("rev-parse", args.baseline), "native_swift_executed": False,
              "resourceHashes": {name: info[1] for name, info in sources.items()}, "observations": []}
    try:
        async with async_playwright() as playwright:
            for engine in ["chromium", "firefox", "webkit"]:
                options = {"headless": True}
                if engine == "chromium":
                    options["args"] = ["--disable-features=MacAppCodeSignClone"]
                browser = await getattr(playwright, engine).launch(**options)
                try:
                    for variant, (source, _) in sources.items():
                        for index, value in enumerate(VALUES):
                            result = await observe(browser, source, value)
                            result.update(engine=engine, version=browser.version, variant=variant)
                            report["observations"].append(result)
                            expected_pass = variant == "candidate" or index >= 3
                            assert result["passed"] == expected_pass, result
                            if not expected_pass:
                                assert not result["checks"]["text"], result
                                if index == 1:
                                    assert result["dateProbe"] == 1 and result["injectedNodes"] == 1, result
                            print(engine, variant, index, "PASS" if result["passed"] else "EXPECTED BASELINE FAILURE", flush=True)
                finally:
                    await browser.close()
        report["passed"] = len(report["observations"]) == 30
    finally:
        output = Path(args.output).absolute()
        assert output.resolve() == output and not output.is_symlink()
        output.write_text(json.dumps(report, indent=2) + "\n")
    assert report["passed"]


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", required=True)
    parser.add_argument("--output", required=True)
    asyncio.run(run(parser.parse_args()))
