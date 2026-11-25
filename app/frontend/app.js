const API = "/api";
const $ = (id) => document.getElementById(id);
let token = sessionStorage.getItem("token");
let me = null;

const msg = (t) => { $("msg").textContent = t || ""; };

async function api(path, opts = {}) {
  opts.headers = Object.assign({}, opts.headers, token ? { Authorization: "Bearer " + token } : {});
  const r = await fetch(API + path, opts);
  if (!r.ok) {
    let d = r.statusText;
    try { d = (await r.json()).detail || d; } catch (_) {}
    throw new Error(typeof d === "string" ? d : JSON.stringify(d));
  }
  return r;
}
const json = (body) => ({ headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });

async function credentials(path) {
  const body = { email: $("email").value, password: $("password").value };
  if (path === "/auth/register") await api(path, { method: "POST", ...json(body) });
  const r = await api("/auth/login", { method: "POST", ...json(body) });
  token = (await r.json()).access_token;
  sessionStorage.setItem("token", token);
  await start();
}

async function start() {
  try { me = await (await api("/me")).json(); } catch (_) { token = null; return show(false); }
  show(true);
  $("who").textContent = me.email + (me.is_agent ? " (agent)" : "");
  $("export").hidden = !me.is_agent;
  await load();
}
function show(logged) {
  $("auth").hidden = logged; $("app").hidden = !logged; $("logout").hidden = !logged;
  if (!logged) $("who").textContent = "";
}

async function load() {
  const tickets = await (await api("/tickets")).json();
  const tb = document.querySelector("#tickets tbody");
  tb.innerHTML = "";
  for (const t of tickets) {
    const tr = document.createElement("tr");
    const cells = [t.id, t.title, t.status, t.notified ? "oui" : "non"];
    cells.forEach((c) => { const td = document.createElement("td"); td.textContent = c; tr.appendChild(td); });
    const att = document.createElement("td");
    if (t.attachment_name) {
      const a = document.createElement("a"); a.href = "#"; a.textContent = t.attachment_name;
      a.onclick = (e) => { e.preventDefault(); download(`/tickets/${t.id}/attachment`, t.attachment_name); };
      att.appendChild(a);
    }
    tr.appendChild(att);
    const act = document.createElement("td");
    const b = document.createElement("button"); b.textContent = "Ouvrir"; b.onclick = () => openTicket(t.id);
    act.appendChild(b);
    if (me.is_agent) {
      const s = document.createElement("button"); s.textContent = "Résoudre";
      s.onclick = async () => { await api(`/tickets/${t.id}`, { method: "PATCH", ...json({ status: "resolved" }) }); load(); };
      act.appendChild(s);
    }
    tr.appendChild(act);
    tb.appendChild(tr);
  }
}

async function download(path, name) {
  const blob = await (await api(path)).blob();
  const a = document.createElement("a"); a.href = URL.createObjectURL(blob); a.download = name; a.click();
}

let current = null;
async function openTicket(id) {
  const t = await (await api(`/tickets/${id}`)).json();
  current = id;
  $("detail").hidden = false;
  $("d-title").textContent = `#${t.id} ${t.title}`;
  $("d-desc").textContent = t.description;
  $("comments").innerHTML = "";
  t.comments.forEach((c) => { const li = document.createElement("li"); li.textContent = c.body; $("comments").appendChild(li); });
}

$("auth-form").onsubmit = (e) => { e.preventDefault(); msg(); credentials("/auth/login").catch((x) => msg(x.message)); };
$("register").onclick = () => { msg(); credentials("/auth/register").catch((x) => msg(x.message)); };
$("logout").onclick = () => { token = null; sessionStorage.removeItem("token"); show(false); };
$("refresh").onclick = () => load().catch((x) => msg(x.message));
$("ticket-form").onsubmit = async (e) => {
  e.preventDefault(); msg();
  try {
    const t = await (await api("/tickets", { method: "POST", ...json({ title: $("title").value, description: $("desc").value }) })).json();
    const f = $("file").files[0];
    if (f) { const fd = new FormData(); fd.append("file", f); await api(`/tickets/${t.id}/attachment`, { method: "POST", body: fd }); }
    e.target.reset(); await load();
  } catch (x) { msg(x.message); }
};
$("comment-form").onsubmit = async (e) => {
  e.preventDefault();
  try { await api(`/tickets/${current}/comments`, { method: "POST", ...json({ body: $("comment").value }) }); e.target.reset(); openTicket(current); }
  catch (x) { msg(x.message); }
};
$("export").onclick = async () => {
  try {
    const { export_id } = await (await api("/exports", { method: "POST" })).json();
    msg("Export demandé, génération par le worker…");
    for (let i = 0; i < 20; i++) {
      await new Promise((r) => setTimeout(r, 1000));
      try { await download(`/exports/${export_id}`, `tickets-${export_id}.csv`); msg("Export téléchargé."); return; } catch (_) {}
    }
    msg("Export non prêt, réessayez.");
  } catch (x) { msg(x.message); }
};
start();
