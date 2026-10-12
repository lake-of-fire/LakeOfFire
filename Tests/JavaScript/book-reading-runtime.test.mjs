import assert from 'node:assert/strict';
import test from 'node:test';
import { installBookReadingRuntime } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/book-reading-runtime.js';
import { createBookActionBridge } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/book-action-bridge.js';
import { createNativeMarkReadRequestCoordinator, refreshNativeMarkReadBookStateForRecovery }
    from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/native-mark-read-request.js';

class Element extends EventTarget {
    attributes = new Map(); children = []; classes = new Set();
    classList = {add:x=>this.classes.add(x),remove:x=>this.classes.delete(x)};
    isConnected = true; inert = false; hidden = false;
    append(x) { this.children.push(x); }
    setAttribute(k,v) { this.attributes.set(k,v); }
    getAttribute(k) { return this.attributes.get(k) ?? null; }
    removeAttribute(k) { this.attributes.delete(k); }
    querySelector(k) { this.nodes ??= new Map(); if(!this.nodes.has(k))this.nodes.set(k,new Element()); return this.nodes.get(k); }
    focus() {}
    remove() { this.isConnected = false; }
}
function fixture({ onInvalidate = () => {} } = {}) {
    const requests = [], projections = [], moves = [];
    const makeDoc = name => {
        const frame = {manabi_bookReadingScope:null, clears:0, presentations:[], reads:[]};
        frame.manabi_invalidateBookReadingScope = () => {
            frame.clears++; frame.manabi_bookReadingScope=null; frame.reads=[];
        };
        frame.manabi_applyBookReadingPresentation = p => {
            frame.presentations.push(p); frame.reads=[...p.readSegmentIdentifiers];
        };
        return {location:{href:`ebook://ebook/processed-section?subpath=${name}`}, defaultView:frame};
    };
    const a=makeDoc('a.xhtml'), b=makeDoc('b.xhtml');
    const renderer={displayedIndex:0,getContents:()=>[{index:0,doc:a},{index:1,doc:b}],
        goTo:async target=>{moves.push(target);renderer.displayedIndex=target.index;return true;}};
    const view=new Element();view.renderer=renderer;
    view.book={sections:[{id:'a.xhtml',linear:'yes'},{id:'b.xhtml',linear:'yes'}]};
    const reader={view};const host=new Element();
    const document={createElement:()=>new Element(),getElementById:()=>host,activeElement:new Element()};
    const window={location:{href:'ebook://ebook/load/book.epub'},webkit:{messageHandlers:{
        ebookBookAction:{postMessage:()=>{}},ebookBookReadingState:{postMessage:r=>requests.push(r)},
    }}};
    const runtime=installBookReadingRuntime({reader,view,document,window,documentStartedAtMs:1,
        applyProjection:p=>projections.push(p),invalidateProjection:onInvalidate,onVisibility:()=>{}});
    const publish=(revision,parent='E1',accountPresentation='0:1',readIDs=['read'],request=requests.at(-1))=>{
        const end=request.isEndPage;
        const location=renderer.displayedIndex===0?'a.xhtml':'b.xhtml';
        const scope=end?null:{articleProgressID:'book',articleEpochID:parent,
            chapterKey:(renderer.displayedIndex===0?'a':'b').repeat(64),chapterEpochID:null};
        return runtime.state.apply(request.requestID,{ok:true,accountPresentation,
            location:{sectionURL:request.sectionURL,isEndPage:request.isEndPage,locationRevision:request.locationRevision},
            ...(request.historyRecoveryObservation ? { historyRecoveryObservation: request.historyRecoveryObservation } : {}),
            state:{revision,articleProgressID:'book',articleEpochID:parent,scope,finished:false,
                bookReadPresence:'present',chapterReadPresence:end?'empty':'present',
                readSegmentIdentifiers:end?[]:readIDs,sentenceIdentifiersRead:[]},
            context:{contextID:`context-${revision}`,articleProgressID:'book',articleEpochID:parent,
                scope,sectionLocation:end?null:location,isEndPage:end},
        });
    };
    runtime.updateLocation();
    return {runtime,reader,view,renderer,a,b,moves,requests,publish,projections};
}

