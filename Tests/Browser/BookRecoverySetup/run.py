#!/usr/bin/env python3
"""Run Book recovery setup-failure cases in an offline Chromium document.

Requires existing Playwright and Chromium. Complete repository modules are loaded
as in-memory ES modules; only relative import specifiers are mapped to blob URLs.
No server, network access, production-function extraction or browser security
relaxation is needed. Native replies, ownership and timer/query completion are
controlled by the shared fixture, not by a native application.
"""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import sys
from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parents[3]
SOURCE = ROOT / 'Sources/LakeOfFireReader/Resources/Resources/foliate-js/book-reading-state.js'
CASES = ROOT / 'Tests/JavaScript/book-recovery-setup-failure-cases.mjs'
# These modules use static relative imports, including multiline named imports.
# Rewriting specifiers keeps every production declaration intact.
IMPORT = re.compile(r'''(?m)^([ \t]*import[ \t]+(?:[\w*{},\s]+[ \t]+from[ \t]+)?)(['"])(\.[^'"]+)\2''')


def module_inputs(source: Path) -> tuple[str, dict[str, str]]:
    modules: dict[str, str] = {}

    def visit(path: Path) -> str:
        path = path.resolve(strict=True)
        if not path.is_relative_to(ROOT) or path.suffix not in ('.js', '.mjs'):
            raise ValueError(f'Import is outside the local module tree: {path}')
        key = 'lake-test:/' + path.relative_to(ROOT).as_posix()
        if key in modules:
            return key
        modules[key] = ''
        text = (source if path == SOURCE else path).read_text(encoding='utf-8')

        def replace(match: re.Match) -> str:
            dependency = visit(path.parent / match.group(3))
            return match.group(1) + match.group(2) + dependency + match.group(2)

        modules[key] = IMPORT.sub(replace, text)
        return key

    return visit(CASES), modules


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=SOURCE)
    parser.add_argument('--browser', default=os.environ.get('CHROMIUM_PATH')
                        or shutil.which('chromium') or shutil.which('chromium-browser'))
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    source = args.source.resolve(strict=True)
    if not args.browser:
        parser.error('Provide --browser or CHROMIUM_PATH for an installed Chromium executable.')
    if args.output and args.output.exists():
        parser.error('Use a fresh --output path; existing results are not overwritten.')
    entry, modules = module_inputs(source)

    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(
            executable_path=args.browser, headless=True,
            args=['--disable-features=MacAppCodeSignClone'] if sys.platform == 'darwin' else [],
        )
        context = None
        try:
            context = browser.new_context()
            context.route('**/*', lambda route: route.abort())
            page = context.new_page()
            errors = []
            page.on('pageerror', lambda error: errors.append(str(error)))
            page.set_content('<!doctype html><html><body></body></html>')
            rows = page.evaluate('''async ({ entry, modules }) => {
                const imports = Object.fromEntries(Object.entries(modules).map(([key, source]) => [
                    key, URL.createObjectURL(new Blob([source], { type: 'text/javascript' })),
                ]));
                const map = document.createElement('script');
                map.type = 'importmap'; map.textContent = JSON.stringify({ imports });
                document.head.append(map);
                try {
                    const { bookRecoverySetupFailureCases } = await import(entry);
                    const names = bookRecoverySetupFailureCases.map(([name]) => name);
                    if (!names.length || new Set(names).size !== names.length) {
                        throw new Error('Scenario roster is empty or has duplicate names');
                    }
                    const rows = [];
                    for (const [name, run] of bookRecoverySetupFailureCases) {
                        let timer;
                        try {
                            await Promise.race([run(), new Promise((_, reject) => {
                                timer = setTimeout(() => reject(new Error('Case exceeded 5 seconds')), 5000);
                            })]);
                            rows.push({ name, passed: true });
                        } catch (error) { rows.push({ name, passed: false, error: String(error) }); }
                        finally { clearTimeout(timer); }
                    }
                    // Deliver late unhandled-rejection/pageerror notifications.
                    await new Promise(resolve => setTimeout(resolve, 0));
                    return rows;
                } finally { Object.values(imports).forEach(url => URL.revokeObjectURL(url)); }
            }''', {'entry': entry, 'modules': modules})
            report = {'browser': browser.version, 'source': str(source), 'cases': rows,
                      'passed': sum(row['passed'] for row in rows),
                      'failed': sum(not row['passed'] for row in rows), 'page_errors': errors}
        finally:
            try:
                if context is not None:
                    context.close()
            finally:
                browser.close()
    text = json.dumps(report, indent=2, ensure_ascii=False)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text + '\n', encoding='utf-8')
    print(text)
    return int(report['failed'] > 0 or bool(report['page_errors']))


if __name__ == '__main__':
    sys.exit(main())
