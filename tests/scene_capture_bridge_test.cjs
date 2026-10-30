const fs=require('fs'),vm=require('vm'),assert=require('assert'),path=require('path');
const source=fs.readFileSync(path.join(__dirname,'../scripts/scene_capture.gd'),'utf8');
const bridge=source.split('const WEB_BRIDGE := '+String.fromCharCode(34).repeat(3))[1].split(String.fromCharCode(34).repeat(3))[0].replace('%s',JSON.stringify('test')).replace('%s',JSON.stringify('test.jpg')).replace('%s',JSON.stringify({title:'スクイーズ記念写真',text:'私のスクイーズ記念写真 #punikko',unsupported:'画像共有は未対応です',failed:'共有できませんでした'}));
function setup({canShare=false,error=null,secure=true}={}){
 const calls={elements:[],downloads:0,shares:0,opened:[],revoked:0,files:[]};
 const context={Blob,File:class{constructor(parts,name,options){this.name=name;this.type=options.type;}},Uint8Array,atob,encodeURIComponent,
 location:{origin:'https://game.punikko.fun',pathname:'/games/squishy/'},
 document:{createElement(tag){calls.elements.push(tag);return{click(){calls.downloads++},remove(){}}},body:{append(){}}},
 navigator:{canShare:()=>canShare,share:async(options)=>{calls.shares++;calls.files=options.files;if(error)throw{name:error};}},
 URL:{createObjectURL:()=> 'blob:photo',revokeObjectURL:()=>calls.revoked++}};
 context.window={isSecureContext:secure,open:(url)=>calls.opened.push(url)};
 vm.runInNewContext(bridge,context);return{photo:context.window.punikkoPhoto,calls};
}
(async()=>{
 let s=setup();s.photo.save();assert.equal(s.calls.downloads,1);assert.deepEqual(s.calls.elements,['a']);
 for(const platform of ['X','LINE']){
  s=setup({canShare:true});await s.photo.share(platform);assert.equal(s.calls.shares,0);assert.equal(s.calls.opened.length,1);
  const target=new URL(s.calls.opened[0]);assert.equal(target.hostname,platform==='X'?'twitter.com':'social-plugins.line.me');
  assert.equal(target.searchParams.get('url'),'https://game.punikko.fun/games/squishy/');
  if(platform==='X')assert.equal(target.searchParams.get('text'),'私のスクイーズ記念写真 #punikko');
 }
 s=setup({canShare:true});await s.photo.share('系统分享');assert.equal(s.calls.shares,1);assert.equal(s.calls.files[0].type,'image/jpeg');assert.equal(s.calls.opened.length,0);
 s=setup({canShare:true,error:'AbortError'});await s.photo.share('系统分享');assert.equal(s.photo.takeMessage(),'');assert.equal(s.calls.downloads,0);
 for(const options of [{},{canShare:true,secure:false},{canShare:true,error:'NotAllowedError'}]){
  s=setup(options);await s.photo.share('系统分享');assert(s.photo.takeMessage().length>0);assert.equal(s.photo.takeMessage(),'');
  assert.equal(s.calls.elements.length,0);assert.equal(s.calls.downloads,0);assert.equal(s.calls.opened.length,0);
 }
 s.photo.dispose();assert.equal(s.calls.revoked,1);
 console.log('Photo browser bridge: PASS (direct download, X/LINE intents, separate file share, cancel, inline error, cleanup)');
})().catch(e=>{console.error(e);process.exit(1)});
