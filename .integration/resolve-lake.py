#!/usr/bin/env python3
"""Resolve only the nine reviewed conflicts between two immutable inputs.

One-shot integration tooling, kept off the production feature ancestry.
All conflict-free Git merges are retained; unrecognized conflicts fail closed.
"""
from pathlib import Path
import re
import subprocess

FEATURE = '52b48fa7c25326ef62995ef18b59ef7c5781b17c'
BASE = '60438f8521dd69d908ba53a692a2ec328e41cff4'
PATH = 'Sources/LakeOfFireReader/Resources/Resources/foliate-js/ebook-viewer.js'
assert subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip() == FEATURE
assert subprocess.check_output(['git', 'rev-parse', 'MERGE_HEAD'], text=True).strip() == BASE
unmerged = subprocess.check_output(['git', 'diff', '--name-only', '--diff-filter=U'], text=True).splitlines()
assert unmerged == [PATH], unmerged
path = Path(PATH)
text = path.read_text()
pattern = re.compile(r'^<<<<<<< HEAD\n(.*?)^=======\n(.*?)^>>>>>>> ' + BASE + r'\n', re.M | re.S)
conflicts = list(pattern.finditer(text))
assert len(conflicts) == 9, len(conflicts)


def resolve(index, ours, theirs):
    if index == 0:
        assert 'async navigateBookReadingAction(target)' in ours
        assert 'async #handleCompletionAction(' in theirs
        # Book Actions deliberately removed the implicit Finish/Restart path.
        return ours
    if index == 1:
        assert 'bookReadingScope: owner?.bookReadingScope ?? null,' in ours
        assert 'message: withArticleMutationProducer(' in theirs
        needle = '                    pageURL: owner?.document?.location?.href ?? null,\n'
        assert theirs.count(needle) == 1
        return theirs.replace(needle, needle + '                    bookReadingScope: owner?.bookReadingScope ?? null,\n')
    if index == 2:
        assert 'this.bookEndcap?.visible' in ours
        assert 'const completionAction = this.completionAction;' in theirs
        capture = theirs.split('        const completionAction = this.completionAction;')[0]
        return ours + capture + '''        const bookEvent = this.bookReadingRuntime?.captureEvent(
            this.#currentPageTrackingDocument()
        ) ?? null;
        if (this.bookReadingRuntime && !bookEvent) return false;
'''
    if index == 3:
        assert '#publishConfirmedPageTurnProgress = debounce((bookEvent)' in ours
        assert '#postConfirmedPageTurnProgress = debounce((articleMutationProducer)' in theirs
        return '''    #postConfirmedPageTurnProgress = (
        articleMutationProducer = captureArticleMutationProducer(window)
    ) => {
        const content = getPrimaryRendererContent(this.view?.renderer);
        const doc = content?.doc ?? content?.document ?? null;
        const bookEvent = this.bookReadingRuntime?.captureEvent(doc) ?? null;
        this.#publishConfirmedPageTurnProgress({ bookEvent, articleMutationProducer });
    }
    #publishConfirmedPageTurnProgress = debounce(({ bookEvent, articleMutationProducer }) => {
        if (this.bookReadingRuntime && !this.bookReadingRuntime.isEventCurrent(bookEvent)) return;
'''
    if index == 4:
        assert 'this.lastCFIPersistenceObservation = decision.nextObservation;' in ours
        assert 'const queued = this.#queueUpdateReadingProgressMessage({' in theirs
        return theirs + '            bookEvent,\n'
    if index == 5:
        assert ours == '        bookEvent = null,\n'
        assert theirs == '        articleMutationProducerToken = null,\n'
        return ours + theirs
    if index == 6:
        assert 'bookReadingScope: bookEvent?.scope ?? null,' in ours
        assert theirs == '        const progressMessage = {\n'
        return ours.replace('        window.webkit.messageHandlers.updateReadingProgress.postMessage({\n', theirs)
    if index == 7:
        assert 'this.bookReadingRuntime?.updateLocation(true);' in ours
        assert 'captureArticleMutationProducer(window);' in theirs
        return theirs + ours
    if index == 8:
        assert 'bookEvent,' in ours
        assert 'this.#queueUpdateReadingProgressMessage({' in theirs
        return theirs + '                    bookEvent,\n'
    raise AssertionError(index)

for index, match in reversed(list(enumerate(conflicts))):
    text = text[:match.start()] + resolve(index, match.group(1), match.group(2)) + text[match.end():]
assert not re.search(r'^(<<<<<<<|=======|>>>>>>>)', text, re.M)
# The async demand-hydration hop is a real suspension even when its current
# implementation returns an already-resolved Promise. A chapter restart during
# that hop must not let this old action capture the new chapter's owner.
needle = '''            ?? await this.#ensureVisiblePageTrackingState(`native-demand:${source}`);
        if (!pageTrackingState) {
            return false;
        }
'''
assert text.count(needle) == 1
text = text.replace(needle, needle + '''        if (this.bookReadingRuntime && !this.bookReadingRuntime.isEventCurrent(bookEvent)) return false;
''')
path.write_text(text)
fixture = Path('Tests/Browser/test_book_endcap_shell.py')
source = fixture.read_text()
assert source.count('        lastLocation = request;\n') == 1
fixture.write_text(source.replace('        lastLocation = request;\n',
    '        lastLocation = request; window.lastNativeBookStateRequest = request;\n'))
subprocess.run(['git', 'add', PATH, str(fixture)], check=True)
