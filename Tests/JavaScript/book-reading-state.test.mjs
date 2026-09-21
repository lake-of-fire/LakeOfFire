import assert from 'node:assert/strict'
import test from 'node:test'
import { BookReadingStateController } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/book-reading-state.js'
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
