import assert from 'node:assert/strict'
import test from 'node:test'
import { BookReadingStateController, compareBookAccountPresentation } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/book-reading-state.js'
const make = () => {
    const messages=[], updates=[]; let n=0
    const state=new BookReadingStateController({postMessage:x=>messages.push(x),documentStartedAtMs:1,topWindowURL:'ebook://book',onState:x=>updates.push(x),makeRequestID:()=>String(++n)})
    return {state,messages,updates}
}
const response = (sequence=1, epoch=null, end=false) => {
    const scope=end?null:{articleProgressID:'book',articleEpochID:'E1',chapterKey:'a'.repeat(64),chapterEpochID:epoch}
    return {ok:true,state:{revision:sequence,articleProgressID:'book',articleEpochID:'E1',scope,finished:false,bookReadPresence:'present',chapterReadPresence:end?'empty':'present',readSegmentIdentifiers:['s'],sentenceIdentifiersRead:['t']},context:{contextID:'native-id',articleProgressID:'book',articleEpochID:'E1',scope,sectionLocation:end?null:'chapter.xhtml',isEndPage:end}}
}
test('scope is unavailable until the matching native publication',()=>{
    const {state,messages}=make();state.relocate({sectionURL:'chapter'})
    assert.equal(state.ready,false);assert.throws(()=>state.captureContext())
    assert.equal(state.apply('wrong',response()),false)
    assert.equal(state.apply(messages[0].requestID,response()),true)
    assert.equal(state.captureScope('other'),null);assert.equal(state.captureScope('chapter').chapterEpochID,null)
})
test('old chapter response cannot replace the current chapter',()=>{
    const {state,messages}=make();state.relocate({sectionURL:'first'});const old=messages[0]
    state.relocate({sectionURL:'last'});assert.equal(state.apply(old.requestID,response()),false)
    assert.equal(state.ready,false)
})
test('new pass invalidates captured context even in the same document',()=>{
    const {state,messages}=make();state.relocate({sectionURL:'chapter'});state.apply(messages[0].requestID,response())
    const old=state.captureContext();state.refresh()
    const next=response(2,'b'.repeat(64));next.context.contextID='new-id';state.apply(messages.at(-1).requestID,next)
    assert.throws(()=>state.captureContext(old));assert.equal(state.captureScope('chapter').chapterEpochID,'b'.repeat(64))
})
test('native publication older than a committed Mark is rejected',()=>{
    const {state,messages}=make();state.relocate({sectionURL:'chapter'});state.apply(messages[0].requestID,response())
    state.noteManualReadSnapshot(20);state.refresh()
    assert.equal(state.apply(messages.at(-1).requestID,response(19)),false)
    assert.equal(state.apply(messages.at(-1).requestID,response(21)),true)
    assert.equal(state.noteManualReadSnapshot(20),false)
})
test('native post-commit refresh requires exact location revision',()=>{
    const {state,messages}=make();state.relocate({sectionURL:'chapter'});state.apply(messages[0].requestID,response())
    const refresh={...response(3),nativeRefresh:true,location:{sectionURL:'chapter',isEndPage:false,locationRevision:1}}
    state.relocate({sectionURL:'chapter'},{moved:true})
    assert.equal(state.apply('native',refresh),false)
    refresh.location.locationRevision=2
    assert.equal(state.apply('native',refresh),true)
})
test('end page has no chapter scope and no inherited subjects',()=>{
    const {state,messages}=make();state.relocate({isEndPage:true})
    assert.equal(state.apply(messages[0].requestID,response(1,null,true)),true)
    assert.equal(state.captureScope('chapter'),null)
    assert.equal(state.captureContext().isEndPage,true)
})
test('navigation retry never pulls a user back after a page turn',()=>{
    const {state,messages}=make();state.relocate({sectionURL:'chapter'});state.apply(messages[0].requestID,response())
    const target={...state.captureContext(),action:'startChapterOver',chapterEpochID:null}
    assert.equal(state.admitsNavigation(target),true)
    state.relocate({sectionURL:'chapter'},{moved:true})
    assert.equal(state.admitsNavigation(target),false)
})
test('another book epoch cannot own restart navigation',()=>{
    const {state,messages}=make();state.relocate({sectionURL:'chapter'});state.apply(messages[0].requestID,response())
    assert.equal(state.admitsNavigation({...state.captureContext(),action:'startBookOver',articleEpochID:'E0'}),false)
})
test('closed controller cannot be revived by a late response',()=>{
    const {state,messages}=make();state.relocate({sectionURL:'chapter'});state.close()
    assert.equal(state.apply(messages[0].requestID,response()),false);assert.equal(state.refresh(),false)
})
test('malformed or unqualified epoch data is not an initial-pass fallback',()=>{
    for(const mutate of [r=>delete r.state.articleEpochID,r=>r.state.scope.chapterKey='bad',r=>r.state.scope=undefined,r=>r.state.revision=NaN,r=>r.state.revision=true]){
        const {state,messages}=make();state.relocate({sectionURL:'chapter'});const r=response();mutate(r)
        assert.equal(state.apply(messages[0].requestID,r),false)
    }
})



