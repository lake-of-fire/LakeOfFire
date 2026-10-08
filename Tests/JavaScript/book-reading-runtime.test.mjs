import assert from 'node:assert/strict';
import test from 'node:test';
import { installBookReadingRuntime } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/book-reading-runtime.js';
import { createBookActionBridge } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/book-action-bridge.js';

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
function fixture() {
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
        applyProjection:p=>projections.push(p),invalidateProjection:()=>{},onVisibility:()=>{}});
    const publish=(revision,parent='E1',accountPresentation='0:1')=>{
        const request=requests.at(-1), end=request.isEndPage;
        const location=renderer.displayedIndex===0?'a.xhtml':'b.xhtml';
        const scope=end?null:{articleProgressID:'book',articleEpochID:parent,
            chapterKey:(renderer.displayedIndex===0?'a':'b').repeat(64),chapterEpochID:null};
        return runtime.state.apply(request.requestID,{ok:true,accountPresentation,
            state:{revision,articleProgressID:'book',articleEpochID:parent,scope,finished:false,
                bookReadPresence:'present',chapterReadPresence:end?'empty':'present',
                readSegmentIdentifiers:end?[]:['read'],sentenceIdentifiersRead:[]},
            context:{contextID:`context-${revision}`,articleProgressID:'book',articleEpochID:parent,
                scope,sectionLocation:end?null:location,isEndPage:end},
        });
    };
    runtime.updateLocation();
    return {runtime,reader,view,renderer,a,b,moves,requests,publish,projections};
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