function nativeRecoveryHarness(f) {
    const posted=[],controls=[],timers=new Map(),nativeAcknowledgements=[];let timer=0;
    f.reader.bookReadingRuntime=f.runtime;
    const coordinator=createNativeMarkReadRequestCoordinator({
        postMessage:message=>posted.push(message),postControlMessage:message=>controls.push(message),
        makeRequestID:()=> 'runtime-recovery',
        scheduleTimeout:callback=>{timers.set(++timer,callback);return timer;},
        cancelTimeout:handle=>timers.delete(handle),lifecycleTarget:null,
        isOwnerCurrent:owner=>f.runtime.isScopeCurrent(owner.scope,owner.document),
        onRecovery:({owner,context,isCurrent,observation})=>refreshNativeMarkReadBookStateForRecovery(f.runtime,owner.scope,()=>
            isCurrent() && f.reader.bookReadingRuntime===f.runtime && f.reader.view===f.view
            && f.renderer.displayedIndex===0 && owner.document===f.a
            && context.accountPresentation===f.runtime.state.accountPresentation,observation),
        onRecoveryQuery:proof=>f.runtime.state.recoverHistoryReadingStatus(proof),
    });
    const request=sectionID=>coordinator.request({sectionID,message:{},
        owner:{scope:f.runtime.captureScope(f.a),document:f.a},
        context:{accountPresentation:f.runtime.state.accountPresentation}});
    const finish=(index,revision,history=true)=>{
        const accepted=coordinator.settle({
        requestID:posted[index].requestID,manualReadPendingProtocol:1,
        manualReadPendingObservationToken:posted[index].manualReadPendingObservationToken,
        manualReadPendingState:'finished',sectionId:posted[index].sectionId,success:true,
        stateSnapshotSequence:revision,
        ...(history?{manualReadPendingHistoryRecovery:true,manualReadPendingOutcomeOnly:true,
            manualReadPendingPresentationAllowed:false}:{}),
        });
        if(accepted) nativeAcknowledgements.push(coordinator.recoverHistoryReadingStatus({requestID:posted[index].requestID,
            observationToken:posted[index].manualReadPendingObservationToken}));
        return accepted;
    };
    return {coordinator,posted,controls,timers,request,finish,nativeAcknowledgements};
}

for (const firstSample of ['accepted','still-pending']) {
    test(`sibling recovered commands refresh the actual same-pass runtime after its first sample is ${firstSample}`,async()=>{
        const {webcrypto}=await import('node:crypto');
        await withUUIDCrypto(webcrypto,async()=>{
            const f=fixture();
            try {
                assert.equal(f.publish(10,'E1','0:1',[]),true);
                const aScope=f.runtime.captureScope(f.a),bScope=f.runtime.captureScope(f.a);
                const h=nativeRecoveryHarness(f),a=h.request('page'),b=h.request('mark-all');
                h.coordinator.pause();h.coordinator.resume();
                assert.equal(h.finish(0,11),true);
                assert.equal((await a).success,true);
                assert.equal(f.runtime.state.ready,false);
                assert.equal(f.runtime.isScopeCurrent(aScope,f.a),false);
                assert.equal(f.runtime.isScopeCurrent(bScope,f.a),false,'First recovery revokes every old authoring receipt');
                const firstQuery=f.requests.at(-1);
                if (firstSample==='accepted') assert.equal(f.publish(11,'E1','0:1',['page']),true);
                assert.equal(h.finish(1,12),true);
                assert.equal((await b).success,true);
                if (firstSample==='still-pending') {
                    assert.equal(f.requests.length,2,'Concurrent recovered commands serialize their native samples');
                    assert.equal(f.publish(11,'E1','0:1',['page'],firstQuery),true,'The first sample retains its own acknowledgement');
                }
                assert.equal(await h.nativeAcknowledgements[0],true);
                await new Promise(resolve=>setImmediate(resolve));
                assert.equal(f.requests.length,3,'The later native commit needs its own fresh query despite revoked receipts');
                assert.equal(f.runtime.state.ready,false);
                assert.equal(f.publish(12,'E1','0:1',['page','mark-all']),true);
                assert.equal(await h.nativeAcknowledgements[1],true);
                assert.equal(f.runtime.state.ready,true);
                assert.deepEqual(f.runtime.state.state.readSegmentIdentifiers,['page','mark-all']);
                assert.equal(h.posted.length,2,'Fresh queries never replay native mutations');
                assert.equal(h.coordinator.pendingCount,0);assert.equal(h.timers.size,0);
            } finally { f.runtime.close(); }
        });
    });
}

