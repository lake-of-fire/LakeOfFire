"""Combined Article producer and chapter-pass ownership in the actual viewer.

Native persistence is simulated exactly as in the end-page shell journey.
Renderer loading, sidecars, layout and reader methods are the production code.
"""
import unittest
from test_book_endcap_shell import BookEndcapShellTests, BRIDGE
from browser_wait import wait_for_reader


class BookArticleProducerTests(unittest.TestCase):
    setUpClass = classmethod(BookEndcapShellTests.setUpClass.__func__)
    tearDownClass = classmethod(BookEndcapShellTests.tearDownClass.__func__)

    def open_book(self):
        page = self.browser.new_page(viewport={'width': 390, 'height': 844})
        self.addCleanup(page.close)
        self.errors = []
        page.on('pageerror', lambda error: self.errors.append(str(error)))
        page.add_init_script(BRIDGE + '''
            window.articleProducerToken = 'article-A';
            window.manabi_captureArticleMutationProducerToken = () => window.articleProducerToken;
        ''')
        page.goto(f'http://127.0.0.1:{self.server.server_port}/load/viewer-assets/foliate-js/ebook-viewer.html')
        wait_for_reader(page, 'typeof window.loadEBook === "function"')
        page.evaluate('loadEBook({url:location.origin+"/fixture.epub",layoutMode:"paginated"})')
        wait_for_reader(page, 'globalThis.reader?.view?.renderer?.getContents?.().length > 0 && reader.bookEndcap')
        page.evaluate('loadLastPosition({cfi:"",fractionalCompletion:0})')
        page.locator('#loading-indicator').wait_for(state='hidden', timeout=15000)
        wait_for_reader(page, 'reader.bookReadingRuntime.state.ready && reader.buildMarkAllSectionsAsReadPayload()?.segments?.length > 0')
        return page

    def test_native_mark_keeps_article_and_chapter_ownership(self):
        page = self.open_book()
        result = page.evaluate('''async () => {
            nativeMessages.length = 0;
            await reader.markAllSectionsAsRead();
            return nativeMessages.filter(x => x.name === 'markSectionAsRead').map(x => x.payload);
        }''')
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0]['articleMutationProducerToken'], 'article-A')
        self.assertEqual(result[0]['bookReadingScope']['articleEpochID'], 'initial')
        self.assertIsNone(result[0]['bookReadingScope']['chapterEpochID'])
        self.assertEqual(self.errors, [])

    def test_hydration_does_not_relabel_old_mark_after_chapter_restart(self):
        page = self.open_book()
        result = page.evaluate('''async () => {
            nativeMessages.length = 0;
            reader.pageTrackingStates = [];
            const oldMark = reader.markVisiblePageAsRead('old-chapter-hydration');
            // The demand path has returned its Promise; its caller is suspended.
            // Publish a new child pass under the SAME Article producer token.
            chapterEpochs['a'.repeat(64)] = 'chapter-successor';
            publishState(lastNativeBookStateRequest, true);
            const oldResult = await oldMark;
            const oldRequests = nativeMessages.filter(x => x.name === 'markSectionAsRead').length;
            await reader.markAllSectionsAsRead();
            return {oldResult, oldRequests,
                requests: nativeMessages.filter(x => x.name === 'markSectionAsRead').map(x => x.payload)};
        }''')
        self.assertFalse(result['oldResult'])
        self.assertEqual(result['oldRequests'], 0)
        self.assertEqual(len(result['requests']), 1)
        self.assertEqual(result['requests'][0]['articleMutationProducerToken'], 'article-A')
        self.assertEqual(result['requests'][0]['bookReadingScope']['chapterEpochID'], 'chapter-successor')
        self.assertEqual(self.errors, [])

    def test_hydration_retains_original_article_token_and_fresh_work_uses_successor(self):
        page = self.open_book()
        result = page.evaluate('''async () => {
            nativeMessages.length = 0;
            reader.pageTrackingStates = [];
            const oldMark = reader.markVisiblePageAsRead('old-article-hydration');
            articleProducerToken = 'article-B';
            await oldMark;
            const oldTokens = nativeMessages.filter(x => x.name === 'markSectionAsRead')
                .map(x => x.payload.articleMutationProducerToken);
            nativeMessages.length = 0;
            await reader.markAllSectionsAsRead();
            return {oldTokens, freshTokens: nativeMessages.filter(x => x.name === 'markSectionAsRead')
                .map(x => x.payload.articleMutationProducerToken)};
        }''')
        self.assertEqual(result['oldTokens'], ['article-A'])
        self.assertEqual(result['freshTokens'], ['article-B'])
        self.assertEqual(self.errors, [])

    def test_missing_required_grant_is_not_relabelled_and_new_work_can_succeed(self):
        page = self.open_book()
        result = page.evaluate('''async () => {
            nativeMessages.length = 0;
            articleProducerToken = null;
            const blocked = await reader.markVisiblePageAsRead('unadmitted');
            const blockedRequests = nativeMessages.filter(x => x.name === 'markSectionAsRead').length;
            articleProducerToken = 'article-B';
            await reader.markAllSectionsAsRead();
            return {blocked, blockedRequests,
                tokens: nativeMessages.filter(x => x.name === 'markSectionAsRead')
                    .map(x => x.payload.articleMutationProducerToken)};
        }''')
        self.assertFalse(result['blocked'])
        self.assertEqual(result['blockedRequests'], 0)
        self.assertEqual(result['tokens'], ['article-B'])
        self.assertEqual(self.errors, [])


if __name__ == '__main__':
    unittest.main(verbosity=2)
