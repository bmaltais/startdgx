// The panel's ComfyUI rules: what the installs list says, which row shows what, and the memory a running one holds.
const test = require("node:test")
const assert = require("node:assert")
const M = require("./load.js")

const install = (over) => Object.assign({ path: "/home/u/dgx-comfyui", kind: "dgx-comfyui", present: true, installed: true, json_capable: true, managed: true, label: "",
  tool: { tag: "v0.1.0", commit: "d913a9f", branch: "", dirty: false, unpushed: 0 } }, over)
const listText = (installs) => JSON.stringify({ installs: installs })

test("parseComfyList: the installs, or null for what isn't the list", () => {
  assert.strictEqual(M.parseComfyList(listText([install({})])).length, 1)
  assert.deepStrictEqual(M.parseComfyList(listText([])), [])
  assert.strictEqual(M.parseComfyList("nope"), null)
  assert.strictEqual(M.parseComfyList("{}"), null)
  assert.strictEqual(M.parseComfyList(listText([{ label: "no path" }])), null)
  assert.strictEqual(M.parseComfyList(listText([{ path: "" }])), null)
})

test("comfyAnswer: a failed command says why, an unreadable answer says so", () => {
  assert.deepStrictEqual(M.comfyAnswer(0, listText([]), "", "h").installs, [])
  assert.match(M.comfyAnswer(1, "", "Error: h has no engine\n", "h").error, /no engine/)
  assert.match(M.comfyAnswer(0, "x", "", "h").error, /unreadable/)
})

test("comfyKey: a path's slashes never read as a model's host/id", () => {
  assert.strictEqual(M.comfyKey("me@dgx", "/home/u/dgx-comfyui"), "me@dgx#comfy//home/u/dgx-comfyui")
  assert.notStrictEqual(M.comfyKey("me@dgx", "/a"), M.modelKey("me@dgx", "a"))
})

test("comfyRunning: the running installs and the MiB they hold, however the status looks", () => {
  assert.deepStrictEqual(M.comfyRunning({ comfyui: [{ path: "/a", rss_mib: 2048 }] }), { "/a": 2048 })
  assert.deepStrictEqual(M.comfyRunning({}), {})
  assert.deepStrictEqual(M.comfyRunning(null), {})
  assert.deepStrictEqual(M.comfyRunning({ comfyui: "x" }), {})
  assert.deepStrictEqual(M.comfyRunning({ comfyui: [null, { path: 3 }, { path: "/b" }] }), { "/b": 0 })
})

test("comfyRow: what each install's row shows", () => {
  const running = { comfyui: [{ path: "/home/u/dgx-comfyui", rss_mib: 6144 }] }
  const up = M.comfyRow(install({}), running)
  assert.strictEqual(up.state, "running")
  assert.strictEqual(up.gib, 6)
  assert.strictEqual(up.version, "v0.1.0")
  assert.strictEqual(up.name, "dgx-comfyui")
  assert.strictEqual(up.note, "")
  assert.strictEqual(M.comfyRow(install({}), {}).state, "stopped")
  assert.strictEqual(M.comfyRow(install({ label: "usb" }), {}).name, "usb")
  assert.strictEqual(M.comfyRow(install({ path: "/media/usb/dgx-comfyui/" }), {}).name, "dgx-comfyui")
  // A working copy shows its branch, and that it has changes.
  assert.strictEqual(M.comfyRow(install({ tool: { tag: "", branch: "main", commit: "abc", dirty: true } }), {}).version, "main · changed")
  assert.strictEqual(M.comfyRow(install({ tool: { tag: "", branch: "", commit: "abc" } }), {}).version, "abc")
  // What can't run says why.
  assert.deepStrictEqual([M.comfyRow(install({ installed: false }), {}).state, M.comfyRow(install({ installed: false }), {}).note], ["unfinished", "ComfyUI isn't installed in it yet"])
  assert.strictEqual(M.comfyRow(install({ present: false }), {}).state, "missing")
  assert.strictEqual(M.comfyRow({ path: "/x", kind: "foreign", present: true }, {}).state, "unsupported")
  const old = M.comfyRow(install({ json_capable: false }), {})
  assert.strictEqual(old.state, "stopped")
  assert.match(old.note, /Too old/)
  // A missing folder says that, not "too old".
  assert.strictEqual(M.comfyRow(install({ present: false, json_capable: false }), {}).note, "Its folder is gone")
})