test('a recovered sibling preserves an ordinary successor until its joined outcome requests fresh state',async()=>{
    const {webcrypto}=await import('node:crypto');
    await withUUIDCrypto(webcrypto,async()=>{
        let h;
        const f=fixture({onInvalidate:()=>h?.coordinator.cancelAll()});
        try {
            assert.equal(f.publish(10),true);
            h=nativeRecoveryHarness(f);
            const a=h.request('page'),b=h.request('mark-all');
            h.coordinator.pause();h.coordinator.resume();
            assert.equal(h.finish(0,11),true);await a;
            assert.equal(f.publish(11),true);
            assert.equal(await h.nativeAcknowledgements[0],true);
            const successor=h.request('independent-page');
            assert.equal(h.finish(1,12),true);await b;
            assert.equal(f.requests.length,2,'Old recovery must not invalidate a live ordinary successor');
            assert.equal(f.runtime.state.ready,true);assert.equal(h.coordinator.pendingCount,1);
            assert.equal(h.controls.length,0,'Recovery must not cancel the newer native command');
            assert.equal(h.finish(2,13,false),true);
            const outcome=await successor;
            await new Promise(resolve=>setImmediate(resolve));
            assert.equal(outcome.success,true);assert.equal(outcome.presentationAllowed,false);
            assert.equal(f.requests.length,3);assert.equal(f.runtime.state.ready,false);
            assert.equal(f.publish(13),true);assert.equal(f.runtime.state.ready,true);
            assert.equal(await h.nativeAcknowledgements[1],true);
            assert.equal(h.controls.length,0);assert.equal(h.posted.length,3);
        } finally { f.runtime.close(); }
    });
});

for (const boundary of ['new-pass','new-account','new-primary-document','new-runtime']) {
    test(`recovered command cannot refresh ${boundary} through an old runtime owner`,async()=>{
        const {webcrypto}=await import('node:crypto');
        await withUUIDCrypto(webcrypto,async()=>{
            const f=fixture();
            try {
                assert.equal(f.publish(10),true);
                const h=nativeRecoveryHarness(f),completion=h.request('old-page');
                h.coordinator.pause();h.coordinator.resume();
                if (boundary==='new-pass' || boundary==='new-account') {
                    f.runtime.state.refresh();
                    assert.equal(f.publish(11,boundary==='new-pass'?'E2':'E1',boundary==='new-account'?'1:1':'0:1'),true);
                } else if (boundary==='new-primary-document') {
                    f.renderer.displayedIndex=1;f.runtime.updateLocation(true);
                } else f.reader.bookReadingRuntime={};
                const queries=f.requests.length;
                assert.equal(h.finish(0,12),true);assert.equal((await completion).success,true);
                assert.equal(f.requests.length,queries,'The original owner must not supersede the replacement sample');
                assert.equal(h.coordinator.pendingCount,0);
            } finally { f.runtime.close(); }
        });
    });
}

