import assert from 'node:assert/strict'
import test from 'node:test'
import { createBookActionBridge } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/book-action-bridge.js'
const make=()=>{
 const messages=[],timers=new Map();let n=0
 const context={contextID:'native',articleEpochID:'E1',scope:{chapterEpochID:null},locationRevision:1}
 const bridge=createBookActionBridge({postMessage:x=>messages.push(x),documentStartedAtMs:1,topWindowURL:'ebook://book',captureContext:()=>context,
 makeRequestID:()=>`00000000-0000-4000-8000-${String(++n).padStart(12,'0')}`,setTimer:fn=>{timers.set(n,fn);return n},clearTimer:id=>timers.delete(id)})
 // Successful reset completion includes navigation. Commit-only replies are
 // exercised as pending by book-action-recovery.test.mjs, never guessed done.
 const ack=(m,extra={})=>bridge.acknowledge(m.deliveryID,{requestID:m.requestID,ok:true,committed:true,
   ...(m.action==='finishBook'?{}:{navigation:{status:'completed'}}),...extra})
 return{bridge,messages,timers,context,ack}
}
test('action captures immutable epoch context without read-all subjects',async()=>{
 const {bridge,messages,context,ack}=make();const p=bridge.perform('startChapterOver');context.scope.chapterEpochID='new'
 assert.equal(messages[0].context.scope.chapterEpochID,null)
 assert.equal(messages[0].stableSegmentIDs,undefined);assert.equal(messages[0].kind,'command')
 ack(messages[0]);assert.equal((await p).navigation.status,'completed')
 assert.equal(bridge.recoveryInfo,null)
})
test('timeout and Check Status never issue a second epoch command',async()=>{
 const {bridge,messages,timers,ack}=make();const p=bridge.perform('startBookOver');const rejected=assert.rejects(p,e=>e.outcomeUnknown)
 timers.values().next().value();await rejected
 await assert.rejects(bridge.perform('startBookOver'))
 const recovery=bridge.recoveryInfo;const check=bridge.recover(recovery)
 assert.equal(messages.length,2);assert.equal(messages[1].kind,'status');assert.equal(messages[1].requestID,messages[0].requestID)
 ack(messages[0]);assert.equal((await check).committed,true)
 assert.equal((await bridge.recover(recovery)).navigation.status,'completed')
 assert.equal(messages.length,2)
})
test('navigation failure has navigation-only recovery',async()=>{
 const {bridge,messages,ack}=make();const p=bridge.perform('startBookOver')
 ack(messages[0],{navigation:{status:'failed'}});await p
 const nav=bridge.recover(bridge.recoveryInfo)
 assert.equal(messages[1].kind,'navigate');assert.equal(messages[1].requestID,messages[0].requestID)
 ack(messages[1],{navigation:{status:'completed'}});assert.equal((await nav).navigation.status,'completed')
 assert.equal(bridge.recoveryInfo,null)
})
test('pending status retains original operation',async()=>{
 const {bridge,messages,ack}=make();const p=bridge.perform('finishBook')
 bridge.acknowledge(messages[0].deliveryID,{requestID:messages[0].requestID,pending:true});await p
 assert.equal(bridge.recoveryInfo.kind,'status')
 const status=bridge.recover(bridge.recoveryInfo);ack(messages[1]);await status
})
test('failed commit permits a new deliberate action but cannot navigate',async()=>{
 const {bridge,messages}=make();const p=bridge.perform('finishBook')
 bridge.acknowledge(messages[0].deliveryID,{requestID:messages[0].requestID,ok:false,error:'failed'});await p
 assert.equal(bridge.recoveryInfo,null)
 await assert.rejects(bridge.recover({requestID:messages[0].requestID,action:'finishBook',kind:'navigate'}))
})
test('wrong, duplicate and malformed acknowledgements do not consume the request',async()=>{
 const {bridge,messages,ack}=make();const p=bridge.perform('finishBook');const m=messages[0]
 assert.equal(bridge.acknowledge(m.deliveryID,{requestID:'other',ok:true,committed:true}),false)
 assert.equal(bridge.acknowledge(m.deliveryID,{requestID:m.requestID,ok:true}),false)
 assert.equal(ack(m),true);await p;assert.equal(ack(m),false)
})
test('closing rejects pending delivery and cannot be reused',async()=>{
 const {bridge,messages,ack}=make();const p=bridge.perform('finishBook');const rejection=assert.rejects(p,/closed/)
 bridge.close();await rejection;assert.equal(ack(messages[0]),false);await assert.rejects(bridge.perform('finishBook'),/closed/)
})
test('Unmark and Finish Chapter are not book actions',async()=>{
 const {bridge,messages}=make()
 for (const action of ['unmark','markAllSectionsAsRead','finishChapter'])await assert.rejects(bridge.perform(action))
 assert.deepEqual(messages,[])
})
test('command preserves its original producer while recovery uses fresh non-mutating ownership',async()=>{
 const messages=[],timers=new Map();let timer=0,capture=0
 const bridge=createBookActionBridge({postMessage:x=>messages.push(x),documentStartedAtMs:1,
  topWindowURL:'ebook://book',captureContext:()=>({contextID:'ctx',locationRevision:1}),
  makeRequestID:()=> '22222222-2222-4222-8222-222222222222',
  captureProducerOwner:()=>Object.freeze({token:`P${++capture}`}),
  carryProducerOwner:(message,owner)=>({...message,readerArticleProducer:{token:owner.token}}),
  setTimer:fn=>{timers.set(++timer,fn);return timer},clearTimer:id=>timers.delete(id)})
 const command=bridge.perform('startBookOver')
 assert.equal(messages[0].readerArticleProducer.token,'P1')
 ;[...timers.values()][0]()
 await assert.rejects(command,error=>error.outcomeUnknown===true)
 const status=bridge.recover()
 assert.equal(messages[1].kind,'status')
 assert.equal(messages[1].readerArticleProducer.token,'P2')
 assert.equal(messages[0].readerArticleProducer.token,'P1')
 bridge.acknowledge(messages[1].deliveryID,{requestID:messages[1].requestID,ok:false,error:'stale'})
 await status
})