test('account presentation ordering preserves full UInt64 generation and transition phase', () => {
    assert.equal(compareBookAccountPresentation('9007199254740993:1', '9007199254740992:1'), 1)
    assert.equal(compareBookAccountPresentation('42:0', '42:1'), -1)
    assert.equal(compareBookAccountPresentation('42:1', '42:0'), 1)
    assert.equal(compareBookAccountPresentation('18446744073709551615:1', '42:1'), 1)
    for (const invalid of [undefined, '01:1', '-1:1', '42:2', '18446744073709551616:1', '2e3:1']) {
        assert.equal(compareBookAccountPresentation(invalid, null), null)
    }
})
test('new production state fails closed until native supplies an account stamp', () => {
    const messages = []
    const state = new BookReadingStateController({postMessage:r=>messages.push(r),
        documentStartedAtMs:1, topWindowURL:'ebook://book', requiresAccountPresentation:true})
    state.relocate({sectionURL:'chapter'})
    assert.equal(state.apply(messages[0].requestID, response()), false)
    assert.equal(state.ready, false)
    assert.equal(state.apply(messages[0].requestID, {...response(),accountPresentation:'0:1'}), true)
    state.refresh()
    assert.equal(state.apply(messages.at(-1).requestID, response(2)), false)
    assert.equal(state.accountPresentation, '0:1')
})
test('account invalidation before initial reply rejects old state and admits fresh same-document state', () => {
    const {state,messages}=make();state.relocate({sectionURL:'chapter'})
    const old=messages[0]
    assert.equal(state.setAccountPresentation('2:0'),true)
    state.refresh();const fresh=messages.at(-1)
    assert.equal(state.apply(old.requestID,{...response(),accountPresentation:'1:1'}),false)
    assert.equal(state.apply(fresh.requestID,{...response(),accountPresentation:'2:1'}),true)
    assert.equal(state.ready,true)
    assert.equal(state.setAccountPresentation('2:0'),false)
    assert.equal(state.ready,true)
})
test('old native refresh and delayed account signal cannot replace the successor account', () => {
    const {state,messages}=make();state.relocate({sectionURL:'chapter'})
    state.apply(messages[0].requestID,{...response(9),accountPresentation:'1:1'})
    state.setAccountPresentation('2:1');state.refresh()
    assert.equal(state.apply(messages.at(-1).requestID,{...response(1),accountPresentation:'2:1'}),true)
    const old={...response(10),accountPresentation:'1:1',nativeRefresh:true,
        location:{sectionURL:'chapter',isEndPage:false,locationRevision:state.locationRevision}}
    assert.equal(state.apply('old-refresh',old),false)
    assert.equal(state.setAccountPresentation('1:1'),false)
    assert.equal(state.accountPresentation,'2:1');assert.equal(state.state.revision,1)
})
test('reentrant successor account invalidation wins over an older state reply', () => {
    const messages=[]
    const state=new BookReadingStateController({postMessage:r=>messages.push(r),documentStartedAtMs:1,
        topWindowURL:'ebook://book',onAccountChange:stamp=>{if(stamp==='1:1')state.setAccountPresentation('2:1')}})
    state.relocate({sectionURL:'chapter'})
    assert.equal(state.apply(messages[0].requestID,{...response(),accountPresentation:'1:1'}),false)
    assert.equal(state.accountPresentation,'2:1');assert.equal(state.ready,false)
})


test('account adoption callback cannot attach its reply to a reentrant successor request',()=>{
    const messages=[]
    const state=new BookReadingStateController({postMessage:r=>messages.push(r),documentStartedAtMs:1,
        topWindowURL:'ebook://book',onAccountChange:()=>state.refresh()})
    state.relocate({sectionURL:'chapter'});const old=messages[0]
    assert.equal(state.apply(old.requestID,{...response(),accountPresentation:'1:1'}),false)
    assert.equal(state.ready,false);assert.notEqual(messages.at(-1).requestID,old.requestID)
    assert.equal(state.apply(messages.at(-1).requestID,{...response(),accountPresentation:'1:1'}),true)
})