test('ordinary publication does not transiently invalidate the active frame',()=>{
    const f=fixture();assert.equal(f.publish(1),true);
    const cleared=f.a.defaultView.clears;
    f.runtime.state.refresh();assert.equal(f.publish(2),true);
    assert.equal(f.a.defaultView.clears,cleared);
    assert.equal(f.a.defaultView.presentations.length,2);
    assert.deepEqual(f.a.defaultView.reads,['read']);
    f.runtime.close();
});
test('chapter movement clears both old tokens and cached frame coverage',()=>{
    const f=fixture();f.publish(1);assert.deepEqual(f.a.defaultView.reads,['read']);
    f.renderer.displayedIndex=1;f.runtime.updateLocation(true);
    assert.equal(f.a.defaultView.manabi_bookReadingScope,null);
    assert.deepEqual(f.a.defaultView.reads,[]);
    assert.equal(f.publish(2),true);
    assert.equal(f.a.defaultView.manabi_bookReadingScope,null);
    assert.deepEqual(f.b.defaultView.reads,['read']);
    f.runtime.close();assert.deepEqual(f.b.defaultView.reads,[]);
});
test('terminal location never leaves hidden chapter coverage active',()=>{
    const f=fixture();f.publish(1);f.runtime.endcap.enter();
    assert.equal(f.runtime.state.location.isEndPage,true);
    assert.equal(f.a.defaultView.manabi_bookReadingScope,null);
    assert.deepEqual(f.a.defaultView.reads,[]);
    assert.equal(f.publish(2),true);
    assert.equal(f.runtime.state.context.scope,null);
    f.runtime.close();
});
test('missing post-commit projection is retryable without repeating the reset',async()=>{
    const f=fixture();const target={accountPresentation:'0:1',action:'startBookOver',articleProgressID:'book',articleEpochID:'E2',
        locationRevision:f.runtime.state.locationRevision};
    assert.deepEqual(await f.runtime.navigate(target),{status:'failed'});
    assert.equal(f.moves.length,0);
    assert.equal(f.publish(1,'E2'),true);
    assert.deepEqual(await f.runtime.navigate(target),{status:'completed'});
    assert.deepEqual(f.moves,[{index:0,anchor:0,bookAction:true}]);
    f.runtime.close();
});
test('generic false at the requested destination cannot complete a committed restart',async()=>{
    const f=fixture();
    try {
        assert.equal(f.publish(1,'E2'),true);
        f.renderer.goTo=async()=>false;
        const target={accountPresentation:'0:1',action:'startBookOver',articleProgressID:'book',articleEpochID:'E2',
            locationRevision:f.runtime.state.locationRevision};
        let completions=0;
        assert.deepEqual(await f.runtime.navigate(target,{onCompleted:()=>{completions++;}}),{status:'failed'});
        assert.equal(completions,0);
    } finally { f.runtime.close(); }
});
test('a moved or replaced reader is superseded rather than navigated again',async()=>{
    const f=fixture();f.publish(1);
    const target={accountPresentation:'0:1',action:'startBookOver',articleProgressID:'book',articleEpochID:'E1',
        locationRevision:f.runtime.state.locationRevision};
    f.runtime.updateLocation(true);
    assert.deepEqual(await f.runtime.navigate(target),{status:'superseded'});
    f.reader.view={};target.locationRevision=f.runtime.state.locationRevision;
    assert.deepEqual(await f.runtime.navigate(target),{status:'superseded'});
    assert.equal(f.moves.length,0);f.runtime.close();
});
test('unsupported action rejected before transport is not an unknown outcome',async()=>{
    const messages=[];
    const bridge=createBookActionBridge({postMessage:p=>messages.push(p),captureContext:()=>({}),
        documentStartedAtMs:1,topWindowURL:'ebook://ebook/load/book.epub'});
    await assert.rejects(bridge.perform('finishChapter'),error=>error.outcomeUnknown!==true);
    assert.deepEqual(messages,[]);assert.equal(bridge.recoveryInfo,null);bridge.close();
});