test("comfySummary: the count and how many run", () => {
  assert.strictEqual(M.comfySummary([]), "")
  assert.strictEqual(M.comfySummary([{ state: "stopped" }]), "1 install")
  assert.strictEqual(M.comfySummary([{ state: "running" }, { state: "stopped" }]), "2 installs, 1 running")
})

test("hostMemory: a running ComfyUI is its own segment, not other programs'", () => {
  const models = { a: { recipe: "a", name: "Alpha", unit: "active", observed: { ram_used_gib: 30 } } }
  const status = { ram_total_gib: 122, ram_available_gib: 40, models, comfyui: [{ path: "/c", rss_mib: 20 * 1024 }] }
  const mem = M.hostMemory(status, {})
  assert.deepStrictEqual(mem.segments.map((s) => s.id), ["a", "comfyui:/c", "other"])
  assert.strictEqual(mem.segments[1].name, "ComfyUI")
  assert.strictEqual(mem.segments[1].comfy, true)
  assert.strictEqual(mem.comfy, 20)
  assert.strictEqual(mem.other, 32, "what the machine holds beyond the models and ComfyUI")
  assert.strictEqual(mem.used, 82)
  assert.match(M.memoryText(mem), /ComfyUI 20 GiB/)
  // Without the host's own figure, only what we know is held.
  assert.strictEqual(M.hostMemory({ ram_total_gib: 122, models, comfyui: [{ path: "/c", rss_mib: 20 * 1024 }] }, {}).used, 50)
  // Alone, it is still something loaded.
  const only = M.hostMemory({ ram_total_gib: 122, models: {}, comfyui: [{ path: "/c", rss_mib: 8192 }] }, {})
  assert.strictEqual(M.memoryText(only), "8 of 122 GiB in use · ComfyUI 8 GiB")
})

test("hostMemory: a model that loads while ComfyUI runs gets the memory beyond ComfyUI, not ComfyUI's", () => {
  const models = { a: { recipe: "a", name: "Alpha", unit: "activating", observed: { ram_used_gib: 40 } } }
  const mem = M.hostMemory({ ram_total_gib: 122, ram_available_gib: 62, models, comfyui: [{ path: "/c", rss_mib: 20 * 1024 }] }, {})
  assert.deepStrictEqual(mem.segments.map((s) => s.id), ["comfyui:/c", "a"])
  assert.strictEqual(mem.segments[1].gib, 40)
})

test("rows: a machine's ComfyUI installs follow its Add model row", () => {
  const up = { loaded: true, online: true, status: { models: {} } }
  const comfy = { h1: [{ path: "/a" }, { path: "/b" }], h2: [{ path: "/c" }] }
  const r = M.rows(["h1", "h2"], { h1: up, h2: { loaded: true, online: false, status: null } }, comfy)
  assert.deepStrictEqual(r.map((x) => x.kind + ":" + x.host + (x.id ? "/" + x.id : "")),
    ["host:h1", "add:h1", "comfy:h1//a", "comfy:h1//b", "host:h2", "comfy:h2//c"])
  assert.deepStrictEqual(M.rows(["h1"], { h1: up }).map((x) => x.kind), ["host", "add"], "none listed: as before")
})

test("keyAction: on a ComfyUI row the machine's keys act for its machine", () => {
  const row = { kind: "comfy", host: "h", id: "/a" }
  assert.deepStrictEqual(M.keyAction("a", row, null, "", false, false, ""), { type: "addModel", host: "h" })
  assert.deepStrictEqual(M.keyAction("g", row, null, "", false, false, ""), { type: "hostSettings", host: "h" })
  assert.strictEqual(M.keyAction("d", row, null, "", false, false, ""), null, "no remove on an install")
})
