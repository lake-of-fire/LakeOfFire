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
