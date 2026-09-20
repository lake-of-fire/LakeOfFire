#!/usr/bin/env python3
"""One-time exact-anchor transport of the locally tested viewer integration.
Removed after application; it never touches a release branch or user data.
"""
from pathlib import Path
P=Path('Sources/LakeOfFireReader/Resources/Resources/foliate-js')
p=P/'ebook-viewer.js';s=p.read_text()
def rep(old,new,n=1):
    global s
    assert s.count(old)==n,(old[:100],s.count(old),n)
    s=s.replace(old,new)
rep("import { BookEndcap, createBookActionBridge } from './book-endcap.js'", "import { installBookReadingRuntime } from './book-reading-runtime.js'")
rep('    bookActionBridge = null;', '    bookActionBridge = null;\n    bookReadingRuntime = null;')
rep('        this.bookEndcap?.destroy();', '        this.bookReadingRuntime?.close();\n        this.bookReadingRuntime = null;\n        this.bookEndcap?.destroy();')
rep('                if (!owner) return false;', '''                if (!owner) return false;
                if (this.bookReadingRuntime && !this.bookReadingRuntime.isScopeCurrent(owner.bookReadingScope, owner.document)) return false;''')
rep("    applyBookReadingProgress(articleReadingProgress, _reason = 'unspecified') {", """    applyBookReadingProgress(articleReadingProgress, _reason = 'unspecified', scoped = false) {
        // Old unqualified Article refreshes are not authority for a chapter pass.
        if (this.bookReadingRuntime && !scoped) return false;""")
rep('            visiblePageCollectionGeneration: this.visiblePageCollectionGeneration,\n        };\n    }\n    #validatedMarkReadPayload', '            visiblePageCollectionGeneration: this.visiblePageCollectionGeneration,\n            bookReadingScope: this.bookReadingRuntime?.captureScope(document) ?? null,\n        };\n    }\n    #validatedMarkReadPayload')
rep('        this.applyBookReadingProgress(committedProgress, reason);', '        this.applyBookReadingProgress(committedProgress, reason, true);')
rep('        const outcome = await this.nativeMarkReadRequestCoordinator.request({', '''        if (this.bookReadingRuntime && !this.bookReadingRuntime.isScopeCurrent(owner?.bookReadingScope, owner?.document)) {
            this.lastNativeMarkReadRequestErrorCode = 'staleChapterPass';
            return false;
        }
        const outcome = await this.nativeMarkReadRequestCoordinator.request({''')
rep('                pageURL: owner?.document?.location?.href ?? null,', '                pageURL: owner?.document?.location?.href ?? null,\n                bookReadingScope: owner?.bookReadingScope ?? null,')
rep('        if (outcome.success !== true) return false;', '''        if (outcome.success !== true) return false;
        if (this.bookReadingRuntime && !this.bookReadingRuntime.state.noteManualReadSnapshot(outcome.nativeResult?.stateSnapshotSequence)) return false;''')
start=s.index('        const bookActionHandler = window.webkit?.messageHandlers?.ebookBookAction;')
end=s.index('        const initialRestore = options?.initialRestore ?? null;',start)
s=s[:start]+'''        this.bookReadingRuntime = installBookReadingRuntime({
            reader: this, view, document, window, documentStartedAtMs: readerDocumentStartedAtMs(),
            invalidateProjection: () => {
                this.#clearOptimisticMarkReadState('chapter-state-unavailable');
                this.nativeMarkReadRequestCoordinator?.cancelAll('chapter-state-unavailable');
                this.articleReadingProgress = normalizeArticleReadingProgress({});
                this.#renderPageTrackingButtons('chapter-state-unavailable');
            },
            applyProjection: (state, { passChanged }) => {
                if (passChanged) {
                    this.nativeMarkReadRequestCoordinator?.cancelAll('chapter-pass-changed');
                    this.#clearOptimisticMarkReadState('chapter-pass-changed');
                    this.#invalidateVisiblePageSegmentSnapshot('chapter-pass-changed');
                }
                this.applyBookReadingProgress({
                    ...this.articleReadingProgress,
                    readSegmentIdentifiers: state.readSegmentIdentifiers,
                    sentenceIdentifiersRead: state.sentenceIdentifiersRead,
                    articleMarkedAsFinished: state.finished,
                }, 'native-chapter-publication', true);
                this.refreshNativeLookupHitTargets?.('chapter-pass-publication');
            },
            onVisibility: () => {
                this.#clearOptimisticMarkReadState('book-endcap');
                this.#renderPageTrackingButtons('book-endcap');
                void this.updateNavButtons();
            },
        });
        this.bookEndcap = this.bookReadingRuntime?.endcap ?? null;
        this.bookActionBridge = this.bookReadingRuntime?.bridge ?? null;
''' + s[end:]
rep('        const relocateSequence = ++this.#relocateSequence;', '        this.bookReadingRuntime?.updateLocation(true);\n        const relocateSequence = ++this.#relocateSequence;')
rep('        this.#postUpdateReadingProgressMessage({', '        this.#postUpdateReadingProgressMessage({\n            bookReadingScope: this.bookReadingRuntime?.captureScope(getPrimaryRendererContent(this.view?.renderer)?.doc) ?? null,',2)
rep('        expectedLocationFraction = null,\n    }) => {', '        expectedLocationFraction = null,\n        bookReadingScope = null,\n    }) => {')
rep('        window.webkit.messageHandlers.updateReadingProgress.postMessage({', '''        if (this.bookEndcap?.visible) return;
        if (this.bookReadingRuntime && !this.bookReadingRuntime.isScopeCurrent(bookReadingScope, doc)) return;
        window.webkit.messageHandlers.updateReadingProgress.postMessage({
            bookReadingScope,
            pageURL: currentDocumentURL,''')
