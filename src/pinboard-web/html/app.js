// Pinboard web — talks to the API on the SAME origin under /api/.
// nginx proxies /api/ to the API container (see nginx/default.conf.template),
// so the browser never needs to know where the API lives.
const $ = (id) => document.getElementById(id);
$('webhost').textContent = location.host;

async function api(path, opts) {
  const res = await fetch('/api' + path, { headers: { 'Content-Type': 'application/json' }, ...opts });
  if (!res.ok && res.status !== 204) throw new Error(`${res.status} ${await res.text()}`);
  return res.status === 204 ? null : res.json();
}

async function refreshInfo() {
  try {
    const i = await api('/info');
    $('hdr').className = 'theme-' + (i.theme || 'emerald');
    $('greeting').textContent = i.greeting;
    $('version').textContent = i.version;
    $('hostname').textContent = i.hostname;
    $('store').textContent = i.store;
    $('status').textContent = '';
    $('status').className = 'status';
  } catch (e) {
    $('hdr').className = 'theme-offline';
    $('greeting').textContent = 'API unreachable';
    $('status').textContent = 'Cannot reach the API: ' + e.message;
    $('status').className = 'status err';
  }
}

async function refreshNotes() {
  try {
    const notes = await api('/notes');
    $('notes').innerHTML = notes.map(n => `
      <li><div>${esc(n.text)}<small>${esc(n.author || 'anonymous')} · ${new Date(n.createdAt).toLocaleString()}</small></div>
      <button title="delete" data-id="${n.id}">×</button></li>`).join('') || '<li><div>No notes yet — pin the first one!</div></li>';
  } catch (e) { /* status already shown by refreshInfo */ }
}

function esc(s) { return String(s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c])); }

$('form').addEventListener('submit', async (ev) => {
  ev.preventDefault();
  try {
    await api('/notes', { method: 'POST', body: JSON.stringify({ text: $('text').value, author: $('author').value }) });
    $('text').value = '';
    await refreshNotes();
  } catch (e) { $('status').textContent = 'Could not save: ' + e.message; $('status').className = 'status err'; }
});

$('notes').addEventListener('click', async (ev) => {
  const id = ev.target.dataset.id;
  if (!id) return;
  try { await api('/notes/' + id, { method: 'DELETE' }); await refreshNotes(); } catch (e) {}
});

refreshInfo(); refreshNotes();
setInterval(() => { refreshInfo(); refreshNotes(); }, 3000);
