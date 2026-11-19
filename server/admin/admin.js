// Loomi admin panel — plain JS, no build step. All text is Persian (RTL).
'use strict';

const $ = (s, el = document) => el.querySelector(s);
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const fa = n => Number(n).toLocaleString('fa-IR');
const bytes = n => n >= 1e9 ? fa((n / 1e9).toFixed(1)) + ' گیگ' : fa(Math.round(n / 1e6)) + ' مگ';
const when = iso => {
  if (!iso) return '—';
  const s = Math.round((Date.now() - new Date(iso)) / 1000);
  if (s < 60) return 'همین الان';
  if (s < 3600) return fa(Math.round(s / 60)) + ' دقیقه پیش';
  if (s < 86400) return fa(Math.round(s / 3600)) + ' ساعت پیش';
  return new Date(iso).toLocaleString('fa-IR', { dateStyle: 'medium', timeStyle: 'short' });
};
const dur = sec => sec < 3600 ? fa(Math.round(sec / 60)) + ' دقیقه' : sec < 86400 ? fa(Math.round(sec / 3600)) + ' ساعت' : fa(Math.round(sec / 86400)) + ' روز';
const pct10 = (used, total) => 'w' + Math.min(100, Math.round((used / Math.max(total, 1)) * 10) * 10);

async function api(path, opts = {}) {
  const res = await fetch('/admin/api' + path, {
    method: opts.method || 'GET',
    credentials: 'same-origin',
    headers: { 'x-loomi-admin': '1', ...(opts.body ? { 'content-type': 'application/json' } : {}) },
    body: opts.body ? JSON.stringify(opts.body) : undefined,
  });
  const data = await res.json().catch(() => ({}));
  if (res.status === 401 && !path.startsWith('/login')) { showGate('login'); throw new Error(data.error || 'دوباره وارد شوید.'); }
  if (!res.ok) throw new Error(data.error || 'خطای سرور (' + res.status + ')');
  return data;
}

let toastTimer;
function toast(msg, bad = false) {
  const t = $('#toast');
  t.textContent = msg;
  t.className = 'toast show' + (bad ? ' bad' : '');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => (t.className = 'toast'), 3200);
}
async function busy(btn, fn) {
  btn.disabled = true;
  try { await fn(); } catch (e) { toast(e.message, true); } finally { btn.disabled = false; }
}

// ── login / first-time setup ──
let setupToken = null;
function showGate(mode) {
  $('#shell').hidden = true;
  $('#gate').hidden = false;
  const setup = mode === 'setup';
  $('#gateTitle').textContent = setup ? 'ساختن رمز پنل ادمین' : 'ورود به پنل ادمین لومی';
  $('#gateHelp').textContent = setup ? 'این رمز فقط برای مدیر سرور است. یک رمز قوی و جدا انتخاب کنید (دست‌کم ۱۰ نویسه).' : '';
  $('#gatePass2Wrap').hidden = !setup;
  $('#gatePass2').required = setup;
  $('#gatePass').autocomplete = setup ? 'new-password' : 'current-password';
  $('#gateBtn').textContent = setup ? 'ذخیره‌ی رمز و ورود' : 'ورود';
  $('#gateFoot').innerHTML = setup ? '' : 'رمز را فراموش کرده‌اید؟ روی سرور بزنید: <code class="ltr">docker compose exec server node dist/cli.js admin</code>';
  $('#gateErr').textContent = '';
  $('#gatePass').value = $('#gatePass2').value = '';
  $('#gatePass').focus();
  $('#gateForm').dataset.mode = mode;
}

$('#gateForm')?.addEventListener('submit', async e => {
  e.preventDefault();
  const mode = e.target.dataset.mode, pass = $('#gatePass').value;
  $('#gateErr').textContent = '';
  if (mode === 'no-setup') return;
  if (mode === 'setup' && pass !== $('#gatePass2').value) { $('#gateErr').textContent = 'دو رمز یکی نیستند.'; return; }
  await busy($('#gateBtn'), async () => {
    try {
      if (mode === 'setup') await api('/setup', { method: 'POST', body: { token: setupToken, password: pass } });
      else await api('/login', { method: 'POST', body: { password: pass } });
    } catch (err) { $('#gateErr').textContent = err.message; return; }
    history.replaceState(null, '', '/admin/#/dashboard');
    enterApp();
  });
});

$('#logout')?.addEventListener('click', async () => { await api('/logout', { method: 'POST' }).catch(() => {}); showGate('login'); });