test('same-URL hidden and detached documents never acquire the displayed scope',()=>{
    const f=fixture();f.b.location.href=f.a.location.href;f.publish(1);
    const detached={location:{href:f.a.location.href},defaultView:{}};
    assert.equal(f.b.defaultView.manabi_bookReadingScope,null);
    assert.equal(f.runtime.captureScope(f.b),null);
    assert.equal(f.runtime.captureScope(detached),null);
    const scope=f.runtime.captureScope(f.a);
    assert.ok(scope);assert.equal(f.runtime.isScopeCurrent(scope,f.a),true);
    assert.equal(f.runtime.isScopeCurrent(scope,detached),false);
    f.runtime.close();
});
test('same-URL document replacement withdraws scope until its own publication',()=>{
    const f=fixture();f.publish(1);const old=f.runtime.captureEvent(f.a);
    const replacement={location:{href:f.a.location.href},defaultView:{}};
    f.renderer.getContents=()=>[{index:0,doc:replacement}];
    assert.equal(f.runtime.captureScope(replacement),null);
    f.runtime.updateLocation(true);
    assert.equal(f.runtime.state.ready,false);assert.equal(f.runtime.isEventCurrent(old),false);
    assert.equal(f.a.defaultView.manabi_bookReadingScope,null);
    f.publish(2);assert.ok(f.runtime.captureEvent(replacement));
    f.runtime.close();
});
test('replaced renderer cannot complete a suspended book restart navigation',async()=>{
    const f=fixture();f.publish(1);let resolve;
    f.renderer.goTo=()=>new Promise(r=>{resolve=r;});
    const target={accountPresentation:'0:1',action:'startBookOver',articleProgressID:'book',articleEpochID:'E1',locationRevision:f.runtime.state.locationRevision};
    const pending=f.runtime.navigate(target);
    f.view.renderer={displayedIndex:1,getContents:()=>[{index:1,doc:f.b}]};
    resolve(true);assert.deepEqual(await pending,{status:'superseded'});f.runtime.close();
});
test('event receipts cannot adopt a successor epoch after a timer or await',()=>{
    const f=fixture();f.publish(1,'E1');const old=f.runtime.captureEvent(f.a);
    assert.equal(f.runtime.isEventCurrent(old),true);
    f.runtime.state.refresh();f.publish(2,'E2');
    assert.equal(f.runtime.isEventCurrent(old),false);
    const fresh=f.runtime.captureEvent(f.a);assert.equal(fresh.scope.articleEpochID,'E2');
    assert.equal(f.runtime.isEventCurrent(fresh),true);f.runtime.close();
});
test('event receipts reject an older page but allow a newly observed same-pass page',()=>{
    const f=fixture();f.publish(1);const old=f.runtime.captureEvent(f.a);
    f.runtime.updateLocation(true);assert.equal(f.runtime.isEventCurrent(old),false);
    assert.equal(f.runtime.isEventCurrent(f.runtime.captureEvent(f.a)),true);f.runtime.close();
});
test('unadmitted initial work stays unadmitted and fresh work succeeds after publication',()=>{
    const f=fixture();const old=f.runtime.captureEvent(f.a);assert.equal(old,null);
    f.publish(1);assert.equal(f.runtime.isEventCurrent(old),false);
    assert.equal(f.runtime.isEventCurrent(f.runtime.captureEvent(f.a)),true);f.runtime.close();
});

test('pending publication cannot grant a scope to a same-URL replacement before relocation',()=>{
    const f=fixture();f.publish(1);f.runtime.state.refresh();
    const oldRequest=f.requests.at(-1);
    const cloneDoc={location:{href:f.a.location.href},defaultView:{presentations:[],
        manabi_applyBookReadingPresentation(p){this.presentations.push(p);}}};
    f.renderer.getContents=()=>[{index:0,doc:cloneDoc}];
    assert.equal(f.publish(2),false);
    assert.equal(f.runtime.state.ready,false);
    assert.equal(f.runtime.captureScope(cloneDoc),null);
    assert.equal(cloneDoc.defaultView.manabi_bookReadingScope,undefined);
    assert.throws(()=>f.runtime.state.captureContext());
    f.runtime.updateLocation();assert.equal(f.publish(3),true);
    assert.ok(f.runtime.captureScope(cloneDoc));
    assert.notEqual(f.requests.at(-1).requestID,oldRequest.requestID);
    f.runtime.close();
});
test('closing an end-page reader cannot publish a false return-to-chapter event',()=>{
    const f=fixture();f.publish(1);f.runtime.endcap.enter();f.publish(2);
    const count=f.requests.length;
    f.runtime.close();
    assert.equal(f.requests.length,count);
    assert.equal(f.runtime.state.ready,false);
    assert.equal(f.runtime.captureScope(f.a),null);
    f.runtime.close();assert.equal(f.requests.length,count);
});



test('same-document account signal withdraws scopes and requests a fresh book binding',()=>{
    const f=fixture();assert.equal(f.publish(1,'E1','1:1'),true)
    const oldEvent=f.runtime.captureEvent(f.a),oldScope=f.runtime.captureScope(f.a),before=f.requests.length
    assert.equal(f.runtime.accountDidChange('2:0'),true)
    assert.equal(f.requests.length,before+1);assert.equal(f.runtime.state.ready,false)
    assert.equal(f.a.defaultView.manabi_bookReadingScope,null)
    assert.equal(f.publish(2,'E1','2:1'),true)
    assert.equal(f.runtime.isEventCurrent(oldEvent),false)
    assert.equal(f.runtime.isScopeCurrent(oldScope,f.a),false,'Same book/pass IDs must not reacquire another account')
    assert.equal(f.runtime.isEventCurrent(f.runtime.captureEvent(f.a)),true)
    const count=f.requests.length
    assert.equal(f.runtime.accountDidChange('2:0'),false)
    assert.equal(f.runtime.accountDidChange('1:1'),false)
    assert.equal(f.requests.length,count);assert.equal(f.runtime.state.ready,true)
    f.runtime.close()
})


