import assert from 'node:assert/strict';
import test from 'node:test';
import {applyBookReadingProjection} from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/book-reading-projection.js';
import {BookReadingStateController} from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/book-reading-state.js';
function fixture(){
 const requests=[];const reader={articleReadingProgress:{readSegmentIdentifiers:['old'],sentenceIdentifiersRead:['sentence']},
    optimisticReadSegmentIdentifiers:new Set(['old']),optimisticSentenceIdentifiersRead:new Set(['sentence'])};
 const scope={articleProgressID:'book',articleEpochID:'E1',chapterKey:'a'.repeat(64),chapterEpochID:null};
 const state=new BookReadingStateController({postMessage:r=>requests.push(r),makeRequestID:()=>String(requests.length+1),
    onState:s=>applyBookReadingProjection(reader,s,p=>{reader.articleReadingProgress={...p,
       readSegmentIdentifiers:[...new Set([...p.readSegmentIdentifiers,...reader.optimisticReadSegmentIdentifiers])],
       sentenceIdentifiersRead:[...new Set([...p.sentenceIdentifiersRead,...reader.optimisticSentenceIdentifiersRead])]};})});
 state.relocate({sectionURL:'chapter'});
 const publish=(revision,ids)=>{state.refresh();return state.apply(requests.at(-1).requestID,{ok:true,
    state:{revision,scope,articleProgressID:'book',articleEpochID:'E1',finished:false,bookReadPresence:'present',chapterReadPresence:'present',
       readSegmentIdentifiers:ids,sentenceIdentifiersRead:[]},
    context:{contextID:'context',scope,articleProgressID:'book',articleEpochID:'E1',sectionLocation:'chapter',isEndPage:false}});};
 return {state,reader,publish};
}
test('a newer same-pass snapshot can remove acknowledged local coverage',()=>{
 const f=fixture();f.publish(1,['old']);f.reader.optimisticReadSegmentIdentifiers.add('old');
 f.publish(2,[]);assert.deepEqual(f.reader.articleReadingProgress.readSegmentIdentifiers,[]);
 assert.equal(f.reader.optimisticReadSegmentIdentifiers.size,0);f.state.close();
});
test('rejected old snapshots cannot retire the current local overlay',()=>{
 const f=fixture();f.publish(5,['retained']);f.reader.optimisticReadSegmentIdentifiers.add('new');
 assert.equal(f.publish(4,[]),false);assert.ok(f.reader.optimisticReadSegmentIdentifiers.has('new'));
 assert.deepEqual(f.reader.articleReadingProgress.readSegmentIdentifiers,['retained']);f.state.close();
});
test('native-retained coverage survives authoritative overlay retirement',()=>{
 const f=fixture();f.publish(5,['retained']);
 assert.deepEqual(f.reader.articleReadingProgress.readSegmentIdentifiers,['retained']);f.state.close();
});
