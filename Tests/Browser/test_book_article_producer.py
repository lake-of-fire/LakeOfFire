"""Combined Article producer and chapter-pass ownership in the actual viewer.

Native persistence is simulated exactly as in the end-page shell journey.
Renderer loading, sidecars, layout and reader methods are the production code.
"""
import unittest
import uuid
import test_book_endcap_shell as shell
from browser_wait import wait_for_reader


class BookArticleProducerTests(unittest.TestCase):
    setUpClass = classmethod(shell.BookEndcapShellTests.setUpClass.__func__)
    tearDownClass = classmethod(shell.BookEndcapShellTests.tearDownClass.__func__)

    def open_book(self, initial_token='article-A', section_index=None, multipage=False, saved_position=None):
        page = self.browser.new_page(viewport={'width': 390, 'height': 844})
        self.addCleanup(page.close)
        self.errors = []
        page.on('pageerror', lambda error: self.errors.append(str(error)))
        page.add_init_script(shell.BRIDGE + '''
            window.articleProducerToken = 'article-A';
            const issuedArticleProducerOwners = new WeakSet();
            window.manabiArticleProducer = {
                captureIfReady() {
                    if (!window.articleProducerToken) return null;
                    const owner = Object.freeze({
                        token: window.articleProducerToken,
                        frameURL: window.location.href.split('#', 1)[0],
                        documentStartedAtMs: window.performance.timeOrigin,
                    });
                    issuedArticleProducerOwners.add(owner);
                    return owner;
                },
                capture() { return this.captureIfReady(); },
                onInvalidated(owner, callback) { return () => {}; },
                own(payload, owner) {
                    if (!issuedArticleProducerOwners.has(owner)) throw new Error('stale producer owner');
                    Object.defineProperty(payload, 'readerArticleProducer', {
                        value: Object.freeze({...owner}), enumerable: true,
                        writable: false, configurable: false,
                    });
                    return payload;
                },
                isCurrent(owner) {
                    return issuedArticleProducerOwners.has(owner)
                        && owner.token === window.articleProducerToken;
                },
                ready() { return Promise.resolve(this.captureIfReady()); },
            };
        ''')
        page.goto(f'http://127.0.0.1:{self.server.server_port}/load/viewer-assets/foliate-js/ebook-viewer.html')
        wait_for_reader(page, 'typeof window.loadEBook === "function"')
        page.evaluate('(token) => { articleProducerToken = token; }', initial_token)
        fixture_path = '/fixture.epub'
        if multipage:
            fixture_path = '/producer-' + str(uuid.uuid4()) + '.epub'
            def chapter(name):
                # Native-shaped sidecars and text arrive through the EPUB server.
                # Give the renderer real pages without altering its live DOM.
                return shell.prepared_chapter(name).replace('</style>',
                    'body{font-size:96px;line-height:2}</style>')
            if not hasattr(self.server, 'epub_fixtures'):
                self.server.epub_fixtures = {}
            self.server.epub_fixtures[fixture_path] = shell.make_epub(chapter)
            self.addCleanup(self.server.epub_fixtures.pop, fixture_path, None)
        page.evaluate('(path) => loadEBook({url:location.origin+path,layoutMode:"paginated"})', fixture_path)
        wait_for_reader(page, 'globalThis.reader?.view?.renderer?.getContents?.().length > 0 && reader.bookEndcap')
        if saved_position is not None:
            page.evaluate('(position) => loadLastPosition(position)', saved_position)
        elif section_index is None:
            page.evaluate('loadLastPosition({})')
        else:
            page.evaluate('(index) => loadLastPosition({cfi:reader.view.book.sections[index].cfi})', section_index)
        page.locator('#loading-indicator').wait_for(state='hidden', timeout=15000)
        wait_for_reader(page, 'reader.bookReadingRuntime.state.ready && reader.buildMarkAllSectionsAsReadPayload()?.segments?.length > 0')
        return page

    def install_position_receipts(self, page):
        # This endpoint models receipt admission, not Realm or its journal.
        # All navigation, locator generation and publication are bundled code.
        page.evaluate('''() => {
            nativeMessages.length = 0;
            window.positionReceipts = [];
            const endpoint = webkit.messageHandlers.updateReadingProgress;
            const originalPost = endpoint.postMessage.bind(endpoint);
            endpoint.postMessage = payload => {
                originalPost(payload);
                if (payload.ebookLocationObservationOnly === true) return;
                const scope = reader.bookReadingRuntime.state.context?.scope;
                if (!scope || scope.articleEpochID !== payload.bookReadingScope?.articleEpochID
                    || scope.articleEpochID !== bookEpoch
                    || payload.readerArticleProducer?.token !== articleProducerToken) return;
                positionReceipts.push(JSON.parse(JSON.stringify(payload)));
            };
        }''')

    def test_saved_chapter_start_over_publishes_new_beginning_and_reopens(self):
        page = self.open_book(section_index=1)
        self.assertEqual(page.evaluate('reader.view.renderer.displayedIndex'), 1)
        self.assertTrue(page.evaluate('__manabiRequireUserInputBeforePositionSave'))
        self.install_position_receipts(page)
        result = page.evaluate('''async () => {
            // The native Book Actions menu invokes the actual bridge without
            // a shell pointer event that would independently clear the guard.
            const pending = reader.bookActionBridge.perform('startBookOver');
            const request = bookActionRequests.at(-1);
            await replyToBookAction(request, true);
            return { result: await pending, epoch: request.requestID };
        }''')
        self.assertEqual(result['result']['navigation']['status'], 'completed')
        self.wait_for_durable_progress(page)
        wait_for_reader(page, 'positionReceipts.length > 0')
        receipts = page.evaluate('positionReceipts')
        self.assertTrue(all(x['sectionIndex'] == 0 for x in receipts))
        self.assertTrue(all(x['bookReadingScope']['articleEpochID'] == result['epoch'] for x in receipts))
        self.assertTrue(all(x['readerArticleProducer']['token'] == 'article-A' for x in receipts))
        self.assertTrue(all(x['reason'] == 'navigation' for x in receipts))
        self.assertFalse(page.evaluate('__manabiRequireUserInputBeforePositionSave'))
        self.assertEqual(self.errors, [])
        saved = receipts[-1]
        reopened = self.open_book(saved_position={
            'cfi': saved['cfi'], 'fractionalCompletion': saved['fractionalCompletion']})
        self.assertEqual(reopened.evaluate('reader.view.renderer.displayedIndex'), 0)
        self.assertEqual(reopened.evaluate('reader.navHUD.rendererPageSnapshot.current'), 1)
        self.assertTrue(reopened.evaluate('__manabiRequireUserInputBeforePositionSave'))
        self.assertEqual(self.errors, [])

    def test_rejected_start_over_does_not_admit_position_save(self):
        page = self.open_book(section_index=1)
        self.install_position_receipts(page)
        result = page.evaluate('''async () => {
            const pending = reader.bookActionBridge.perform('startBookOver');
            await replyToBookAction(bookActionRequests.at(-1), false);
            return await pending;
        }''')
        self.assertFalse(result['committed'])
        page.wait_for_timeout(500)
        self.assertEqual(page.evaluate('positionReceipts'), [])
        self.assertEqual(page.evaluate("nativeMessages.filter(x => x.name === 'updateReadingProgress' && !x.payload.ebookLocationObservationOnly).length"), 0)
        self.assertEqual(page.evaluate('reader.view.renderer.displayedIndex'), 1)
        self.assertTrue(page.evaluate('__manabiRequireUserInputBeforePositionSave'))
        self.assertEqual(self.errors, [])

    def test_start_over_waits_for_destination_chapter_admission(self):
        page = self.open_book(section_index=1)
        self.install_position_receipts(page)
        self.hold_chapter_replies(page)
        result = page.evaluate('''async () => {
            const pending = reader.bookActionBridge.perform('startBookOver');
            const request = bookActionRequests.at(-1);
            await replyToBookAction(request, true);
            return { result: await pending, epoch: request.requestID };
        }''')
        self.assertEqual(result['result']['navigation']['status'], 'completed')
        self.assertEqual(page.evaluate('reader.view.renderer.displayedIndex'), 0)
        page.wait_for_timeout(500)
        self.assertEqual(page.evaluate('positionReceipts'), [])
        page.evaluate('releaseChapterReplies()')
        self.wait_for_durable_progress(page)
        wait_for_reader(page, 'positionReceipts.length > 0')
        receipts = page.evaluate('positionReceipts')
        self.assertTrue(all(x['sectionIndex'] == 0 for x in receipts))
        self.assertTrue(all(x['bookReadingScope']['articleEpochID'] == result['epoch'] for x in receipts))
        self.assertEqual(self.errors, [])

    def begin_restart_with_cold_producer(self, page):
        self.install_position_receipts(page)
        page.evaluate('''() => {
            const context = reader.bookReadingRuntime.state.captureContext();
            bookEpoch = 'committed-restart';
            publishState(lastNativeBookStateRequest, true);
            articleProducerToken = null;
            const ready = new Promise((resolve, reject) => {
                window.releaseBookProducerReady = () => {
                    articleProducerToken = 'article-restart';
                    resolve(manabiArticleProducer.captureIfReady());
                };
                window.rejectBookProducerReady = () => reject(new Error('producer admission failed'));
            });
            window.bookProducerReadyCalls = 0;
            manabiArticleProducer.ready = () => { ++bookProducerReadyCalls; return ready; };
            window.bookNavigationTarget = {
                action:'startBookOver', accountPresentation, articleProgressID:'book',
                articleEpochID:bookEpoch, chapterEpochID:null,
                sectionLocation:context.sectionLocation, locationRevision:context.locationRevision,
            };
            window.pendingBookNavigation = reader.navigateBookReadingAction(bookNavigationTarget);
        }''')
        wait_for_reader(page, 'bookProducerReadyCalls === 1')

    def test_committed_restart_joins_cold_producer_before_real_navigation(self):
        page = self.open_book(section_index=1)
        self.begin_restart_with_cold_producer(page)
        self.assertEqual(page.evaluate('reader.view.renderer.displayedIndex'), 1)
        self.assertEqual(page.evaluate('positionReceipts'), [])
        self.assertTrue(page.evaluate('__manabiRequireUserInputBeforePositionSave'))
        result = page.evaluate('''async () => {
            releaseBookProducerReady();
            return await pendingBookNavigation;
        }''')
        self.assertEqual(result['status'], 'completed')
        self.wait_for_durable_progress(page)
        wait_for_reader(page, 'positionReceipts.length > 0')
        receipts = page.evaluate('positionReceipts')
        self.assertTrue(all(x['sectionIndex'] == 0 for x in receipts))
        self.assertTrue(all(x['bookReadingScope']['articleEpochID'] == 'committed-restart' for x in receipts))
        self.assertTrue(all(x['readerArticleProducer']['token'] == 'article-restart' for x in receipts))
        self.assertEqual(self.errors, [])

    def test_cold_producer_wait_cannot_adopt_replacement_navigation_authority(self):
        for mode in ['account', 'pass', 'location', 'producer', 'target']:
            with self.subTest(mode=mode):
                page = self.open_book(section_index=1)
                self.begin_restart_with_cold_producer(page)
                result = page.evaluate('''async mode => {
                    if (mode === 'account') {
                        accountPresentation = '2:1';
                        reader.bookReadingRuntime.accountDidChange(accountPresentation);
                    }
                    else if (mode === 'pass' || mode === 'target') {
                        bookEpoch = 'replacement-pass';
                        publishState(lastNativeBookStateRequest, true);
                        if (mode === 'target') bookNavigationTarget.articleEpochID = bookEpoch;
                    } else if (mode === 'location') {
                        await reader.view.renderer.goTo({index:1, anchor:1, bookAction:true});
                    } else window.manabiArticleProducer = {...manabiArticleProducer};
                    releaseBookProducerReady();
                    return await pendingBookNavigation;
                }''', mode)
                self.assertEqual(result['status'], 'superseded')
                self.assertEqual(page.evaluate('reader.view.renderer.displayedIndex'), 1)
                self.assertEqual(page.evaluate('positionReceipts'), [])
                self.assertTrue(page.evaluate('__manabiRequireUserInputBeforePositionSave'))
                self.assertEqual(self.errors, [])

    def test_failed_cold_producer_admission_does_not_turn_or_save(self):
        page = self.open_book(section_index=1)
        self.begin_restart_with_cold_producer(page)
        result = page.evaluate('''async () => {
            rejectBookProducerReady();
            return await pendingBookNavigation;
        }''')
        self.assertEqual(result['status'], 'failed')
        self.assertEqual(page.evaluate('reader.view.renderer.displayedIndex'), 1)
        self.assertEqual(page.evaluate('positionReceipts'), [])
        self.assertTrue(page.evaluate('__manabiRequireUserInputBeforePositionSave'))
        self.assertEqual(self.errors, [])

    def test_cold_producer_wait_cannot_adopt_same_producer_replacement_ticket(self):
        page = self.open_book(section_index=1)
        self.begin_restart_with_cold_producer(page)
        result = page.evaluate('''async () => {
            releaseBookProducerReady();
            // A synchronous readiness observer retires the resolved ticket
            // before the awaiting navigation continuation can resume.
            articleProducerToken = 'article-replacement';
            return await pendingBookNavigation;
        }''')
        self.assertEqual(result['status'], 'failed')
        self.assertEqual(page.evaluate('reader.view.renderer.displayedIndex'), 1)
        self.assertEqual(page.evaluate('positionReceipts'), [])
        self.assertTrue(page.evaluate('__manabiRequireUserInputBeforePositionSave'))
        self.assertEqual(self.errors, [])

    def test_unsuccessful_or_stale_real_navigation_does_not_admit_position_save(self):
        for mode in ['cancelled', 'rejected', 'stale-producer', 'stale-location']:
            with self.subTest(mode=mode):
                page = self.open_book(section_index=1)
                self.install_position_receipts(page)
                page.evaluate('''mode => {
                    const context = reader.bookReadingRuntime.state.captureContext();
                    bookEpoch = 'committed-restart';
                    publishState(lastNativeBookStateRequest, true);
                    const renderer = reader.view.renderer;
                    const originalGoTo = renderer.goTo.bind(renderer);
                    window.originalBookGoTo = originalGoTo;
                    renderer.goTo = async (target, options) => {
                        if (mode === 'stale-producer' || mode === 'stale-location') {
                            // Hold a REAL successful renderer result. Retiring
                            // its producer must not let this predecessor save.
                            const result = await originalGoTo(target, options);
                            await new Promise(resolve => { window.releaseBookNavigation = resolve; });
                            return result;
                        }
                        // The actual paginator owns cancellation/rejection of
                        // its awaited target; no completed renderer is stubbed.
                        return await originalGoTo(new Promise((resolve, reject) => {
                            window.releaseBookNavigation = () => resolve(target);
                            window.rejectBookNavigation = () => reject(new Error('rejected target'));
                        }), options);
                    };
                    window.pendingBookNavigation = reader.navigateBookReadingAction({
                        action:'startBookOver', accountPresentation, articleProgressID:'book',
                        articleEpochID:bookEpoch, chapterEpochID:null,
                        sectionLocation:context.sectionLocation, locationRevision:context.locationRevision,
                    }).then(result => ({result}), error => ({error:error.message}));
                }''', mode)
                wait_for_reader(page, 'typeof releaseBookNavigation === "function"')
                result = page.evaluate('''async mode => {
                    try {
                        if (mode === 'cancelled') {
                            await originalBookGoTo({index:1, anchor:0, bookAction:true});
                            releaseBookNavigation();
                        } else if (mode === 'rejected') rejectBookNavigation();
                        else if (mode === 'stale-producer') {
                            articleProducerToken = 'article-successor';
                            releaseBookNavigation();
                        } else {
                            // A newer real navigation within the same chapter
                            // cannot donate its location to the older success.
                            await originalBookGoTo({index:0, anchor:1, bookAction:true});
                            releaseBookNavigation();
                        }
                        return await pendingBookNavigation;
                    } finally { reader.view.renderer.goTo = originalBookGoTo; }
                }''', mode)
                if mode == 'cancelled':
                    self.assertEqual(result['result']['status'], 'superseded')
                elif mode == 'rejected':
                    self.assertEqual(result['error'], 'rejected target')
                else:
                    self.assertEqual(result['result']['status'], 'completed')
                page.wait_for_timeout(500)
                self.assertEqual(page.evaluate('positionReceipts'), [])
                self.assertEqual(page.evaluate("nativeMessages.filter(x => x.name === 'updateReadingProgress' && !x.payload.ebookLocationObservationOnly).length"), 0)
                self.assertTrue(page.evaluate('__manabiRequireUserInputBeforePositionSave'))
                self.assertEqual(self.errors, [])

    def test_native_mark_keeps_article_and_chapter_ownership(self):
        page = self.open_book()
        result = page.evaluate('''async () => {
            nativeMessages.length = 0;
            await reader.markAllSectionsAsRead();
            return nativeMessages.filter(x => x.name === 'markSectionAsRead').map(x => x.payload);
        }''')
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0]['readerArticleProducer']['token'], 'article-A')
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
        self.assertEqual(result['requests'][0]['readerArticleProducer']['token'], 'article-A')
        self.assertEqual(result['requests'][0]['bookReadingScope']['chapterEpochID'], 'chapter-successor')
        self.assertEqual(self.errors, [])

    def test_hydration_retains_original_article_token_and_fresh_work_uses_successor(self):
        page = self.open_book()
        result = page.evaluate('''async () => {
            nativeMessages.length = 0;
            reader.pageTrackingStates = [];
            const oldMark = reader.markVisiblePageAsRead('old-article-hydration');
            articleProducerToken = 'article-B';
            const oldResult = await oldMark;
            const oldTokens = nativeMessages.filter(x => x.name === 'markSectionAsRead')
                .map(x => x.payload.readerArticleProducer?.token);
            nativeMessages.length = 0;
            await reader.markAllSectionsAsRead();
            return {oldResult, oldTokens, freshTokens: nativeMessages.filter(x => x.name === 'markSectionAsRead')
                .map(x => x.payload.readerArticleProducer?.token)};
        }''')
        self.assertFalse(result['oldResult'])
        self.assertEqual(result['oldTokens'], [])
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
                    .map(x => x.payload.readerArticleProducer?.token)};
        }''')
        self.assertFalse(result['blocked'])
        self.assertEqual(result['blockedRequests'], 0)
        self.assertEqual(result['tokens'], ['article-B'])
        self.assertEqual(self.errors, [])

    def test_replacement_producer_observes_current_position_without_replaying_old_event(self):
        page = self.open_book()
        page.evaluate("nativeMessages.length = 0; articleProducerToken = null;")
        page.evaluate('reader.handlePhysicalArrowKey("right")')
        wait_for_reader(page, "reader.view.lastLocation?.sectionIndex === 1 && reader.bookReadingRuntime.state.ready")
        # The unavailable producer cannot retain this relocation for later.
        page.wait_for_timeout(100)
        blocked = page.evaluate("nativeMessages.filter(x => x.name === 'updateReadingProgress').length")
        self.assertEqual(blocked, 0)
        page.evaluate("articleProducerToken = 'article-B'; window.dispatchEvent(new CustomEvent('manabi-article-producer-ready'));")
        wait_for_reader(page, "nativeMessages.some(x => x.name === 'updateReadingProgress')")
        messages = page.evaluate("nativeMessages.filter(x => x.name === 'updateReadingProgress').map(x => x.payload)")
        self.assertTrue(messages)
        for message in messages:
            self.assertEqual(message['readerArticleProducer']['token'], 'article-B')
            self.assertEqual(message['sectionIndex'], 1)
            self.assertEqual(message['bookReadingScope']['articleEpochID'], 'initial')
        self.assertEqual(self.errors, [])

    def test_initial_producer_admission_observes_restored_section_without_a_save_or_mark(self):
        page = self.open_book(initial_token=None, section_index=1)
        wait_for_reader(page, 'reader.view.lastLocation?.sectionIndex === 1')
        # Observe the shell's shipping readiness callback, as the native user
        # script does. The test never sets readiness or a location itself.
        page.evaluate("""() => {
            nativeMessages.length = 0;
            window.docStateSamples = [];
            window.__manabiPostReaderDocStateEvent = reason => docStateSamples.push({
                reason, ready: document.documentElement.dataset.mnbReaderRenderReady,
                sectionIndex: reader.view.lastLocation?.sectionIndex,
            });
            articleProducerToken = 'article-B';
            window.dispatchEvent(new CustomEvent('manabi-article-producer-ready'));
        }""")
        wait_for_reader(page, "nativeMessages.some(x => x.name === 'updateReadingProgress')")
        result = page.evaluate("""() => ({
            progress: nativeMessages.filter(x => x.name === 'updateReadingProgress').map(x => x.payload),
            marks: nativeMessages.filter(x => x.name === 'markSectionAsRead').length,
            guarded: window.__manabiRequireUserInputBeforePositionSave,
            samples: docStateSamples,
        })""")
        self.assertTrue(result['guarded'])
        self.assertEqual(result['marks'], 0)
        self.assertTrue(any(x['ready'] == '1' and x['sectionIndex'] == 1 for x in result['samples']))
        for message in result['progress']:
            self.assertTrue(message['ebookLocationObservationOnly'])
            self.assertEqual(message['readerArticleProducer']['token'], 'article-B')
            self.assertEqual(message['sectionIndex'], 1)
            self.assertEqual(message['bookReadingScope']['articleEpochID'], 'initial')
        # A subsequent real user turn still uses the durable progress path.
        self.perform_durable_turn(page, 'left', expected_section=0)
        self.assertFalse(page.evaluate('window.__manabiRequireUserInputBeforePositionSave'))
        self.assertEqual(self.errors, [])

    def test_producer_ready_during_restore_waits_for_fresh_terminal_location(self):
        page = self.open_book(initial_token=None)
        page.evaluate("""() => {
            nativeMessages.length = 0;
            const renderer = reader.view.renderer;
            const originalGoTo = renderer.goTo.bind(renderer);
            renderer.goTo = async (...args) => {
                await new Promise(resolve => { window.releaseRestoreNavigation = resolve; });
                return originalGoTo(...args);
            };
            window.pendingRestore = loadLastPosition({cfi:reader.view.book.sections[1].cfi})
                .finally(() => { renderer.goTo = originalGoTo; });
        }""")
        wait_for_reader(page, '!!window.releaseRestoreNavigation && window.__manabiRestoreInProgress === true')
        page.evaluate("articleProducerToken = 'article-B'; window.dispatchEvent(new CustomEvent('manabi-article-producer-ready'));")
        wait_for_reader(page, 'reader.bookReadingRuntime.state.ready')
        page.wait_for_timeout(500)
        self.assertEqual(page.evaluate("nativeMessages.filter(x => x.name === 'updateReadingProgress').length"), 0)
        page.evaluate('releaseRestoreNavigation(); pendingRestore')
        wait_for_reader(page, "nativeMessages.some(x => x.name === 'updateReadingProgress')")
        messages = page.evaluate("nativeMessages.filter(x => x.name === 'updateReadingProgress').map(x => x.payload)")
        self.assertTrue(all(x['sectionIndex'] == 1 and x['ebookLocationObservationOnly'] for x in messages))
        self.assertTrue(page.evaluate('window.__manabiRequireUserInputBeforePositionSave'))
        self.assertEqual(self.errors, [])

    def test_readiness_burst_does_not_replace_real_user_turn_progress(self):
        page = self.open_book(multipage=True)
        page.evaluate("""async () => {
            nativeMessages.length = 0;
            window.progressDiagnostics = [];
            window.__manabiRestoreDebugLog = (stage, detail) => {
                progressDiagnostics.push({stage, detail});
                if (progressDiagnostics.length > 40) progressDiagnostics.shift();
            };
            const turn = reader.handlePhysicalArrowKey('right');
            window.dispatchEvent(new CustomEvent('manabi-article-producer-ready'));
            window.actualTurnMoved = await turn;
            window.dispatchEvent(new CustomEvent('manabi-article-producer-ready'));
        }""")
        self.assertTrue(page.evaluate('window.actualTurnMoved'), self.progress_diagnostics(page))
        self.assertEqual(page.evaluate('reader.view.lastLocation.sectionIndex'), 0)
        self.wait_for_durable_progress(page)
        result = page.evaluate("""() => ({
            progress: nativeMessages.filter(x => x.name === 'updateReadingProgress').map(x => x.payload),
            marks: nativeMessages.filter(x => x.name === 'markSectionAsRead').length,
            guarded: window.__manabiRequireUserInputBeforePositionSave,
        })""")
        self.assertEqual(result['marks'], 0)
        self.assertFalse(result['guarded'])
        self.assertTrue(any(x['ebookLocationObservationOnly'] for x in result['progress']))
        self.assertTrue(any(not x['ebookLocationObservationOnly'] for x in result['progress']))
        self.assertEqual(self.errors, [])

    def hold_chapter_replies(self, page):
        page.evaluate("""() => {
            nativeMessages.length = 0;
            window.heldChapterRequests = [];
            const handler = webkit.messageHandlers.ebookBookReadingState;
            const originalPost = handler.postMessage.bind(handler);
            handler.postMessage = payload => heldChapterRequests.push(payload);
            window.releaseChapterReplies = () => {
                handler.postMessage = originalPost;
                for (const request of heldChapterRequests.splice(0)) originalPost(request);
            };
        }""")

    def test_delayed_chapter_admission_commits_confirmed_real_turn(self):
        page = self.open_book()
        self.hold_chapter_replies(page)
        moved = page.evaluate("reader.handlePhysicalArrowKey('right')")
        self.assertTrue(moved)
        wait_for_reader(page, 'reader.view.lastLocation?.sectionIndex === 1 && heldChapterRequests.length > 0')
        page.wait_for_timeout(450)
        self.assertEqual(page.evaluate("nativeMessages.filter(x => x.name === 'updateReadingProgress').length"), 0)
        page.evaluate('releaseChapterReplies()')
        self.wait_for_durable_progress(page)
        messages = page.evaluate("nativeMessages.filter(x => x.name === 'updateReadingProgress' && !x.payload.ebookLocationObservationOnly).map(x => x.payload)")
        self.assertTrue(all(x['sectionIndex'] == 1 and x['readerArticleProducer']['token'] == 'article-A' for x in messages))
        self.assertEqual(self.errors, [])

    def test_terminal_lookup_turn_preserves_pending_confirmed_save(self):
        page = self.open_book()
        self.hold_chapter_replies(page)
        self.assertTrue(page.evaluate("reader.handlePhysicalArrowKey('right')"))
        wait_for_reader(page, 'reader.view.lastLocation?.sectionIndex === 1 && heldChapterRequests.length > 0')
        page.wait_for_timeout(450)
        before = page.evaluate('reader.view.lastLocation.sectionIndex')
        result = page.evaluate("reader.performLookupNavigationPageTurn({kind:'word', direction:'next', navigationToken:'pending-save-terminal'})")
        self.assertFalse(result['moved'])
        self.assertTrue(result['turnResult']['authoritativeNoMove'])
        self.assertFalse(result['opened'])
        self.assertEqual(result['navigationToken'], 'pending-save-terminal')
        self.assertEqual(page.evaluate('reader.view.lastLocation.sectionIndex'), before)
        page.evaluate('releaseChapterReplies()')
        self.wait_for_durable_progress(page)
        messages = page.evaluate("nativeMessages.filter(x => x.name === 'updateReadingProgress' && !x.payload.ebookLocationObservationOnly).map(x => x.payload)")
        self.assertTrue(all(x['sectionIndex'] == 1 and x['readerArticleProducer']['token'] == 'article-A' for x in messages))
        self.assertEqual(self.errors, [])

    def test_successor_navigation_rejects_pending_turn_and_fresh_turn_commits(self):
        page = self.open_book()
        self.hold_chapter_replies(page)
        self.assertTrue(page.evaluate("reader.handlePhysicalArrowKey('right')"))
        wait_for_reader(page, 'reader.view.lastLocation?.sectionIndex === 1 && heldChapterRequests.length > 0')
        page.evaluate('reader.view.renderer.goTo({index:0})')
        wait_for_reader(page, 'reader.view.lastLocation?.sectionIndex === 0')
        page.evaluate('releaseChapterReplies()')
        wait_for_reader(page, 'reader.bookReadingRuntime.state.ready')
        page.wait_for_timeout(450)
        self.assertEqual(page.evaluate("nativeMessages.filter(x => x.name === 'updateReadingProgress' && !x.payload.ebookLocationObservationOnly).length"), 0)
        self.perform_durable_turn(page, 'right', expected_section=1)
        self.assertEqual(self.errors, [])

    def test_rotated_producer_rejects_pending_turn_and_fresh_turn_commits(self):
        page = self.open_book()
        self.hold_chapter_replies(page)
        self.assertTrue(page.evaluate("reader.handlePhysicalArrowKey('right')"))
        wait_for_reader(page, 'reader.view.lastLocation?.sectionIndex === 1 && heldChapterRequests.length > 0')
        page.evaluate("articleProducerToken = 'article-B'; window.dispatchEvent(new CustomEvent('manabi-article-producer-ready')); releaseChapterReplies()")
        wait_for_reader(page, 'reader.bookReadingRuntime.state.ready')
        page.wait_for_timeout(450)
        self.assertEqual(page.evaluate("nativeMessages.filter(x => x.name === 'updateReadingProgress' && !x.payload.ebookLocationObservationOnly).length"), 0)
        self.perform_durable_turn(page, 'left', expected_section=0)
        messages = page.evaluate("nativeMessages.filter(x => x.name === 'updateReadingProgress' && !x.payload.ebookLocationObservationOnly).map(x => x.payload)")
        self.assertTrue(all(x['readerArticleProducer']['token'] == 'article-B' for x in messages))
        self.assertEqual(self.errors, [])

    def progress_diagnostics(self, page):
        return page.evaluate("""() => ({moved:window.actualTurnMoved,
            location:reader.view.lastLocation, navigationInFlight:reader.view.renderer.navigationInFlight,
            scope:reader.bookReadingRuntime.state.scope,
            stages:window.progressDiagnostics ?? []})""")

    def wait_for_durable_progress(self, page):
        try:
            wait_for_reader(page, "nativeMessages.some(x => x.name === 'updateReadingProgress' && x.payload.ebookLocationObservationOnly !== true)", timeout=5000)
        except AssertionError as error:
            self.fail(str(error) + '; progress=' + str(self.progress_diagnostics(page)))

    def perform_durable_turn(self, page, direction, expected_section):
        page.evaluate("""async direction => {
            nativeMessages.length = 0;
            window.progressDiagnostics = [];
            window.__manabiRestoreDebugLog = (stage, detail) => {
                progressDiagnostics.push({stage, detail});
                if (progressDiagnostics.length > 40) progressDiagnostics.shift();
            };
            window.actualTurnMoved = await reader.handlePhysicalArrowKey(direction);
        }""", direction)
        self.assertTrue(page.evaluate('window.actualTurnMoved'), self.progress_diagnostics(page))
        wait_for_reader(page, f'reader.view.lastLocation?.sectionIndex === {expected_section}')
        self.wait_for_durable_progress(page)

    def test_closed_reader_does_not_publish_on_replacement_producer_ready(self):
        page = self.open_book()
        page.evaluate("reader.close(); nativeMessages.length = 0; articleProducerToken = 'article-B'; window.dispatchEvent(new CustomEvent('manabi-article-producer-ready'));")
        page.wait_for_timeout(100)
        self.assertEqual(page.evaluate("nativeMessages.filter(x => x.name === 'updateReadingProgress').length"), 0)
        self.assertEqual(self.errors, [])


if __name__ == '__main__':
    unittest.main(verbosity=2)
