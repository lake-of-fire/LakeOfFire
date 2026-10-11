"""Actual shipped modules on the secure loopback browser fixture.

The iOS custom-scheme counterpart lives in EBookCryptographicUUIDWebKitTests.
"""
import unittest
import test_book_endcap_shell as shell
from browser_wait import wait_for_reader


class BookUUIDCompatibilityTests(unittest.TestCase):
    setUpClass = classmethod(shell.BookEndcapShellTests.setUpClass.__func__)
    tearDownClass = classmethod(shell.BookEndcapShellTests.tearDownClass.__func__)

    def test_secure_default_and_portable_requests_and_entropy_errors(self):
        page = self.browser.new_page()
        self.addCleanup(page.close)
        page.goto(f'http://127.0.0.1:{self.server.server_port}/load/viewer-assets/foliate-js/ebook-viewer.html')
        wait_for_reader(page, 'typeof window.loadEBook === "function"')
        result = page.evaluate("""async () => {
            const {cryptographicUUID} = await import('./cryptographic-uuid.js');
            const {BookReadingStateController} = await import('./book-reading-state.js');
            const {createBookActionBridge} = await import('./book-action-bridge.js');
            const pattern = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
            const check = (value, message) => {if (!value) throw new Error(message)};
            check(isSecureContext && typeof crypto.randomUUID === 'function', 'Loopback must exercise secure default');
            const descriptor = Object.getOwnPropertyDescriptor(globalThis, 'crypto');
            const actualCrypto = crypto, paths = [];
            try {
                for (const mode of ['secure', 'portable', 'missing', 'throwing']) {
                    const provider = mode === 'secure' ? actualCrypto : mode === 'portable'
                        ? {getRandomValues: bytes => actualCrypto.getRandomValues(bytes)}
                        : mode === 'missing' ? {} : {getRandomValues() {throw new Error('entropy failed')}};
                    Object.defineProperty(globalThis, 'crypto', {configurable: true, value: provider});
                    const posts = [];
                    const state = new BookReadingStateController({postMessage:p=>posts.push(p),
                        documentStartedAtMs:performance.timeOrigin, topWindowURL:location.href});
                    const bridge = createBookActionBridge({postMessage:p=>posts.push(p),
                        documentStartedAtMs:performance.timeOrigin, topWindowURL:location.href,
                        captureContext:()=>({contextID:'context',locationRevision:1})});
                    try {
                        state.relocate({sectionURL:location.href});
                        if (mode === 'secure' || mode === 'portable') {
                            const pending = bridge.perform('startBookOver');
                            check(posts.length === 2, 'Both defaults must send');
                            check(posts.every(p=>pattern.test(p.requestID)), 'Canonical RFC 4122 v4 requests');
                            check(pattern.test(cryptographicUUID()), 'Canonical relocation helper');
                            bridge.acknowledge(posts[1].deliveryID,{requestID:posts[1].requestID,ok:false,error:'controlled'});
                            await pending;
                        } else {
                            let rejected = false;
                            try {await bridge.perform('startBookOver')} catch (_) {rejected = true}
                            check(rejected && posts.length === 0 && bridge.recoveryInfo === null, 'Entropy failure must not dispatch');
                            check(state.refresh() === false, 'State allocation failure remains retryable');
                        }
                        paths.push(mode);
                    } finally {state.close();bridge.close()}
                }
            } finally {
                if (descriptor) Object.defineProperty(globalThis,'crypto',descriptor);
                else delete globalThis.crypto;
            }
            return paths;
        }""")
        self.assertEqual(result, ['secure', 'portable', 'missing', 'throwing'])


if __name__ == '__main__':
    unittest.main(verbosity=2)