// ── pages ──
const PAGES = { dashboard, ai, devices, log };
let pairTimer;
function route() {
  clearInterval(pairTimer);
  const name = (location.hash.match(/^#\/(\w+)/) || [])[1] || 'dashboard';
  const page = PAGES[name] ? name : 'dashboard';
  document.querySelectorAll('[data-nav]').forEach(a => {
    if (a.dataset.nav === page) a.setAttribute('aria-current', 'page'); else a.removeAttribute('aria-current');
  });
  const main = $('#main');
  main.innerHTML = '<p class="muted">در حال بارگذاری…</p>';
  PAGES[page](main).catch(e => { main.innerHTML = '<div class="banner warn">' + esc(e.message) + '</div>'; });
}
window.addEventListener('hashchange', () => { if (!$('#shell').hidden) route(); });

function enterApp() {
  $('#gate').hidden = true;
  $('#shell').hidden = false;
  if (!/^#\//.test(location.hash)) location.hash = '#/dashboard';
  route();
}

async function dashboard(main) {
  const o = await api('/overview');
  const memUsed = o.memory.total - o.memory.free;
  main.innerHTML = `
    <div class="page-head"><h1>داشبورد</h1><span class="pill ok">سرور سالم · نسخه‌ی ${esc(o.version)}</span></div>
    ${o.masterKey ? '' : '<div class="banner warn">LOOMI_MASTER_KEY روی سرور تنظیم نشده؛ تا آن را تنظیم نکنید، کلیدهای API ذخیره نمی‌شوند.</div>'}
    ${o.counts.providers ? '' : '<div class="banner info">هنوز هیچ هوش مصنوعی‌ای وصل نشده. از بخش <a href="#/ai">هوش مصنوعی و کلیدها</a> شروع کنید.</div>'}
    <div class="grid">
      <div class="card stat"><span class="muted">دستگاه‌های جفت‌شده</span><b>${fa(o.counts.devices)}</b></div>
      <div class="card stat"><span class="muted">کلیدهای هوش مصنوعی</span><b>${fa(o.counts.providers)}</b></div>
      <div class="card stat"><span class="muted">کاربران</span><b>${fa(o.counts.users)}</b></div>
      <div class="card stat"><span class="muted">مدت روشن بودن</span><b>${dur(o.uptimeSec)}</b></div>
      <div class="card stat"><span class="muted">حافظه (RAM)</span><b>${bytes(memUsed)} از ${bytes(o.memory.total)}</b>
        <div class="bar"><i class="${pct10(memUsed, o.memory.total)}"></i></div><span class="muted small">لومی: ${bytes(o.memory.process)}</span></div>
      ${o.disk ? `<div class="card stat"><span class="muted">دیسک</span><b>${bytes(o.disk.total - o.disk.free)} از ${bytes(o.disk.total)}</b>
        <div class="bar"><i class="${pct10(o.disk.total - o.disk.free, o.disk.total)}"></i></div></div>` : ''}
      <div class="card stat"><span class="muted">بار پردازنده</span><b>${fa(o.load.toFixed(2))}</b><span class="muted small">${fa(o.cpus)} هسته</span></div>
    </div>
    <div class="card"><h2>آدرس سرور</h2><p class="ltr">${esc(o.publicUrl)}</p>
      <p class="muted small">اپ‌های گوشی و دسکتاپ با این آدرس و یک کد جفت‌سازی (بخش دستگاه‌ها) وصل می‌شوند.</p></div>`;
}

async function ai(main) {
  const d = await api('/providers');
  const info = id => d.catalog.find(p => p.id === id) || { name: id, caps: [] };
  const keyOpts = (cap, sel) => '<option value="">— هیچ —</option>' + d.keys.filter(k => info(k.provider).caps.includes(cap))
    .map(k => `<option value="${esc(k.id)}" ${k.id === sel ? 'selected' : ''}>${esc(k.label)}</option>`).join('');
  const modelList = (cap, keyId) => {
    const k = d.keys.find(x => x.id === keyId);
    return (k ? k.models : []).map(m => `<option value="${esc(m)}"></option>`).join('');
  };
  main.innerHTML = `
    <div class="page-head"><h1>هوش مصنوعی و کلیدها</h1></div>
    ${d.masterKey ? '' : '<div class="banner warn">LOOMI_MASTER_KEY روی سرور تنظیم نشده؛ ذخیره‌ی کلید ممکن نیست.</div>'}
    <p class="muted">کلیدهای API خودتان را این‌جا اضافه کنید. کلیدها روی همین سرور رمزنگاری می‌شوند و هیچ‌وقت به گوشی‌ها یا هیچ جای دیگر فرستاده نمی‌شوند؛ فقط ۴ نویسه‌ی آخرشان نمایش داده می‌شود.</p>

    <h2>کلیدها</h2>
    <div class="keys">${d.keys.length ? d.keys.map(k => `
      <div class="card key-card">
        <h3><span>${esc(k.label)}</span>${k.lastTestOk === true ? '<span class="pill ok">سالم</span>' : k.lastTestOk === false ? '<span class="pill bad">خطا</span>' : '<span class="pill">آزموده نشده</span>'}</h3>
        <div class="muted small">${esc(info(k.provider).name)} ${k.keyLast4 ? '· <span class="ltr">••••' + esc(k.keyLast4) + '</span>' : ''} ${k.baseUrl ? '· <span class="ltr">' + esc(k.baseUrl) + '</span>' : ''}</div>
        <div class="small">${esc(k.lastTestMsg || '')} ${k.lastTestAt ? '<span class="muted">(' + when(k.lastTestAt) + ')</span>' : ''}</div>
        <div class="actions"><button class="btn sm" data-test="${esc(k.id)}">آزمون دوباره</button><button class="btn sm danger" data-del="${esc(k.id)}">حذف</button></div>
      </div>`).join('') : '<p class="muted">هنوز کلیدی اضافه نشده.</p>'}</div>

    <div class="card">
      <h2>افزودن کلید</h2>
      <form id="addKey" class="row" autocomplete="off">
        <label class="field"><span>ارائه‌دهنده</span><select id="akProvider">${d.catalog.map(p => `<option value="${esc(p.id)}">${esc(p.name)}</option>`).join('')}</select></label>
        <label class="field"><span>اسم دلخواه</span><input id="akLabel" maxlength="40" placeholder="مثلاً Claude شخصی"></label>
        <label class="field" id="akKeyWrap"><span>کلید API</span><input id="akKey" type="password" class="ltr" autocomplete="off" spellcheck="false"></label>
        <label class="field" id="akUrlWrap" hidden><span>آدرس سرور مدل</span><input id="akUrl" class="ltr" placeholder="http://localhost:11434"></label>
        <button class="btn primary" id="akBtn" type="submit">افزودن و آزمون</button>
      </form>
      <p class="muted small" id="akHelp"></p>
    </div>

    <div class="card">
      <h2>آزمون مغز لومی</h2>
      <p class="muted small">یک جمله بنویسید تا لومی با هوش مصنوعیِ انتخاب‌شده برای «مغز» جواب بدهد. این آزمون کمی از اعتبار حسابتان مصرف می‌کند.</p>
      <form id="tryForm" class="row"><label class="field"><span>پیام</span><input id="tryPrompt" maxlength="1000" value="سلام لومی، خودت را در یک جمله معرفی کن."></label>
        <button class="btn primary" id="tryBtn" type="submit">بفرست</button></form>
      <div id="tryOut"></div>
    </div>

    <div class="card">
      <h2>هر کار با کدام هوش مصنوعی؟</h2>
      <p class="muted small">برای هر توانایی یک کلید و مدل اصلی، و اگر خواستید یک پشتیبان (وقتی اصلی خطا داد) انتخاب کنید.</p>
      ${d.capabilities.map(c => {
        const r = d.routes.find(x => x.capability === c.id) || {};
        return `<form class="route" data-cap="${c.id}">
          <div class="cap">${esc(c.label)}</div>
          <label class="field"><span>کلید اصلی</span><select name="keyId">${keyOpts(c.id, r.keyId)}</select></label>
          <label class="field"><span>مدل اصلی</span><input name="model" class="ltr" list="ml-${c.id}" value="${esc(r.model || '')}"><datalist id="ml-${c.id}">${modelList(c.id, r.keyId)}</datalist></label>
          <label class="field"><span>کلید پشتیبان</span><select name="fallbackKeyId">${keyOpts(c.id, r.fallbackKeyId)}</select></label>
          <label class="field"><span>مدل پشتیبان</span><input name="fallbackModel" class="ltr" list="mlf-${c.id}" value="${esc(r.fallbackModel || '')}"><datalist id="mlf-${c.id}">${modelList(c.id, r.fallbackKeyId)}</datalist></label>
          <button class="btn sm" type="submit">ذخیره</button>
        </form>`;
      }).join('')}
    </div>`;

  const prov = $('#akProvider'), help = () => {
    const p = info(prov.value);
    $('#akKeyWrap').hidden = !p.needsKey && p.id !== 'custom';
    $('#akKeyWrap span').textContent = p.needsKey ? 'کلید API' : 'کلید API (اگر لازم است)';
    $('#akUrlWrap').hidden = !p.needsUrl;
    $('#akUrl').value = p.needsUrl ? (p.defaultUrl || '') : '';
    $('#akHelp').innerHTML = `${p.needsKey ? 'کلید را از این‌جا بگیرید' : 'نصب'}: <a href="${esc(p.keyHelp)}" target="_blank" rel="noopener noreferrer" class="ltr">${esc(p.keyHelp)}</a> · توانایی‌ها: ${p.caps.map(c => esc((d.capabilities.find(x => x.id === c) || {}).label || c)).join('، ')}`;
  };
  prov.addEventListener('change', help); help();

  $('#addKey').addEventListener('submit', e => {
    e.preventDefault();
    busy($('#akBtn'), async () => {
      const k = await api('/providers/keys', { method: 'POST', body: { provider: prov.value, label: $('#akLabel').value, apiKey: $('#akKey').value, baseUrl: $('#akUrl').value } });
      $('#akKey').value = '';
      toast(k.lastTestOk ? 'کلید اضافه شد و سالم است.' : 'کلید اضافه شد ولی آزمون ناموفق بود: ' + (k.lastTestMsg || ''), !k.lastTestOk);
      route();
    });
  });
  $('#tryForm').addEventListener('submit', e => {
    e.preventDefault();
    busy($('#tryBtn'), async () => {
      $('#tryOut').innerHTML = '<p class="muted">لومی دارد فکر می‌کند…</p>';
      try {
        const r = await api('/providers/try', { method: 'POST', body: { prompt: $('#tryPrompt').value } });
        $('#tryOut').innerHTML = `<div class="banner info"><p dir="auto">${esc(r.text) || '<span class="muted">(جواب خالی)</span>'}</p>
          <span class="muted small ltr">${esc(r.model)} · ${fa(r.ms)} ms${r.usage ? ' · ' + fa(r.usage.input) + ' → ' + fa(r.usage.output) + ' tokens' : ''}</span>
          ${r.usedFallback ? '<p class="small">مدل اصلی خطا داد و از پشتیبان استفاده شد: ' + esc(r.errors.join('، ')) + '</p>' : ''}</div>`;
      } catch (err) { $('#tryOut').innerHTML = '<div class="banner warn">' + esc(err.message) + '</div>'; }
    });
  });
  main.querySelectorAll('[data-test]').forEach(b => b.addEventListener('click', () => busy(b, async () => {
    const k = await api('/providers/keys/' + b.dataset.test + '/test', { method: 'POST' });
    toast(k.lastTestMsg || '', !k.lastTestOk); route();
  })));
  main.querySelectorAll('[data-del]').forEach(b => b.addEventListener('click', () => {
    if (!confirm('این کلید از سرور حذف شود؟ کارهایی که از آن استفاده می‌کنند بی‌کلید می‌مانند.')) return;
    busy(b, async () => { await api('/providers/keys/' + b.dataset.del, { method: 'DELETE' }); toast('کلید حذف شد.'); route(); });
  }));
  main.querySelectorAll('form.route').forEach(f => {
    const refreshList = (sel, listId) => { $('#' + listId).innerHTML = modelList(f.dataset.cap, sel.value); };
    f.keyId.addEventListener('change', () => refreshList(f.keyId, 'ml-' + f.dataset.cap));
    f.fallbackKeyId.addEventListener('change', () => refreshList(f.fallbackKeyId, 'mlf-' + f.dataset.cap));
    f.addEventListener('submit', e => {
      e.preventDefault();
      busy(f.querySelector('button'), async () => {
        await api('/providers/routes', { method: 'PUT', body: {
          capability: f.dataset.cap, keyId: f.keyId.value || null, model: f.model.value || null,
          fallbackKeyId: f.fallbackKeyId.value || null, fallbackModel: f.fallbackModel.value || null,
        } });
        toast('ذخیره شد.');
      });
    });
  });
}

async function devices(main) {
  const list = await api('/devices');
  main.innerHTML = `
    <div class="page-head"><h1>دستگاه‌ها</h1><button class="btn primary" id="newPair">جفت کردن دستگاه تازه</button></div>
    <div id="pairBox"></div>
    <div class="card table-wrap">
      ${list.length ? `<table><thead><tr><th>دستگاه</th><th>سیستم</th><th>آخرین اتصال</th><th>جفت شده</th><th></th></tr></thead><tbody>
        ${list.map(d => `<tr><td>${esc(d.name)}</td><td class="ltr">${esc(d.platform)}</td><td>${when(d.lastSeen)}</td><td>${when(d.createdAt)}</td>
          <td><button class="btn sm danger" data-revoke="${esc(d.id)}" data-name="${esc(d.name)}">قطع دسترسی</button></td></tr>`).join('')}
      </tbody></table>` : '<p class="muted">هنوز هیچ دستگاهی جفت نشده.</p>'}
    </div>`;
  $('#newPair').addEventListener('click', e => busy(e.currentTarget, async () => {
    const p = await api('/devices/pair-code', { method: 'POST' });
    const box = $('#pairBox');
    box.innerHTML = `<div class="card pair">
      <div class="qr" aria-label="QR جفت‌سازی">${p.qrSvg}</div>
      <div><h2>با اپ لومی اسکن کنید</h2>
        <p class="muted">یا در اپ، آدرس سرور و این کد را دستی وارد کنید:</p>
        <div class="code">${esc(p.code.slice(0, 4))} ${esc(p.code.slice(4))}</div>
        <p class="muted small" id="pairLeft"></p></div></div>`;
    const end = new Date(p.expiresAt).getTime();
    const tick = () => {
      const s = Math.round((end - Date.now()) / 1000);
      if (s <= 0) { clearInterval(pairTimer); box.innerHTML = '<div class="banner warn">کد منقضی شد؛ دوباره «جفت کردن دستگاه تازه» را بزنید.</div>'; return; }
      $('#pairLeft').textContent = 'اعتبار کد: ' + fa(Math.floor(s / 60)) + ':' + String(s % 60).padStart(2, '0').replace(/\d/g, x => '۰۱۲۳۴۵۶۷۸۹'[x]) + ' — فقط یک بار کار می‌کند.';
    };
    clearInterval(pairTimer); tick(); pairTimer = setInterval(tick, 1000);
  }));
  main.querySelectorAll('[data-revoke]').forEach(b => b.addEventListener('click', () => {
    if (!confirm('دسترسی «' + b.dataset.name + '» قطع شود؟ برای استفاده‌ی دوباره باید دوباره جفت شود.')) return;
    busy(b, async () => { await api('/devices/' + b.dataset.revoke, { method: 'DELETE' }); toast('دسترسی قطع شد.'); route(); });
  }));
}

const ACTIONS = {
  'device.paired': 'دستگاه جفت شد', 'device.revoked': 'دسترسی دستگاه قطع شد', 'pair.code': 'کد جفت‌سازی ساخته شد',
  'admin.login': 'ورود ادمین', 'admin.login_failed': 'ورود ناموفق ادمین', 'admin.password_set': 'رمز ادمین تنظیم شد',
  'provider.key_added': 'کلید هوش مصنوعی اضافه شد', 'provider.key_deleted': 'کلید هوش مصنوعی حذف شد', 'provider.route_set': 'انتخاب هوش مصنوعی تغییر کرد', 'provider.tried': 'آزمون مغز لومی',
};
async function log(main) {
  const rows = await api('/audit?limit=200');
  const detail = d => Object.entries(d || {}).map(([k, v]) => `<span class="pill">${esc(k)}: <span class="ltr">${esc(v)}</span></span>`).join(' ');
  main.innerHTML = `<div class="page-head"><h1>گزارش کارها</h1><span class="muted small">۲۰۰ مورد آخر</span></div>
    <div class="card table-wrap">${rows.length ? `<table><thead><tr><th>زمان</th><th>کار</th><th>جزئیات</th></tr></thead><tbody>
      ${rows.map(r => `<tr><td>${when(r.at)}</td><td>${esc(ACTIONS[r.action] || r.action)}</td><td>${detail(r.detail)}</td></tr>`).join('')}
    </tbody></table>` : '<p class="muted">هنوز چیزی ثبت نشده.</p>'}</div>`;
}

// ── start ──
(async function start() {
  const m = location.hash.match(/setup=([\w-]+)/);
  if (m) setupToken = m[1];
  let st;
  try { st = await (await fetch('/admin/api/state', { credentials: 'same-origin' })).json(); }
  catch { document.body.textContent = 'سرور لومی در دسترس نیست.'; return; }
  if (setupToken) return showGate('setup');
  if (!st.setupDone) {
    showGate('login');
    $('#gateForm').dataset.mode = 'no-setup';
    $('#gateTitle').textContent = 'پنل ادمین هنوز راه‌اندازی نشده';
    $('#gateHelp').innerHTML = 'لینک راه‌اندازی در لاگ سرور هست. یا روی سرور بزنید:<br><code class="ltr">docker compose exec server node dist/cli.js admin</code>';
    $('#gateForm').hidden = true;
    return;
  }
  if (st.signedIn) enterApp(); else showGate('login');
})();