rep('            if (sameVisiblePage) {', '            if (sameVisiblePage && target?.bookAction !== true) {')
rep('        if (this.bookEndcap?.visible) return false;', '        if (this.bookEndcap?.visible || (this.bookReadingRuntime && !this.bookReadingRuntime.state.ready)) return false;')
rep("const markReadButtonsVisible = !this.bookEndcap?.visible &&", "const markReadButtonsVisible = !this.bookEndcap?.visible && (!this.bookReadingRuntime || this.bookReadingRuntime.state.ready) &&")
rep('                messageTarget.lookupPayload = target.lookupPayload;', '                messageTarget.lookupPayload = { ...target.lookupPayload, bookReadingScope: globalThis.reader?.bookReadingRuntime?.captureScope(doc) ?? null };')
s += '''
window.manabi_refreshBookReadingState = () => globalThis.reader?.bookReadingRuntime?.state.refresh() ?? false;
window.manabi_bookReadingStateDidUpdate = (requestID, result) =>
    globalThis.reader?.bookReadingRuntime?.state.apply(requestID, result) ?? false;
'''
rep('    #currentSectionReadState() {', '''    async navigateBookReadingAction(target) {
        return await this.bookReadingRuntime?.navigate(target) ?? { status: 'superseded' };
    }
    #currentSectionReadState() {''')
