#!/usr/bin/env python3
"""Offline Chromium execution of the complete Book state/runtime/endcap modules.

Import specifiers are redirected to data URLs only for this no-network fixture.
Native endpoints, Core frame projection and paginator inputs are controlled.
"""
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
NAMES = ['book-reading-state.js', 'reader-producer-evidence.js', 'renderer-content.js',
         'book-action-bridge.js', 'book-endcap.js', 'book-reading-runtime.js']

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--state-source', type=Path, default=SOURCES / NAMES[0])
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        parser.error('Use a fresh output path; previous results are retained')
    executable = shutil.which('chromium') or shutil.which('google-chrome')
    if not executable:
        parser.error('An installed Chromium executable is required')
    paths = {name: args.state_source if name == NAMES[0] else SOURCES / name for name in NAMES}
    originals = {name: path.read_text() for name, path in paths.items()}
    modules = {}
    for name in NAMES:
        source = originals[name]
        for dependency, uri in modules.items():
            source = source.replace("'./" + dependency + "'", json.dumps(uri))
        if re.search(r"(?:from|import)\s*['\"]\./", source):
            parser.error('Unresolved fixture module dependency in ' + name)
        modules[name] = 'data:text/javascript;base64,' + base64.b64encode(source.encode()).decode()
    report = {'scope': __doc__, 'inputs': {str(path): hashlib.sha256(path.read_bytes()).hexdigest()
                for path in [*paths.values(), HERE/'cases.js', HERE/'fixture.js', Path(__file__)]},
              'cases': [], 'page_errors': [], 'harness_errors': []}
    with sync_playwright() as p:
        browser = p.chromium.launch(executable_path=executable, headless=True,
                                   args=['--no-sandbox', '--disable-dev-shm-usage'])
        report['browser'] = browser.version
        names = None
        try:
            catalog = browser.new_page()
            catalog.add_script_tag(content=(HERE/'cases.js').read_text())
            names = catalog.evaluate('bookStateTransactionCases.map(x => x.name)')
            catalog.close()
            if len(set(names)) != len(names) or not names:
                raise ValueError('Scenario roster is empty or contains duplicate names')
            for name in names:
                context = browser.new_context()
                page = context.new_page()
                page.set_default_timeout(5000)
                page.on('pageerror', lambda error, name=name: report['page_errors'].append({'name': name, 'error': str(error)}))
                page.route('**/*', lambda route: route.abort())
                try:
                    page.set_content('<!doctype html><html><body></body></html>')
                    page.evaluate('async url => { window.BookStateTestModules = await import(url) }', modules[NAMES[-1]])
                    page.add_script_tag(content=(HERE/'fixture.js').read_text())
                    page.add_script_tag(content=(HERE/'cases.js').read_text())
                    result = page.evaluate('''async name => {
                        try {
                            await bookStateTransactionCases.find(x => x.name === name).run()
                            return {name, passed: true}
                        } catch (error) { return {name, passed: false, error: String(error), stack: error.stack} }
                    }''', name)
                    report['cases'].append(result)
                except Exception as error:
                    report['harness_errors'].append({'name': name, 'error': str(error)})
                finally:
                    context.close()
        finally:
            browser.close()
    report['total'] = len(report['cases'])
    report['passed'] = sum(case['passed'] for case in report['cases'])
    report['failed'] = report['total'] - report['passed']
    report['passed_gate'] = (names is not None and report['total'] == len(names)
                            and not report['failed'] and not report['page_errors'] and not report['harness_errors'])
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({key: report[key] for key in ['total', 'passed', 'failed', 'passed_gate']}))
    for result in report['cases']:
        if not result['passed']:
            print(result['name'] + ': ' + result['error'])
    for error in report['harness_errors']:
        print(error)
    return 0 if report['passed_gate'] else 1

if __name__ == '__main__':
    sys.exit(main())