const accountFixture = () => {
    const messages = [], timers = new Map(); let n = 0, timer = 0
    const bridge = createBookActionBridge({postMessage:r=>messages.push(r),documentStartedAtMs:1,
        topWindowURL:'ebook://book',captureContext:()=>({contextID:'context',locationRevision:1}),
        makeRequestID:()=>`00000000-0000-4000-8000-${String(++n).padStart(12,'0')}`,
        captureProducerOwner:()=>({token:`P${n}`}),carryProducerOwner:(body,owner)=>({...body,readerArticleProducer:owner}),
        setTimer:fn=>{timers.set(++timer,fn);return timer},clearTimer:id=>timers.delete(id)})
    const ack=(message,accountPresentation,extra={})=>bridge.acknowledge(message.deliveryID,
        {requestID:message.requestID,accountPresentation,ok:true,committed:true,...extra})
    return {bridge,messages,timers,ack}
}
test('account replacement releases old pending presentation as unknown and permits a fresh action', async () => {
    const f=accountFixture();f.bridge.setAccountPresentation('1:1')
    const old=f.bridge.perform('finishBook'), oldMessage=f.messages[0]
    const rejected=assert.rejects(old,e=>e.outcomeUnknown===true&&e.presentationSuperseded===true)
    assert.equal(f.bridge.setAccountPresentation('2:1'),true);await rejected
    assert.equal(f.bridge.recoveryInfo,null);assert.equal(f.timers.size,0)
    assert.equal(f.messages.length,1,'Account replacement must not replay a mutation')
    assert.equal(f.ack(oldMessage,'1:1'),false)
    const fresh=f.bridge.perform('finishBook'), freshMessage=f.messages.at(-1)
    assert.equal(f.ack(freshMessage,undefined),false,'An unstamped reply cannot settle a stamped action')
    assert.equal(f.ack(freshMessage,'2:1'),true);assert.equal((await fresh).committed,true)
})
test('cached committed outcome cannot be recovered under a successor account', async () => {
    const f=accountFixture();f.bridge.setAccountPresentation('1:1')
    const first=f.bridge.perform('finishBook'), message=f.messages[0]
    f.ack(message,'1:1');assert.equal((await first).committed,true)
    const recovery={requestID:message.requestID,action:'finishBook',kind:'status'}
    assert.equal((await f.bridge.recover(recovery)).committed,true)
    assert.equal(f.messages.length,1)
    f.bridge.setAccountPresentation('2:1')
    await assert.rejects(f.bridge.recover(recovery),e=>e.outcomeUnknown===true)
    assert.equal(f.messages.length,1,'Cached recovery must not become a successor-account command')
})
test('delayed invalidation cannot clear a newer pending command even beyond Number precision', async () => {
    const f=accountFixture();f.bridge.setAccountPresentation('9007199254740993:1')
    const pending=f.bridge.perform('finishBook'), message=f.messages[0]
    assert.equal(f.bridge.setAccountPresentation('9007199254740992:1'),false)
    assert.equal(f.bridge.setAccountPresentation('9007199254740993:0'),false)
    assert.equal(f.bridge.recoveryInfo.requestID,message.requestID)
    assert.equal(f.ack(message,'9007199254740992:1'),false)
    assert.equal(f.ack(message,'9007199254740993:1'),true);assert.equal((await pending).ok,true)
})
test('same-account publication preserves committed navigation-only recovery', async () => {
    const f=accountFixture();f.bridge.setAccountPresentation('7:1')
    const first=f.bridge.perform('startBookOver'), message=f.messages[0]
    f.ack(message,'7:1',{navigation:{status:'failed'}});await first
    assert.equal(f.bridge.setAccountPresentation('7:1'),false)
    const recovery=f.bridge.recover();assert.equal(f.messages.at(-1).kind,'navigate')
    f.ack(f.messages.at(-1),'7:1',{navigation:{status:'completed'}})
    assert.equal((await recovery).navigation.status,'completed')
    assert.deepEqual(f.messages.map(x=>x.kind),['command','navigate'])
})
