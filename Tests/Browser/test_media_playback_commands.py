"""Execute the production embedded playback command in installed Chromium.

Only play() completion is controlled to reproduce overlapping platform promises.
DOM media nodes, event listeners, seeks, and pause behavior belong to Chromium.
"""
import os
from contextlib import contextmanager, ExitStack
from pathlib import Path
import unittest
from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "Sources/LakeOfFireReader/Reader/ReaderWebMediaPlaybackRouter.swift"


@contextmanager
def browser_session():
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(
            executable_path=os.environ.get("CHROMIUM_PATH"), headless=True,
            args=["--disable-features=MacAppCodeSignClone"])
        try:
            yield browser
        finally:
            browser.close()


@contextmanager
def browser_context(browser):
    context = browser.new_context()
    try:
        yield context
    finally:
        context.close()


class MediaPlaybackCommandTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        source = SOURCE.read_text()
        cls.command = source.split('private static let commandScript = #"""', 1)[1].split('"""#', 1)[0]
        cls.stack = ExitStack()
        cls.addClassCleanup(cls.stack.close)
        cls.browser = cls.stack.enter_context(browser_session())

    def setUp(self):
        stack = ExitStack()
        self.addCleanup(stack.close)
        self.context = stack.enter_context(browser_context(self.browser))
        self.page = self.context.new_page()
        self.page.set_content('<audio preload="none" src="https://example.test/audio.mp3"></audio>')
        self.page.evaluate("""script => {
            window.__manabiReaderMediaDocumentID = 'document-A';
            window.media = document.querySelector('audio');
            media.__manabiReaderMediaTagID = 'media-A';
            window.plays = [];
            media.play = () => new Promise((resolve, reject) => plays.push({resolve, reject}));
            const AsyncFunction = Object.getPrototypeOf(async function() {}).constructor;
            const execute = new AsyncFunction('operation', 'scriptDocumentID', 'tagID',
                'expectedSource', 'play', 'commandID', 'start', 'end', 'rewindTo', script);
            window.command = (id, operation = 'segment', start = 1, end = 2, rewindTo) =>
                Promise.race([
                    execute(operation, 'document-A', 'media-A',
                        'https://example.test/audio.mp3', operation !== 'pause', id, start, end, rewindTo),
                    new Promise((_, reject) => setTimeout(() => reject(new Error('command timed out')), 5000))
                ]);
        }""", self.command)

    def test_stale_rejection_preserves_newer_segment_and_stop_boundary(self):
        result = self.page.evaluate("""async () => {
            const first = command('first');
            const second = command('second', 'segment', 4, 5, 3);
            const owned = media.__manabiReaderTranscriptSegment;
            plays[0].reject(new DOMException('interrupted', 'AbortError'));
            const firstResult = await first;
            const retained = media.__manabiReaderTranscriptSegment === owned;
            plays[1].resolve();
            const secondResult = await second;
            media.currentTime = 5;
            media.dispatchEvent(new Event('timeupdate'));
            return {firstResult, retained, secondResult, position: media.currentTime,
                stopped: !media.__manabiReaderTranscriptSegment};
        }""")
        self.assertEqual(result, dict(firstResult=False, retained=True, secondResult=True,
                                     position=3, stopped=True))

    def test_current_rejection_cleans_its_segment(self):
        result = self.page.evaluate("""async () => {
            const pending = command('first');
            plays[0].reject(new DOMException('unavailable', 'NotSupportedError'));
            return {result: await pending, retained: !!media.__manabiReaderTranscriptSegment};
        }""")
        self.assertEqual(result, dict(result=False, retained=False))

    def test_stale_success_does_not_claim_newer_command(self):
        result = self.page.evaluate("""async () => {
            const first = command('first');
            const second = command('second', 'segment', 4, 5);
            plays[0].resolve();
            const oldResult = await first;
            plays[1].resolve();
            return {oldResult, newResult: await second, retained: !!media.__manabiReaderTranscriptSegment};
        }""")
        self.assertEqual(result, dict(oldResult=False, newResult=True, retained=True))

    def test_pause_retires_segment_while_play_is_pending(self):
        result = self.page.evaluate("""async () => {
            const pending = command('first');
            const paused = await command('pause', 'pause');
            plays[0].reject(new DOMException('interrupted', 'AbortError'));
            return {paused, result: await pending, retained: !!media.__manabiReaderTranscriptSegment};
        }""")
        self.assertEqual(result, dict(paused=True, result=False, retained=False))

    def test_changed_document_rejects_command_without_playing(self):
        result = self.page.evaluate("""async () => {
            window.__manabiReaderMediaDocumentID = 'replacement';
            return {result: await command('first'), plays: plays.length};
        }""")
        self.assertEqual(result, dict(result=False, plays=0))

    def test_changed_source_rejects_command_without_playing(self):
        self.page.evaluate("media.src = 'https://example.test/replacement.mp3'; media.load()")
        self.page.wait_for_function("(media.currentSrc || media.src) === 'https://example.test/replacement.mp3'")
        result = self.page.evaluate("""async () => {
            return {result: await command('first'), plays: plays.length};
        }""")
        self.assertEqual(result, dict(result=False, plays=0))


    def test_retirement_cleans_completed_segment_without_late_pause_or_rewind(self):
        result = self.page.evaluate("""async () => {
            let pauses = 0;
            const pause = media.pause.bind(media);
            media.pause = () => { pauses++; pause(); };
            const pending = command('first', 'segment', 1, 2, 0);
            plays[0].resolve();
            const accepted = await pending;
            const revoked = await command('first', 'cancel');
            media.currentTime = 2;
            media.dispatchEvent(new Event('timeupdate'));
            return {accepted, revoked, pauses, position: media.currentTime,
                retained: !!media.__manabiReaderTranscriptSegment};
        }""")
        self.assertEqual(result, dict(accepted=True, revoked=True, pauses=0, position=2, retained=False))

    def test_cancellation_cleans_segment_before_held_play_finishes(self):
        result = self.page.evaluate("""async () => {
            const pending = command('first', 'segment', 1, 2, 0);
            const revoked = await command('first', 'cancel');
            plays[0].resolve();
            const accepted = await pending;
            media.currentTime = 2;
            media.dispatchEvent(new Event('timeupdate'));
            return {revoked, accepted, position: media.currentTime,
                retained: !!media.__manabiReaderTranscriptSegment};
        }""")
        self.assertEqual(result, dict(revoked=True, accepted=False, position=2, retained=False))

    def test_late_old_revocation_cannot_remove_successor_segment(self):
        result = self.page.evaluate("""async () => {
            const first = command('first');
            const second = command('second', 'segment', 4, 5, 3);
            const owned = media.__manabiReaderTranscriptSegment;
            const revoked = await command('first', 'cancel');
            plays[0].resolve();
            const oldAccepted = await first;
            plays[1].resolve();
            const accepted = await second;
            const retained = media.__manabiReaderTranscriptSegment === owned;
            media.currentTime = 5;
            media.dispatchEvent(new Event('timeupdate'));
            return {revoked, oldAccepted, accepted, retained, position: media.currentTime};
        }""")
        self.assertEqual(result, dict(revoked=False, oldAccepted=False, accepted=True, retained=True, position=3))

if __name__ == "__main__":
    unittest.main()
