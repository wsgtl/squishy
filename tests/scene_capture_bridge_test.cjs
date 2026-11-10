const fs=require('fs'),vm=require('vm'),assert=require('assert'),path=require('path');
const source=fs.readFileSync(path.join(__dirname,'../scripts/scene_capture.gd'),'utf8');
const bridge=source.split('const WEB_BRIDGE := '+String.fromCharCode(34).repeat(3))[1].split(String.fromCharCode(34).repeat(3))[0].replace('%s',JSON.stringify('test')).replace('%s',JSON.stringify('test.jpg')).replace('%s',JSON.stringify({title:'スクイーズ記念写真',text:'私のスクイーズ記念写真 #punikko',unsupported:'画像共有は未対応です',failed:'共有できませんでした'}));
function setup({canShare=false,error=null,secure=true,pending=false}={}){
 const calls={elements:[],downloads:0,shares:0,opened:[],revoked:0,files:[]};
 const listeners=new Map(), windowListeners=new Map();
 const logs=[];
 const context={Date,Math,Blob,File:class{constructor(parts,name,options){this.name=name;this.type=options.type;}},Uint8Array,atob,encodeURIComponent,
 location:{origin:'https://game.punikko.fun',pathname:'/games/squishy/'},
 document:{getElementById:()=>({getBoundingClientRect:()=>({left:0,top:0,width:720,height:1280})}),addEventListener:(n,f)=>listeners.set(n,f),removeEventListener:(n,f)=>{if(listeners.get(n)===f)listeners.delete(n);},createElement(tag){calls.elements.push(tag);return{click(){calls.downloads++},remove(){}}},body:{append(){}}},
 navigator:{canShare:()=>canShare,share:async(options)=>{calls.shares++;calls.files=options.files;if(error)throw{name:error};if(pending)return new Promise(()=>{});}},
 URL:{createObjectURL:()=> 'blob:photo',revokeObjectURL:()=>calls.revoked++}};
 context.window={punikkoShareLog:(event,data)=>logs.push({event,data}),addEventListener:(n,f)=>windowListeners.set(n,f),removeEventListener:n=>windowListeners.delete(n),isSecureContext:secure,open:(url)=>calls.opened.push(url)};
 vm.runInNewContext(bridge,context);return{photo:context.window.punikkoPhoto,calls,logs,listeners,windowListeners,reopen(){vm.runInNewContext(bridge,context);this.photo=context.window.punikkoPhoto;}};
}
(async()=>{
 let s=setup();s.photo.save();assert.equal(s.calls.downloads,1);assert.deepEqual(s.calls.elements,['a']);
 for(const platform of ['X','LINE']){
  s=setup({canShare:true});await s.photo.share(platform);assert.equal(s.calls.shares,0);assert.equal(s.calls.opened.length,1);
  const target=new URL(s.calls.opened[0]);assert.equal(target.hostname,platform==='X'?'twitter.com':'social-plugins.line.me');
  assert.equal(target.searchParams.get('url'),'https://game.punikko.fun/games/squishy/');
  if(platform==='X')assert.equal(target.searchParams.get('text'),'私のスクイーズ記念写真 #punikko');
 }
 for(const platform of ['Instagram','TikTok','Kakao']){s=setup({canShare:true});await s.photo.share(platform);assert.equal(s.calls.shares,1);assert.equal(s.calls.opened.length,0);}
 s=setup({canShare:true});await s.photo.share('系统分享');assert.equal(s.calls.shares,1);assert.equal(s.calls.files[0].type,'image/jpeg');assert.equal(s.calls.opened.length,0);
 s=setup({canShare:true,error:'AbortError'});await s.photo.share('系统分享');assert.equal(s.photo.takeMessage(),'');assert.equal(s.calls.downloads,0);
 for(const options of [{},{canShare:true,secure:false},{canShare:true,error:'NotAllowedError'}]){
  s=setup(options);await s.photo.share('系统分享');assert(s.photo.takeMessage().length>0);assert.equal(s.photo.takeMessage(),'');
  assert.equal(s.calls.elements.length,0);assert.equal(s.calls.downloads,0);assert.equal(s.calls.opened.length,0);
 }
 s.photo.dispose();assert.equal(s.calls.revoked,1);
 // Trusted touch path survives close/reopen, suppresses duplicate Godot dispatch,
 // ignores scroll drags and releases all listeners on disposal.
 s=setup({canShare:true});
 const point={identifier:4,clientX:100,clientY:100};
 for(let i=0;i<3;i++){
  s.photo.setTargets([{platform:'Instagram',x:0,y:0,w:1,h:1}]);
  s.listeners.get('touchstart')({touches:[point]});
  s.listeners.get('touchend')({changedTouches:[point]});
  await s.photo.shareFromGame('Instagram');
  assert.equal(s.calls.shares,i+1);
  s.listeners.get('touchstart')({touches:[point]});
  s.listeners.get('touchmove')({touches:[{...point,clientX:160}]});
  s.listeners.get('touchend')({changedTouches:[point]});
  assert.equal(s.calls.shares,i+1);
  s.photo.dispose(); assert.equal(s.listeners.size,0);
  s.reopen(); assert.equal(s.listeners.size,5);
 }
 // A stale contact must not prevent the fresh tap after returning from an app.
 s=setup({canShare:true,pending:true});
 s.photo.setTargets([{platform:'Instagram',x:0,y:0,w:1,h:1}]);
 const stale={identifier:99,clientX:700,clientY:1200};
 const tap=()=>{
  s.listeners.get('touchstart')({touches:[stale,point],changedTouches:[point]});
  s.listeners.get('touchend')({changedTouches:[point]});
 };
 tap();assert.equal(s.calls.shares,1);
 await s.photo.share('X');assert.equal(s.calls.opened.length,1);
 s.windowListeners.get('focus')();tap();assert.equal(s.calls.shares,2);
 s.photo.dispose();assert.equal(s.windowListeners.size,0);
 s.reopen();s.photo.setTargets([{platform:'Instagram',x:0,y:0,w:1,h:1}]);
 tap();assert.equal(s.calls.shares,3);
 assert(s.logs.some(r=>r.event==='photo.create'));
 assert(s.logs.some(r=>r.event==='touch.start'));
 assert(s.logs.some(r=>r.event==='share.invoke'));
 assert(s.logs.some(r=>r.event==='photo.dispose'));
 const diagnostics=source.split('const WEB_DIAGNOSTICS := '+String.fromCharCode(34).repeat(3))[1].split(String.fromCharCode(34).repeat(3))[0];
 new vm.Script(diagnostics);
 console.log('Photo browser bridge: PASS (direct download, X/LINE intents, separate file share, cancel, inline error, cleanup)');
})().catch(e=>{console.error(e);process.exit(1)});