test('account change during awaited restart navigation cannot acknowledge successor movement',async()=>{
    const f=fixture();f.publish(1,'E1','1:1');let resolve
    f.renderer.goTo=()=>new Promise(r=>{resolve=r})
    const target={accountPresentation:'1:1',action:'startBookOver',articleProgressID:'book',
        articleEpochID:'E1',locationRevision:f.runtime.state.locationRevision}
    const pending=f.runtime.navigate(target)
    f.runtime.accountDidChange('2:1');f.publish(2,'E1','2:1')
    resolve(true);assert.deepEqual(await pending,{status:'superseded'})
    // The already-started physical scroll is not rollback-capable. A delayed
    // old delivery, however, must not start another navigation or resume native work.
    let calls=0;f.renderer.goTo=async()=>{calls++;return true}
    assert.deepEqual(await f.runtime.navigate(target),{status:'superseded'})
    assert.equal(calls,0);f.runtime.close()
})

// A failed read-only refresh retires event ownership without changing native
// pass IDs. Recovery can restore equal values but may not resurrect the event.
const failCurrentRefresh = f => {
    f.runtime.state.refresh();
    assert.equal(f.runtime.state.apply(f.requests.at(-1).requestID, {
        ok: false, accountPresentation: f.runtime.state.accountPresentation,
    }), false);
};

test('same-scope recovery never revives an event captured before invalidation', t => {
    const f = fixture(); t.after(() => f.runtime.close());
    assert.equal(f.publish(1), true);
    const event = f.runtime.captureEvent(f.a);
    const scope = f.runtime.captureScope(f.a);
    const locationRevision = f.runtime.state.locationRevision;
    failCurrentRefresh(f);
    assert.equal(f.runtime.isEventCurrent(event), false);
    f.runtime.state.refresh();
    assert.equal(f.publish(2), true);
    assert.equal(f.runtime.state.locationRevision, locationRevision);
    assert.equal(f.runtime.isEventCurrent(event), false);
    assert.equal(f.runtime.isScopeCurrent(scope, f.a), false);
    assert.equal(f.runtime.isEventCurrent(f.runtime.captureEvent(f.a)), true);
});

test('same-scope successful refresh preserves a captured event without invalidation', t => {
    const f = fixture(); t.after(() => f.runtime.close());
    assert.equal(f.publish(1), true);
    const event = f.runtime.captureEvent(f.a);
    f.runtime.state.refresh();
    assert.equal(f.publish(2), true);
    assert.equal(f.runtime.isEventCurrent(event), true);
});

test('each failed refresh permanently retires only its earlier scope receipts', t => {
    const f = fixture(); t.after(() => f.runtime.close());
    assert.equal(f.publish(1), true);
    const retired = [];
    for (let revision = 2; revision <= 5; ++revision) {
        retired.push(f.runtime.captureEvent(f.a));
        failCurrentRefresh(f);
        f.runtime.state.refresh();
        assert.equal(f.publish(revision), true);
        for (const event of retired) assert.equal(f.runtime.isEventCurrent(event), false);
        assert.equal(f.runtime.isEventCurrent(f.runtime.captureEvent(f.a)), true);
    }
});

test('scope receipts are retired before a frame invalidation callback reenters recovery', t => {
    const f = fixture(); t.after(() => f.runtime.close());
    assert.equal(f.publish(1), true);
    const old = f.runtime.captureEvent(f.a);
    const clear = f.a.defaultView.manabi_invalidateBookReadingScope;
    let afterRecovery;
    f.a.defaultView.manabi_invalidateBookReadingScope = () => {
        clear();
        f.a.defaultView.manabi_invalidateBookReadingScope = clear;
        f.runtime.state.refresh();
        assert.equal(f.publish(2), true);
        afterRecovery = f.runtime.isEventCurrent(old);
    };
    failCurrentRefresh(f);
    assert.equal(afterRecovery, false);
    assert.equal(f.runtime.isEventCurrent(f.runtime.captureEvent(f.a)), true);
});

