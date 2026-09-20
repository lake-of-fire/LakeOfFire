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
    const publish=(revision,parent='E1')=>{
        const request=requests.at(-1), end=request.isEndPage;
        const location=renderer.displayedIndex===0?'a.xhtml':'b.xhtml';
        const scope=end?null:{articleProgressID:'book',articleEpochID:parent,
            chapterKey:(renderer.displayedIndex===0?'a':'b').repeat(64),chapterEpochID:null};
        return runtime.state.apply(request.requestID,{ok:true,
            state:{revision,articleProgressID:'book',articleEpochID:parent,scope,finished:false,
                bookReadPresence:'present',chapterReadPresence:end?'empty':'present',
                readSegmentIdentifiers:end?[]:['read'],sentenceIdentifiersRead:[]},
            context:{contextID:`context-${revision}`,articleProgressID:'book',articleEpochID:parent,
                scope,sectionLocation:end?null:location,isEndPage:end},
        });
    };
    runtime.updateLocation();
    return {runtime,reader,view,renderer,a,b,moves,requests,publish};
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
    const f=fixture();const target={action:'startBookOver',articleProgressID:'book',articleEpochID:'E2',
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
    const target={action:'startBookOver',articleProgressID:'book',articleEpochID:'E1',
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
