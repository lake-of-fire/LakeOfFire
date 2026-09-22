import assert from 'node:assert/strict'
import test from 'node:test'
import { BookEndcap, createBookActionBridge, endcapNavigationResult } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/book-endcap.js'
import { pageTurnMovementDisposition } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/page-turn-coordination.js'
class Element extends EventTarget {
    attributes = new Map()
    children = []
    classes = new Set()
    classList = {add:x=>this.classes.add(x),remove:x=>this.classes.delete(x)}
    isConnected = true
    inert = false
    hidden = false
    textContent = ''
    append(x) { this.children.push(x) }
    setAttribute(k,v) { this.attributes.set(k,v) }
    getAttribute(k) { return this.attributes.get(k) ?? null }
    removeAttribute(k) { this.attributes.delete(k) }
    querySelector(k) { this.nodes ??= new Map(); if(!this.nodes.has(k))this.nodes.set(k,new Element()); return this.nodes.get(k) }
    focus() { this.focused = true }
    remove() { this.isConnected = false }
}
const fixture = (performAction = async()=>({ok:true,finished:true})) => {
    const document={createElement:()=>new Element(),activeElement:new Element()}
    const host=new Element(), publication=new Element(), changes=[]
    const cap=new BookEndcap({document,host,publication,performAction,onChange:v=>changes.push(v)})
    cap.setReady(true)
    return {cap,host,publication,document,changes}
}
const deferred = ()=>{let resolve,reject;const promise=new Promise((r,j)=>{resolve=r;reject=j});return{promise,resolve,reject}}
test('enter/leave preserves the publication node and restores accessibility and focus',()=>{
    const {cap,publication,document,changes}=fixture()
    publication.setAttribute('aria-hidden','false')
    assert.equal(cap.enter(),true);assert.equal(cap.enter(),false)
    assert.equal(publication.inert,true)
    assert.equal(publication.getAttribute('aria-hidden'),'true')
    assert.equal(cap.heading.focused,true)
    assert.equal(cap.leave(),true);assert.equal(cap.leave(),false)
    assert.equal(publication.getAttribute('aria-hidden'),'false')
    assert.equal(publication.inert,false)
    assert.equal(document.activeElement.focused,true)
    assert.deepEqual(changes,[true,false])
})
test('enter and navigation alone never dispatch Finish',()=>{
    const calls=[];const {cap}=fixture(x=>calls.push(x))
    cap.enter();cap.leave();cap.enter();cap.destroy()
    assert.deepEqual(calls,[])
})
test('Finished appears only after acknowledgement and never calls mark-all',async()=>{
    const pending=deferred(),calls=[];const {cap}=fixture(action=>{calls.push(action);return pending.promise})
    cap.enter();const first=cap.activate()
    assert.equal(cap.finished,false);assert.equal(cap.busy,true)
    assert.equal(cap.button.textContent,'Finish Book')
    assert.equal(await cap.activate(),false)
    assert.deepEqual(calls,['finishBook'])
    cap.setFinished(true);pending.resolve({ok:true,committed:true,finished:true});assert.equal(await first,true)
    assert.equal(cap.heading.textContent,'Finished');assert.equal(cap.button.textContent,'Start Book Over')
})
test('failure does not finish or navigate and a new explicit retry can succeed',async()=>{
    let calls=0;const {cap}=fixture(async()=>{if(!calls++)throw Error('journal failure');return{ok:true,finished:true}})
    cap.enter();assert.equal(await cap.activate(),false)
    assert.equal(cap.visible,true);assert.equal(cap.finished,false);assert.equal(cap.busy,false)
    assert.equal(cap.error.textContent,'journal failure')
    assert.equal(await cap.activate(),true);assert.equal(cap.finished,false);cap.setFinished(true);assert.equal(cap.finished,true)
})
test('negative acknowledgement is failure, never optimistic success',async()=>{
    const {cap}=fixture(async()=>({ok:false,error:'stale chapter'}));cap.enter()
    assert.equal(await cap.activate(),false);assert.equal(cap.finished,false)
})
test('start over leaves the endcap only after native success',async()=>{
    const pending=deferred(),calls=[];const {cap}=fixture(action=>{calls.push(action);return pending.promise})
    cap.setFinished(true);cap.enter();const task=cap.activate()
    assert.equal(cap.visible,true);assert.deepEqual(calls,['startBookOver'])
    cap.setFinished(false);cap.leave();pending.resolve({ok:true,committed:true,finished:false});await task
    assert.equal(cap.visible,false);assert.equal(cap.finished,false)
})
test('failure to start over leaves finished state intact',async()=>{
    const {cap}=fixture(async()=>{throw Error('write failed')});cap.setFinished(true);cap.enter()
    await cap.activate();assert.equal(cap.visible,true);assert.equal(cap.finished,true)
})
test('late acknowledgement after destroy cannot revive or update the old endcap',async()=>{
    const pending=deferred();const {cap}=fixture(()=>pending.promise)
    cap.enter();const task=cap.activate();cap.destroy();pending.resolve({ok:true,finished:true})
    assert.equal(await task,false);assert.equal(cap.visible,false);assert.equal(cap.finished,false)
    assert.equal(cap.enter(),false)
})
test('navigation away during a write never reopens the endcap',async()=>{
    const pending=deferred();const {cap}=fixture(()=>pending.promise)
    cap.enter();const task=cap.activate();cap.leave();pending.resolve({ok:true,finished:true});await task
    assert.equal(cap.visible,false);assert.equal(cap.finished,false)
})
test('preexisting inert state survives endcap navigation',()=>{
    const {cap,publication}=fixture();publication.inert=true
    cap.enter();cap.leave();assert.equal(publication.inert,true)
})
test('endcap movement is not physical page/read evidence',()=>{
    assert.equal(pageTurnMovementDisposition(endcapNavigationResult()),'no-move')
})

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
