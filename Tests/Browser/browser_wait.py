"""Driver-side polling for a viewer which deliberately forbids unsafe-eval."""
import time


def wait_for_reader(page, expression, timeout=20_000):
    deadline = time.monotonic() + timeout / 1000
    while time.monotonic() < deadline:
        # DevTools evaluation does not install an eval-based polling function
        # into the application. Keep the production Content Security Policy.
        if page.evaluate('() => Boolean(' + expression + ')'):
            return
        time.sleep(0.05)
    diagnostics = page.evaluate('''() => ({
        title: document.title,
        reader: !!globalThis.reader,
        renderer: !!globalThis.reader?.view?.renderer,
        endcap: !!globalThis.reader?.bookEndcap,
        contents: globalThis.reader?.view?.renderer?.getContents?.().length,
        errors: globalThis.nativeMessages?.filter(x => x.name === 'readerOnError')
    })''')
    raise AssertionError(f'Reader condition timed out: {expression}; {diagnostics}')
