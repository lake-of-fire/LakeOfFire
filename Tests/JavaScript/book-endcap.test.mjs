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
    pending.resolve({ok:true,finished:true});assert.equal(await first,true)
    assert.equal(cap.heading.textContent,'Finished');assert.equal(cap.button.textContent,'Start Book Over')
})
test('failure does not finish or navigate and a new explicit retry can succeed',async()=>{
    let calls=0;const {cap}=fixture(async()=>{if(!calls++)throw Error('journal failure');return{ok:true,finished:true}})
    cap.enter();assert.equal(await cap.activate(),false)
    assert.equal(cap.visible,true);assert.equal(cap.finished,false);assert.equal(cap.busy,false)
    assert.equal(cap.error.textContent,'journal failure')
    assert.equal(await cap.activate(),true);assert.equal(cap.finished,true)
})
test('negative acknowledgement is failure, never optimistic success',async()=>{
    const {cap}=fixture(async()=>({ok:false,error:'stale chapter'}));cap.enter()
    assert.equal(await cap.activate(),false);assert.equal(cap.finished,false)
})
test('start over leaves the endcap only after native success',async()=>{
    const pending=deferred(),calls=[];const {cap}=fixture(action=>{calls.push(action);return pending.promise})
    cap.setFinished(true);cap.enter();const task=cap.activate()
    assert.equal(cap.visible,true);assert.deepEqual(calls,['startBookOver'])
    pending.resolve({ok:true,finished:false});await task
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
    assert.equal(cap.visible,false);assert.equal(cap.finished,true)
})
test('preexisting inert state survives endcap navigation',()=>{
    const {cap,publication}=fixture();publication.inert=true
    cap.enter();cap.leave();assert.equal(publication.inert,true)
})
test('endcap movement is not physical page/read evidence',()=>{
    assert.equal(pageTurnMovementDisposition(endcapNavigationResult()),'no-move')
})
test('bridge only posts explicit book actions, without read subjects',async()=>{
    const messages=[];const bridge=createBookActionBridge({postMessage:x=>messages.push(x),documentStartedAtMs:1,topWindowURL:'ebook://book/a'})
    const task=bridge.perform('finishBook');const message=messages[0]
    assert.deepEqual(Object.keys(message).sort(),['action','documentStartedAtMs','requestID','topWindowURL'])
    assert.equal(message.action,'finishBook');assert.equal(bridge.acknowledge('wrong',{}),false)
    assert.equal(bridge.acknowledge(message.requestID,{ok:true,finished:true}),true)
    assert.equal((await task).finished,true)
    assert.equal(bridge.acknowledge(message.requestID,{}),false)
    await assert.rejects(bridge.perform('markAllSectionsAsRead'))
})
test('closed bridge rejects pending commands and cannot be reused',async()=>{
    const bridge=createBookActionBridge({postMessage(){},documentStartedAtMs:1,topWindowURL:'ebook://book/a'})
    const task=bridge.perform('startBookOver');const rejection=assert.rejects(task,/closed/)
    bridge.close();await rejection;await assert.rejects(bridge.perform('finishBook'),/closed/)
})
test('postMessage failure clears the pending command',async()=>{
    let request;const bridge=createBookActionBridge({postMessage:x=>{request=x;throw Error('unavailable')},documentStartedAtMs:1,topWindowURL:'ebook://book/a'})
    await assert.rejects(bridge.perform('finishBook'),/unavailable/)
    assert.equal(bridge.acknowledge(request.requestID,{ok:true}),false)
})