test('reentrant frame publication cannot paint the old finished state over its successor', t => {
    const f = fixture(); t.after(() => f.runtime.close());
    const apply = f.a.defaultView.manabi_applyBookReadingPresentation;
    f.a.defaultView.manabi_applyBookReadingPresentation = projection => {
        apply(projection);
        f.a.defaultView.manabi_applyBookReadingPresentation = apply;
        const state = { ...f.runtime.state.state, revision: 2, finished: true };
        const context = { ...f.runtime.state.context, contextID: 'successor' };
        f.runtime.state.refresh();
        assert.equal(f.runtime.state.apply(f.requests.at(-1).requestID, {
            ok: true, accountPresentation: '0:1', state, context,
        }), true);
    };
    assert.equal(f.publish(1), false);
    assert.equal(f.runtime.endcap.finished, true);
    assert.deepEqual(f.projections.map(value => value.revision), [2]);
});

test('closing during frame publication prevents later shell projection effects', () => {
    const f = fixture();
    f.a.defaultView.manabi_applyBookReadingPresentation = () => f.runtime.close();
    assert.equal(f.publish(1), false);
    assert.deepEqual(f.projections, []);
    assert.equal(f.runtime.state.ready, false);
});

test('an old invalidation cannot disable a reentrantly recovered end page', t => {
    const f = fixture(); t.after(() => f.runtime.close());
    f.runtime.endcap.enter();
    assert.equal(f.publish(1), true);
    assert.equal(f.runtime.endcap.button.disabled, false);
    const clear = f.a.defaultView.manabi_invalidateBookReadingScope;
    f.a.defaultView.manabi_invalidateBookReadingScope = () => {
        clear();
        f.a.defaultView.manabi_invalidateBookReadingScope = clear;
        f.runtime.state.refresh();
        assert.equal(f.publish(2), true);
    };
    failCurrentRefresh(f);
    assert.equal(f.runtime.state.ready, true);
    assert.equal(f.runtime.endcap.button.disabled, false);
});

// Keep the actual runtime and its receipt fences; only the host's Crypto API
// capability and renderer completion are controlled by this fixture.
async function withUUIDCrypto(crypto, body) {
    const descriptor = Object.getOwnPropertyDescriptor(globalThis, 'crypto');
    Object.defineProperty(globalThis, 'crypto', {configurable:true,value:crypto});
    try { await body(); } finally {
        if (descriptor) Object.defineProperty(globalThis, 'crypto', descriptor);
        else delete globalThis.crypto;
    }
}
test('portable relocation UUID keeps completed position receipt fenced', async()=>{
    const {webcrypto} = await import('node:crypto');
    await withUUIDCrypto({getRandomValues:bytes=>webcrypto.getRandomValues(bytes)}, async()=>{
        const f=fixture();
        try {
            assert.equal(f.publish(1),true);
            let receipt=null, relocationID=null;
            f.renderer.goTo=async (target, options)=>{
                relocationID=options.relocationID;
                f.moves.push(target);f.renderer.displayedIndex=target.index;
                f.view.lastLocation={relocationID};return true;
            };
            const target={accountPresentation:'0:1',action:'startBookOver',articleProgressID:'book',articleEpochID:'E1',
                locationRevision:f.runtime.state.locationRevision};
            assert.deepEqual(await f.runtime.navigate(target,{onCompleted:check=>{receipt=check;}}),{status:'completed'});
            assert.match(relocationID,/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
            assert.equal(receipt(),true);
            f.view.lastLocation={relocationID};
            assert.equal(receipt(),false,'Equal UUID cannot adopt a replaced location');
        } finally { f.runtime.close(); }
    });
});
for (const [name,crypto] of [['missing entropy',{}],['throwing entropy',{getRandomValues(){throw new Error('entropy failure');}}]]) {
    test('relocation '+name+' cannot move or issue a position receipt',async()=>{
        const {webcrypto}=await import('node:crypto');
        await withUUIDCrypto(webcrypto,async()=>{
            const f=fixture();
            try {
                assert.equal(f.publish(1),true);
                const target={accountPresentation:'0:1',action:'startBookOver',articleProgressID:'book',articleEpochID:'E1',
                    locationRevision:f.runtime.state.locationRevision};
                let completions=0;
                await withUUIDCrypto(crypto,async()=>{
                    await assert.rejects(f.runtime.navigate(target,{onCompleted:()=>{completions++;}}));
                });
                assert.equal(completions,0);assert.deepEqual(f.moves,[]);
                assert.equal(f.runtime.state.ready,true);
            } finally { f.runtime.close(); }
        });
    });
}
