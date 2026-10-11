-- Copyright (C) 2026 zacharykim88
-- SPDX-License-Identifier: AGPL-3.0-only
-- InkShare phone interface. All assets are local and offline.
return [==[<!doctype html>
<html lang="zh-CN"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>墨享 · InkShare</title>
<style>
:root { color-scheme: light; font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; color:#222; background:#f8f8f7; }
* { box-sizing: border-box; } body {margin:0; padding:0 0 92px;} header {position:sticky; top:0; z-index:2; background:#f8f8f7; border-bottom:1px solid #ddd; padding:16px max(16px,env(safe-area-inset-left));}
h1 {font-size:20px; margin:0 0 7px;} .meta {font-size:13px;color:#666;display:flex;align-items:center;justify-content:space-between;} button {border:1px solid #bbb;border-radius:8px;background:white;padding:8px 12px;font-size:14px;} button:disabled {opacity:.45;} #status {padding:10px 16px;color:#777;font-size:13px;}
.grid {padding:8px 12px;display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:10px;} .tile {min-width:0;border:1px solid #e1e1e1;border-radius:9px;overflow:hidden;background:white;position:relative;}
.thumb {display:block;background:#e9e9e9;width:100%;aspect-ratio:3/4;object-fit:contain;} .name {white-space:nowrap;overflow:hidden;text-overflow:ellipsis;font-size:10px;color:#666;padding:7px 6px 0;} .date {font-size:10px;color:#888;padding:3px 6px 8px;} .tick {position:absolute;top:5px;right:5px;min-width:28px;min-height:28px;accent-color:#333;} .tile.selected {outline:2px solid #333;}
footer {position:fixed;z-index:3;bottom:0;width:100%;background:#fff;border-top:1px solid #ddd;padding:12px 16px calc(12px + env(safe-area-inset-bottom));display:flex;align-items:center;gap:12px;justify-content:space-between;} #selected {font-size:14px;} #download {background:#232323;color:white;border-color:#232323;padding:12px 17px;}
#viewer {position:fixed;inset:0;background:rgba(0,0,0,.95);z-index:10;display:none;flex-direction:column;color:white;} #viewer.open {display:flex;} #viewerbar {display:flex;align-items:center;justify-content:space-between;padding:18px 16px;gap:10px;} #viewer img {display:block;flex:1;min-height:0;width:100%;object-fit:contain;touch-action:pan-y pinch-zoom;} #viewer a {color:white;} #viewer button {background:#222;color:white;border-color:#555;}
@media (min-width:600px) {.grid {grid-template-columns:repeat(5,minmax(0,1fr)); max-width:920px;margin:0 auto;} }
</style></head><body>
<header><h1>阅读器截图</h1><div class="meta"><span id="total">正在读取...</span><button id="refresh" type="button">刷新列表</button></div></header>
<div id="status" role="status">手机与阅读器需要连接同一局域网。</div>
<main class="grid" id="grid"></main>
<footer><span id="selected">已选择 0/10 张</span><button type="button" id="download" disabled>下载所选</button></footer>
<div id="viewer" aria-label="图片预览"><div id="viewerbar"><button id="close" type="button">关闭</button><span id="viewdate"></span><a id="save" href="#">下载 PNG</a></div><img id="large" alt="截图预览"></div>
<script>
(() => {
  const grid=document.querySelector('#grid'), status=document.querySelector('#status');
  const selected=new Set(), dl=document.querySelector('#download'), count=document.querySelector('#selected');
  const viewer=document.querySelector('#viewer'), large=document.querySelector('#large'); let files=[], currentIndex=-1, touchStart=null;
  const url=(route,name)=>route+'?f='+encodeURIComponent(name);
  const stamp=t=>t?new Date(t*1000).toLocaleString('zh-CN',{month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit'}):'时间未知';
  function update() {
    count.textContent=`已选择 ${selected.size}/10 张`;
    dl.disabled=selected.size===0;
    dl.textContent=selected.size===1?'下载 PNG':(selected.size>1?'下载 ZIP':'下载所选');
    grid.querySelectorAll('.tick').forEach(e=>e.disabled=!e.checked&&selected.size>=10);
  }
  function show(file) {
    currentIndex=files.indexOf(file);
    if(currentIndex<0)return;
    large.src=url('/image',file.name);
    document.querySelector('#save').href=url('/download',file.name);
    document.querySelector('#viewdate').textContent=`${currentIndex+1}/${files.length} · ${stamp(file.modified)}`;
    viewer.classList.add('open');
  }
  function move(step) {
    const next=currentIndex+step;
    if(next>=0&&next<files.length)show(files[next]);
  }
  large.addEventListener('touchstart',e=>{
    touchStart=e.touches.length===1?{x:e.touches[0].clientX,y:e.touches[0].clientY}:null;
  },{passive:true});
  large.addEventListener('touchend',e=>{
    if(!touchStart||e.changedTouches.length!==1){touchStart=null;return;}
    const dx=e.changedTouches[0].clientX-touchStart.x,dy=e.changedTouches[0].clientY-touchStart.y;
    touchStart=null;
    if(Math.abs(dx)>=45&&Math.abs(dx)>Math.abs(dy)*1.25)move(dx<0?1:-1);
  },{passive:true});
  large.addEventListener('touchcancel',()=>{touchStart=null;});
  async function refresh() {
    // Every refresh starts a new selection, even if the network request fails.
    selected.clear();
    grid.querySelectorAll('.tick').forEach(tick=>{
      tick.checked=false;
      tick.closest('.tile').classList.remove('selected');
    });
    update();
    status.textContent='正在读取截图...';
    try {
      const r=await fetch('/api/files',{cache:'no-store'}); if(!r.ok) throw new Error('HTTP '+r.status);
      const result=await r.json(); files=result.files;
      grid.replaceChildren();
      for(const f of files) {
        const tile=document.createElement('article'); tile.className='tile'+(selected.has(f.name)?' selected':'');
        const pic=document.createElement('img'); pic.className='thumb';pic.loading='lazy';pic.alt='截图预览';pic.src=url('/image',f.name);pic.onclick=()=>show(f);
        const tick=document.createElement('input');tick.type='checkbox';tick.className='tick';tick.checked=selected.has(f.name);tick.setAttribute('aria-label','选择 '+f.name);
        tick.onchange=()=>{if(tick.checked) {if(selected.size>=10){tick.checked=false;return;}selected.add(f.name);} else selected.delete(f.name);tile.classList.toggle('selected',tick.checked);update();};
        const name=document.createElement('div');name.className='name';name.textContent=f.name;
        const date=document.createElement('div');date.className='date';date.textContent=stamp(f.modified);
        tile.append(pic,tick,name,date);grid.append(tile);
      }
      document.querySelector('#total').textContent=`共 ${files.length} 张截图 · 时间倒序`;
      status.textContent=files.length?'点击图片预览；勾选后下载。':'暂无截图。先在 KOReader 中截屏。';update();
    } catch(e) {status.textContent='读取失败：'+e.message+'。请检查阅读器 Wi-Fi 与分享服务。';}
  }
  document.querySelector('#refresh').onclick=refresh;
  document.querySelector('#close').onclick=()=>{viewer.classList.remove('open');currentIndex=-1;touchStart=null;large.removeAttribute('src');};
  dl.onclick=()=>{
    const names=[...selected];if(!names.length||names.length>10)return;
    const link=document.createElement('a');link.href=names.length===1?url('/download',names[0]):('/batch?'+names.map(n=>'f='+encodeURIComponent(n)).join('&'));
    document.body.append(link);link.click();link.remove();
  };
  refresh();
})();
</script></body></html>]==]