p.write_text(s)
p=P/'book-endcap.js';s=p.read_text()
s=s[:s.index('// All actions have an explicit')]+"export { createBookActionBridge } from './book-action-bridge.js'\n"
s=s.replace('    #listeners = []', '    #listeners = []\n    #ready = false\n    #recovery = null')
s=s.replace('performAction, onChange = () => {}', 'performAction, recoverAction = null, onChange = () => {}')
s=s.replace('        this.performAction = performAction', '        this.performAction = performAction\n        this.recoverAction = recoverAction')
s=s.replace('Finish this book without changing any read markings.', 'Your reading history and skipped sections will stay unchanged.')
s=s.replace('    setFinished(finished) {', '    setReady(ready) {\n        this.#ready = ready === true\n        this.#render()\n    }\n\n    setFinished(finished) {')
s=s.replace('!this.#visible || this.#busy)', '!this.#visible || this.#busy || (!this.#ready && !this.#recovery))')
s=s.replace('const result = await this.performAction(action)', 'const result = this.#recovery\n                ? await this.recoverAction(this.#recovery) : await this.performAction(action)')
s=s.replace('            if (result?.ok !== true)', "            if (result?.pending || result?.outcomeUnknown) {\n                const error = new Error(result.error || 'Check the original action status.')\n                error.outcomeUnknown = true\n                error.requestID = result.requestID\n                error.action = result.action || action\n                throw error\n            }\n            if (result?.ok !== true)")
s=s.replace("            this.#finished = result.finished === true\n            if (action === 'startBookOver') this.leave()", "            // Only ordered native publications change Finished. Command replies\n            // acknowledge a historical operation; they cannot select current state.\n            if (result.navigation?.status === 'failed') {\n                this.#recovery = { requestID: result.requestID, action: result.action || action, kind: 'navigate' }\n                this.error.textContent = result.navigation.message || 'The new pass was saved. Go to its beginning without restarting again.'\n                this.error.hidden = false\n            } else { this.#recovery = null }")
s=s.replace('            this.error.textContent = error?.message', "            if (error?.outcomeUnknown && error.requestID) {\n                this.#recovery = { requestID: error.requestID, action: error.action || action, kind: 'status' }\n            } else { this.#recovery = null }\n            this.error.textContent = error?.message")
s=s.replace("this.button.textContent = this.#finished ? 'Start Book Over' : 'Finish Book'", "this.button.textContent = this.#recovery\n            ? (this.#recovery.kind === 'navigate' ? 'Go to Beginning' : 'Check Status')\n            : this.#finished ? 'Start Book Over' : 'Finish Book'")
s=s.replace('this.button.disabled = this.#busy','this.button.disabled = this.#busy || (!this.#ready && !this.#recovery)')
p.write_text(s)
p=Path('Tests/JavaScript/book-endcap.test.mjs');s=p.read_text();s=s[:s.index("test('bridge only posts")]
s=s.replace('    return {cap,host,publication,document,changes}','    cap.setReady(true)\n    return {cap,host,publication,document,changes}')
s=s.replace('pending.resolve({ok:true,finished:true});assert.equal(await first,true)', 'cap.setFinished(true);pending.resolve({ok:true,committed:true,finished:true});assert.equal(await first,true)')
s=s.replace('assert.equal(await cap.activate(),true);assert.equal(cap.finished,true)', 'assert.equal(await cap.activate(),true);assert.equal(cap.finished,false);cap.setFinished(true);assert.equal(cap.finished,true)')
s=s.replace('pending.resolve({ok:true,finished:false});await task\n    assert.equal(cap.visible,false);assert.equal(cap.finished,false)', 'cap.setFinished(false);cap.leave();pending.resolve({ok:true,committed:true,finished:false});await task\n    assert.equal(cap.visible,false);assert.equal(cap.finished,false)')
s=s.replace('assert.equal(cap.visible,false);assert.equal(cap.finished,true)', 'assert.equal(cap.visible,false);assert.equal(cap.finished,false)')
s+='''
test('old Finish acknowledgement never overwrites a newer native projection',async()=>{
    const pending=deferred();const {cap}=fixture(()=>pending.promise);cap.enter()
    const p=cap.activate();cap.setFinished(false);pending.resolve({ok:true,committed:true,finished:true});await p
    assert.equal(cap.finished,false)
})
test('committed restart with failed navigation remains visible with recovery',async()=>{
    const {cap}=fixture(async()=>({ok:true,committed:true,requestID:'r',navigation:{status:'failed',message:'Saved; navigation failed'}}))
    cap.setFinished(true);cap.enter();await cap.activate()
    assert.equal(cap.visible,true);assert.equal(cap.button.textContent,'Go to Beginning');assert.equal(cap.error.hidden,false)
})
test('without an admitted native state no semantic action is issued',async()=>{
    const calls=[];const {cap}=fixture(x=>calls.push(x));cap.setReady(false);cap.enter()
    assert.equal(await cap.activate(),false);assert.deepEqual(calls,[])
})
''';p.write_text(s)
p=Path('Tests/Browser/book-endcap.html');s=p.read_text().replace("window.readIDs = ['chapter-0:read', 'chapter-1:read']", "window.readIDs = ['chapter-0:read', 'chapter-1:read']\nwindow.historicalReadIDs = [...window.readIDs]")
s=s.replace("return {ok:true,finished:action==='finishBook'}", "cap.setFinished(action==='finishBook')\n        return {ok:true,committed:true,finished:action==='finishBook'}")
s=s.replace('window.cap = cap', 'cap.setReady(true)\nwindow.cap = cap');p.write_text(s)
p=Path('Tests/Browser/test_book_endcap.py');s=p.read_text().replace("self.assertEqual(page.evaluate('readIDs'),[])","self.assertEqual(page.evaluate('readIDs'),[])\n        self.assertEqual(page.evaluate('historicalReadIDs'),['chapter-0:read','chapter-1:read'])");p.write_text(s)
p=Path('Tests/Browser/prepared_book_fixture.py');s=p.read_text().replace("text = f'This is the {name} chapter. Some content remains deliberately unmarked.'", "text = f'昨日の午後、図書館で本を読みました。猫がいます。 {name}'");p.write_text(s)
