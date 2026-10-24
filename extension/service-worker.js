// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 B1s9l
const HOST="com.deskriptions.bridge",PROTOCOL=1,STATE_VERSION=1;
let port,connecting=false,reconnectAttempt=0,installationIDPromise; const sessionID=crypto.randomUUID(),cancelled=new Set();
async function installationID(){if(!installationIDPromise)installationIDPromise=(async()=>{const s=await chrome.storage.local.get("installationID");if(s.installationID)return s.installationID;const id=crypto.randomUUID();await chrome.storage.local.set({installationID:id});return id})();return installationIDPromise}
const faviconCache=new Map(),faviconPending=new Map(),MAX_FAVICON_BYTES=65536;
function delay(ms){return new Promise(resolve=>setTimeout(resolve,ms))}
function cacheFavicon(key,value){
  faviconCache.set(key,value);
  while(faviconCache.size>1000)faviconCache.delete(faviconCache.keys().next().value);
  return value;
}
async function blobDataURL(blob){
  const mime=blob.type||"image/png";
  if(!blob.size||blob.size>MAX_FAVICON_BYTES||!mime.startsWith("image/"))return null;
  const bytes=new Uint8Array(await blob.arrayBuffer());let binary="";
  for(let i=0;i<bytes.length;i+=8192)binary+=String.fromCharCode(...bytes.subarray(i,i+8192));
  return `data:${mime};base64,${btoa(binary)}`;
}
async function loadFavicon(page,tabFavicon){
  if(tabFavicon?.startsWith("data:image/")&&tabFavicon.includes(";base64,")&&tabFavicon.length<=MAX_FAVICON_BYTES*2)return tabFavicon;
  const faviconURL=chrome.runtime.getURL(`/_favicon/?pageUrl=${encodeURIComponent(page)}&size=32`);
  for(const wait of[0,200,600]){
    if(wait)await delay(wait);
    try{const response=await fetch(faviconURL,{cache:"no-store"});if(!response.ok)continue;const value=await blobDataURL(await response.blob());if(value)return value}catch{}
  }
  return null;
}
async function faviconData(t){
  const page=t.url??t.pendingUrl??"",key=`${t.id}:${page}`;
  if(!page||page.startsWith("chrome://")||page.startsWith("chrome-extension://"))return null;
  if(faviconCache.has(key))return faviconCache.get(key);
  if(faviconPending.has(key))return faviconPending.get(key);
  const pending=loadFavicon(page,t.favIconUrl).then(value=>value?cacheFavicon(key,value):null).finally(()=>faviconPending.delete(key));
  faviconPending.set(key,pending);return pending;
}
async function inventory(){const windows=await chrome.windows.getAll({populate:true,windowTypes:["normal"]});return Promise.all(windows.map(async w=>({extensionWindowID:w.id,sessionID:w.sessionId??null,focused:w.focused,state:w.state,bounds:{x:w.left??0,y:w.top??0,width:w.width??0,height:w.height??0},tabs:await Promise.all((w.tabs??[]).map(async t=>({id:t.id,title:t.title??"",url:t.url??t.pendingUrl??"",active:t.active,pinned:t.pinned,index:t.index,faviconDataURL:await faviconData(t)})))})))}
// The extension deliberately does not claim which Chromium product hosts it.
// The browser-specific native host registration overwrites this value with a
// verified bundle identity before the app sees the message.
async function envelope(type,extra={}){return{type,protocolVersion:PROTOCOL,savedStateVersion:STATE_VERSION,adapterVersion:chrome.runtime.getManifest().version,installationID:await installationID(),sessionID,browser:"unverified",capabilities:["inventory.windows","inventory.tabs","inventory.fresh","inventory.favicons.data-v1","close.selected.v1","restore.reconciled.v1","restore.startup-window.v1","cancel.v1"],...extra}}
async function sendInventory(reason="change",requestID){if(port)port.postMessage(await envelope("inventory",{requestID,reason,windows:await inventory()}))}
function result(r,status,extra={}){port?.postMessage({type:`${r.type}Result`,protocolVersion:PROTOCOL,requestID:r.requestID,operationID:r.operationID,status,...extra})}
async function operationRecord(id){return(await chrome.storage.local.get(`operation:${id}`))[`operation:${id}`]}
async function saveOperation(id,value){await chrome.storage.local.set({[`operation:${id}`]:value})}
async function closeSelected(r){const prior=await operationRecord(r.operationID);if(prior){port?.postMessage({...prior,requestID:r.requestID});return}const targets=r.payload?.targets??[],allWindows=await chrome.windows.getAll({windowTypes:["normal"]}),targetWindowIDs=new Set(targets.filter(t=>t.closeWholeWindow&&t.nativeAssociationVerified).map(t=>t.windowID));let holder;if(allWindows.length>0&&allWindows.every(w=>targetWindowIDs.has(w.id)))holder=await chrome.windows.create({url:"about:blank",type:"popup",focused:false,width:240,height:160});const outcomes=[];for(const target of targets){if(cancelled.has(r.operationID))break;try{const current=await chrome.windows.get(target.windowID,{populate:true}),ids=(current.tabs??[]).map(t=>t.id),expected=target.expectedTabIDs??[];if(target.expectedSessionID!==sessionID||!expected.every(id=>ids.includes(id))){outcomes.push({windowID:target.windowID,status:"stale",code:"identity_changed"});continue}const selected=target.tabIDs.filter(id=>ids.includes(id));if(selected.length===ids.length&&!target.nativeAssociationVerified){outcomes.push({windowID:target.windowID,status:"skipped",code:"unverified_window_identity"});continue}if(target.closeWholeWindow&&target.nativeAssociationVerified&&selected.length===ids.length){await chrome.windows.remove(target.windowID);outcomes.push({windowID:target.windowID,status:"closed_window"})}else if(selected.length){await chrome.tabs.remove(selected);outcomes.push({windowID:target.windowID,status:"closed_tabs",tabIDs:selected})}else outcomes.push({windowID:target.windowID,status:"skipped"})}catch(error){outcomes.push({windowID:target.windowID,status:"failed",code:"chrome_api_error",message:String(error)})}}const status=cancelled.has(r.operationID)?"cancelled":outcomes.every(x=>!["failed","stale","skipped"].includes(x.status))?"complete":"partial",response={type:"closeSelectedResult",protocolVersion:PROTOCOL,requestID:r.requestID,operationID:r.operationID,status,payload:{outcomes}};await saveOperation(r.operationID,response);port?.postMessage(response);if(holder?.id)setTimeout(()=>chrome.windows.remove(holder.id).catch(()=>{}),500)}
async function startupWindowFor(token){
  if(!token)return null;
  const marker=`${chrome.runtime.getURL("startup.html")}#deskriptions-restore=${token}`;
  const tabs=await chrome.tabs.query({});
  const markerTab=tabs.find(t=>(t.url??t.pendingUrl)==marker);
  if(!markerTab?.windowId||!markerTab.id)return null;
  const window=await chrome.windows.get(markerTab.windowId,{populate:true});
  return{window,markerTabID:markerTab.id};
}
async function restoreDesktop(r){
  const key=`operation:${r.operationID}`,prior=await operationRecord(r.operationID);
  if(prior?.status==="complete"){
    const frontmost=(prior.payload?.windows??[]).filter(x=>x.windowID&&x.status==="complete").at(-1);
    if(frontmost)try{await chrome.windows.update(frontmost.windowID,{focused:true})}catch(error){port?.postMessage({...prior,requestID:r.requestID,status:"partial",payload:{...prior.payload,focusError:String(error)}});return}
    port?.postMessage({...prior,requestID:r.requestID});return
  }
  const windows=r.payload?.windows??[],outcomes=[];
  if(prior?.status==="running"||prior?.status==="partial"||prior?.status==="failed"){
    for(const old of prior.payload?.windows??[]){
      if(!old.windowID)continue;
      try{const live=await chrome.windows.get(old.windowID,{populate:true});const saved=windows.find(w=>w.id===old.savedWindowID);if(!saved){continue}const actual=(live.tabs??[]).filter(t=>old.tabIDs?.includes(t.id));const expected=[...saved.tabs].sort((a,b)=>a.order-b.order);if(actual.length!==expected.length||actual.some((t,i)=>t.url!==expected[i].url)){result(r,"indeterminate",{code:"reconciliation_failed",message:"A restoration window changed after the last attempt; no duplicate content was opened.",payload:prior.payload});return}outcomes.push({...old,status:"complete",tabIDs:actual.map(t=>t.id)})}
      catch{result(r,"indeterminate",{code:"reconciliation_failed",message:"Previously created content is no longer identifiable; no new content was opened.",payload:prior.payload});return}
    }
  }
  const progress={type:"restoreDesktopResult",protocolVersion:PROTOCOL,requestID:r.requestID,operationID:r.operationID,status:"running",payload:{windows:outcomes}};
  await chrome.storage.local.set({[key]:progress});
  let startup=await startupWindowFor(r.payload?.startupToken);
  for(const saved of windows){
    if(outcomes.some(x=>x.savedWindowID===saved.id))continue;
    if(cancelled.has(r.operationID))break;
    try{
      const ordered=[...saved.tabs].sort((a,b)=>a.order-b.order);if(!ordered.length)continue;
      let created,tabs,markerTabID;
      if(startup){
        created=startup.window;markerTabID=startup.markerTabID;startup=null;
        await chrome.windows.update(created.id,{focused:false,left:Math.round(saved.frame.x),top:Math.round(saved.frame.y),width:Math.round(saved.frame.width),height:Math.round(saved.frame.height)});
        tabs=[];
        for(let i=0;i<ordered.length;i++)tabs.push(await chrome.tabs.create({windowId:created.id,url:ordered[i].url,active:false,index:i}));
      }else{
        created=await chrome.windows.create({url:ordered.map(t=>t.url),focused:false,left:Math.round(saved.frame.x),top:Math.round(saved.frame.y),width:Math.round(saved.frame.width),height:Math.round(saved.frame.height)});
        tabs=created.tabs??await chrome.tabs.query({windowId:created.id});
      }
      const createdOutcome={savedWindowID:saved.id,windowID:created.id,tabIDs:tabs.map(t=>t.id),status:"created",reusedStartupWindow:!!markerTabID};
      outcomes.push(createdOutcome);await saveOperation(r.operationID,{...progress,payload:{windows:outcomes}});
      for(let i=0;i<Math.min(tabs.length,ordered.length);i++)await chrome.tabs.update(tabs[i].id,{pinned:!!ordered[i].pinned,active:!!ordered[i].active});
      if(markerTabID)await chrome.tabs.remove(markerTabID);
      createdOutcome.status="complete";
    }catch(error){outcomes.push({savedWindowID:saved.id,status:"failed",code:"chrome_api_error",message:String(error)})}
  }
  const frontmost=outcomes.filter(x=>x.windowID&&x.status==="complete").at(-1);
  if(frontmost)try{await chrome.windows.update(frontmost.windowID,{focused:true})}catch(error){outcomes.push({savedWindowID:frontmost.savedWindowID,status:"failed",code:"focus_failed",message:String(error)})}
  const status=cancelled.has(r.operationID)?"cancelled":outcomes.every(x=>x.status==="complete")?"complete":outcomes.some(x=>x.status==="complete")?"partial":"failed",response={...progress,status,payload:{windows:outcomes}};
  await chrome.storage.local.set({[key]:response});port?.postMessage(response);
}
async function handleNative(m){if(m.protocolVersion!==PROTOCOL){result(m,"failed",{code:"incompatible_protocol"});return}switch(m.type){case"freshInventory":await sendInventory("explicit_request",m.requestID);break;case"closeSelected":await closeSelected(m);break;case"restoreDesktop":await restoreDesktop(m);break;case"cancelOperation":cancelled.add(m.operationID);result(m,"complete");break;case"restoreTest":await restoreDesktop({...m,payload:{windows:[{id:"test",frame:{x:100,y:100,width:900,height:700},tabs:(m.urls??[]).map((url,order)=>({url,order,pinned:false,active:order===0}))}]}});break}}
function connect(){if(port||connecting)return;connecting=true;try{const candidate=chrome.runtime.connectNative(HOST);port=candidate;connecting=false;candidate.onMessage.addListener(handleNative);candidate.onDisconnect.addListener(()=>{console.warn("Deskriptions bridge disconnected:",chrome.runtime.lastError?.message??"native host disconnected");if(port===candidate)port=undefined;setTimeout(connect,Math.min(30000,500*(2**reconnectAttempt++)))});reconnectAttempt=0;sendInventory("connected")}catch(error){connecting=false;console.error(error);setTimeout(connect,Math.min(30000,500*(2**reconnectAttempt++)))}}
for(const event of[chrome.windows.onCreated,chrome.windows.onRemoved,chrome.windows.onFocusChanged,chrome.tabs.onCreated,chrome.tabs.onRemoved,chrome.tabs.onMoved,chrome.tabs.onUpdated])event.addListener(()=>sendInventory("change"));
chrome.action.onClicked.addListener(()=>sendInventory("action"));chrome.runtime.onStartup.addListener(connect);chrome.runtime.onInstalled.addListener(connect);chrome.alarms.create("heartbeat",{periodInMinutes:.5});chrome.alarms.onAlarm.addListener(a=>{if(a.name==="heartbeat")sendInventory("heartbeat")});connect();
setInterval(()=>sendInventory("bridge_poll"),1000);
