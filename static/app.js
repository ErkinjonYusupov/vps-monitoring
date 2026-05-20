const $=id=>document.getElementById(id);
let HOST_RAW='',HOST_MASKED=true;

function maskHost(h){return h.replace(/(ip-)?.*/, 'ip-***-***-***-***')}
function renderHost(){$('host').textContent=HOST_MASKED?maskHost(HOST_RAW):HOST_RAW;$('maskBtn').textContent=HOST_MASKED?'Show':'Hide'}
function toggleMask(){HOST_MASKED=!HOST_MASKED;localStorage.setItem('vps_host_mask',HOST_MASKED?'1':'0');renderHost()}
HOST_MASKED=localStorage.getItem('vps_host_mask')!=='0';

function ring(p){$('cpuRing').style.strokeDashoffset=314-(314*Math.min(p,100)/100)}

// Get Telegram initData - MUST be called synchronously, not in async context
let TELEGRAM_INIT_DATA = '';
if(window.Telegram && Telegram.WebApp){
  console.log('[TG] Telegram Web App detected');
  Telegram.WebApp.ready();
  Telegram.WebApp.expand();
  Telegram.WebApp.setHeaderColor('#050914');
  Telegram.WebApp.setBackgroundColor('#050914');
  TELEGRAM_INIT_DATA = Telegram.WebApp.initData || '';
  console.log('[TG] initData captured, length:', TELEGRAM_INIT_DATA.length);
} else {
  console.log('[TG] Not running in Telegram Web App');
}

function bar(id,p,lvl){$(id+'Bar').style.width=Math.min(p,100)+'%';$(id+'BarBox').className='bar '+lvl}

async function load(){
  try{
    console.log('[FETCH] Sending request with initData length:', TELEGRAM_INIT_DATA.length);
    let r=await fetch('/api/metrics',{headers:{'X-Telegram-Init-Data':TELEGRAM_INIT_DATA}});
    if(r.status===401){
      console.log('[AUTH] Got 401, prompting for password');
      let p=prompt('Password');
      if(!p)return;
      await fetch('/login',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'password='+encodeURIComponent(p)});
      return load();
    }
    let m=await r.json();
    HOST_RAW=m.host;renderHost();
    $('health').textContent=m.health.label;$('health').className='status '+m.health.level;
    $('cpu').textContent=m.cpu.pct+'%';
    $('load').textContent=`load ${m.cpu.load1} / ${m.cpu.load5} / ${m.cpu.load15} • ${m.cpu.load_per_core}/core`;
    ring(m.cpu.pct);
    $('cores').textContent=m.cpu.cores;
    $('uptime').textContent=m.uptime.split(' ').slice(0,2).join(' ');
    $('refresh').textContent=REFRESH+'s';
    $('ram').textContent=m.ram.pct+'%';
    $('ramd').textContent=`${m.ram.used_gb} GB used • ${m.ram.avail_gb} GB free`;
    bar('ram',m.ram.pct,m.ram.level);
    $('disk').textContent=m.disk.pct+'%';
    $('diskd').textContent=`${m.disk.used_gb} GB used • ${m.disk.free_gb} GB free`;
    bar('disk',m.disk.pct,m.disk.level);
    $('alerts').className='alerts '+(m.health.alerts.length?'show':'');
    $('alerts').textContent=m.health.alerts.join(' • ');
    let svc='';
    for(let s of m.services){
      svc+=`<div class="svcRow ${s.status}"><b>${s.name}</b><span>${s.status}</span></div>`;
    }
    $('svc').innerHTML=svc;
    let top='';
    for(let p of m.top){
      top+=`<div class="procRow"><span class="pid">${p.pid}</span><b>${p.cmd}</b><span class="pct">${p.cpu}%</span><span class="pct">${p.mem}%</span></div>`;
    }
    $('top').innerHTML=top;
    $('ts').textContent=new Date().toLocaleTimeString();
  }catch(e){
    console.error('[LOAD] Error:', e);
    $('health').textContent='ERROR';$('health').className='status danger';
  }
}

load();
setInterval(load, REFRESH*1000);
