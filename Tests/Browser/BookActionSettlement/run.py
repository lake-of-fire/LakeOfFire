#!/usr/bin/env python3
"""Offline real-DOM bridge/endcap scenarios; native outcomes and fault callbacks are controlled."""
from __future__ import annotations
import argparse
import base64
import hashlib
import json
from pathlib import Path
import re
import shutil
import sys
from playwright.sync_api import sync_playwright

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
SOURCES = ROOT / 'Sources/LakeOfFireReader/Resources/Resources/foliate-js'
NAMES = ['book-reading-state.js', 'reader-producer-evidence.js', 'book-action-bridge.js', 'book-endcap.js']


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bridge-source', type=Path, default=SOURCES / 'book-action-bridge.js')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        parser.error('Use a fresh output path; earlier evidence is not overwritten')
    executable = shutil.which('chromium') or shutil.which('google-chrome')
    if executable is None:
        parser.error('Installed Chromium is required; no download is attempted')
    paths = {name: args.bridge_source if name == 'book-action-bridge.js' else SOURCES / name for name in NAMES}
    uris = {}
    for name, path in paths.items():
        source = path.read_text()
        for dependency, uri in uris.items():
            source = source.replace("'./" + dependency + "'", json.dumps(uri))
        if re.search(r"(?:from|import)\s*['\"]\./", source):
            parser.error('Unresolved fixture import in ' + name)
        uris[name] = 'data:text/javascript;base64,' + base64.b64encode(source.encode()).decode()
    cases_path = HERE / 'cases.js'
    report = {'scope': __doc__, 'inputs': {str(path): hashlib.sha256(path.read_bytes()).hexdigest()
              for path in [*paths.values(), cases_path, Path(__file__)]},
              'cases': [], 'page_errors': [], 'harness_errors': []}
    names = []
    with sync_playwright() as p:
        browser = p.chromium.launch(executable_path=executable, headless=True,
                                   args=['--no-sandbox', '--disable-dev-shm-usage'])
        report['browser'] = browser.version
        try:
            catalog = browser.new_page()
            catalog.add_script_tag(content=cases_path.read_text())
            names = catalog.evaluate('bookActionSettlementCases.map(item => item.name)')
            catalog.close()
            if not names or len(names) != len(set(names)):
                raise ValueError('Expected a nonempty unique case roster')
            for name in names:
                context = browser.new_context()
                page = context.new_page()
                page.set_default_timeout(5000)
                page.on('pageerror', lambda error, name=name: report['page_errors'].append({'name': name, 'error': str(error)}))
                page.route('**/*', lambda route: route.abort())
                try:
                    page.set_content('<!doctype html><html><body></body></html>')
                    page.evaluate('''async sources => {
                        window.BookActionTestModules = {
                            ...await import(sources['book-action-bridge.js']),
                            ...await import(sources['book-endcap.js']),
                        }
                    }''', uris)
                    page.add_script_tag(content=cases_path.read_text())
                    result = page.evaluate('''async name => {
                        try { await bookActionSettlementCases.find(item => item.name === name).run(); return {name, passed: true} }
                        catch (error) { return {name, passed: false, error: String(error), stack: error.stack} }
                    }''', name)
                    report['cases'].append(result)
                except Exception as error:
                    report['harness_errors'].append({'name': name, 'error': str(error)})
                finally:
                    context.close()
        finally:
            browser.close()
    report['total'] = len(report['cases'])
    report['passed'] = sum(item['passed'] for item in report['cases'])
    report['failed'] = report['total'] - report['passed']
    report['passed_gate'] = (bool(names) and report['total'] == len(names)
                            and not report['failed'] and not report['page_errors'] and not report['harness_errors'])
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({key: report[key] for key in ['total', 'passed', 'failed', 'passed_gate']}))
    for item in report['cases']:
        if not item['passed']:
            print(item['name'] + ': ' + item['error'])
    for error in report['harness_errors']:
        print(error)
    return 0 if report['passed_gate'] else 1


if __name__ == '__main__':
    sys.exit(main())
