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
    ["host:h1", "add:h1", "comfy:h1//a", "comfy:h1//b", "comfyinstall:h1", "comfyfind:h1", "host:h2", "comfy:h2//c"])
  assert.deepStrictEqual(M.rows(["h1"], { h1: up }).map((x) => x.kind), ["host", "add", "comfyinstall", "comfyfind"], "none listed: just the Install and Find rows")
})

test("keyAction: on a ComfyUI row g opens its window and the machine's other keys act for its machine", () => {
  const row = { kind: "comfy", host: "h", id: "/a" }
  assert.deepStrictEqual(M.keyAction("a", row, null, "", false, false, ""), { type: "addModel", host: "h" })
  assert.deepStrictEqual(M.keyAction("g", row, null, "", false, false, ""), { type: "comfySettings", host: "h", path: "/a" }, "g opens the install's window")
  assert.strictEqual(M.keyAction("d", row, null, "", false, false, ""), null, "no remove on an install")
})

const rowOf = (over, status) => M.comfyRow(install(over), status || {})

test("comfyToggle: Start when stopped and nothing else runs, Stop when running, nothing while a click waits", () => {
  const stopped = rowOf({})
  const running = rowOf({}, { comfyui: [{ path: "/home/u/dgx-comfyui", rss_mib: 1024 }] })
  assert.deepStrictEqual(M.comfyToggle(stopped, "", [stopped]), { action: "start", reason: "" })
  assert.deepStrictEqual(M.comfyToggle(running, "", [running]), { action: "stop", reason: "" })
  assert.strictEqual(M.comfyToggle(stopped, "start", [stopped]).action, "")
  assert.strictEqual(M.comfyToggle(running, "stop", [running]).action, "")
  assert.strictEqual(M.comfyToggle(null, "", []).action, "")
})

test("comfyToggle: one ComfyUI runs at a time, so a stopped install says which to stop", () => {
  const a = rowOf({ path: "/a", label: "main" }, { comfyui: [{ path: "/a", rss_mib: 1 }] })
  const b = rowOf({ path: "/b" })
  const t = M.comfyToggle(b, "", [a, b])
  assert.strictEqual(t.action, "")
  assert.match(t.reason, /ComfyUI in main is running: stop it first/)
  assert.strictEqual(M.comfyToggle(a, "", [a, b]).action, "stop", "the running one can still stop")
})

test("comfyToggle: what can't run has no button", () => {
  for (const over of [{ installed: false }, { present: false }]) {
    const r = rowOf(over)
    assert.strictEqual(M.comfyToggle(r, "", [r]).action, "")
  }
})

test("comfyKeyAction: Enter and s start or stop the install under the cursor, once", () => {
  const row = { kind: "comfy", host: "h", id: "/a" }
  const toggle = { action: "start", reason: "" }
  assert.deepStrictEqual(M.comfyKeyAction("enter", row, toggle, false), { type: "comfyToggle", host: "h", path: "/a", kind: "start" })
  assert.deepStrictEqual(M.comfyKeyAction("S", row, { action: "stop" }, false), { type: "comfyToggle", host: "h", path: "/a", kind: "stop" })
  assert.strictEqual(M.comfyKeyAction("enter", row, toggle, true), null, "a held key acts once")
  assert.strictEqual(M.comfyKeyAction("enter", row, { action: "" }, false), null)
  assert.strictEqual(M.comfyKeyAction("x", row, toggle, false), null)
  assert.strictEqual(M.comfyKeyAction("enter", { kind: "model", host: "h", id: "m" }, toggle, false), null)
  assert.strictEqual(M.comfyKeyAction("enter", null, toggle, false), null)
})

test("comfyCommand: the CLI call for each action", () => {
  assert.deepStrictEqual(M.comfyCommand("h", { kind: "start", path: "/a" }), ["comfyui", "start", "h", "--dir", "/a", "--timeout", "120"])
  assert.deepStrictEqual(M.comfyCommand("h", { kind: "stop", path: "/a" }), ["comfyui", "stop", "h", "--dir", "/a", "--timeout", "120"])
  assert.deepStrictEqual(M.comfyCommand("h", { kind: "adopt", path: "/a", label: "usb" }), ["comfyui", "adopt", "h", "--dir", "/a", "--label", "usb", "--timeout", "60"])
  assert.deepStrictEqual(M.comfyCommand("h", { kind: "adopt", path: "/a" }), ["comfyui", "adopt", "h", "--dir", "/a", "--timeout", "60"])
  assert.strictEqual(M.comfyCommand("h", { kind: "nope", path: "/a" }), null)
})

test("comfyMarks: a click shows from the moment it is asked until the status shows it took", () => {
  const up = { comfyui: [{ path: "/a", rss_mib: 5 }] }
  const key = M.comfyKey("h", "/a")
  // Running or waiting.
  assert.deepStrictEqual(M.comfyMarks("h", [{ kind: "start", path: "/a" }, { kind: "stop", path: "/b" }], [], {}, 0).marks, { [key]: "start", [M.comfyKey("h", "/b")]: "stop" })
  // Finished, but the process isn't there yet: the mark stays.
  const wait = [{ kind: "start", path: "/a", until: 30000 }]
  assert.deepStrictEqual(M.comfyMarks("h", [], wait, {}, 1000).marks, { [key]: "start" })
  // Until it shows, or 30 s have passed.
  assert.deepStrictEqual(M.comfyMarks("h", [], wait, up, 1000), { marks: {}, settling: [] })
  assert.deepStrictEqual(M.comfyMarks("h", [], wait, {}, 31000), { marks: {}, settling: [] })
  // A stop waits for the process to go.
  const stopWait = [{ kind: "stop", path: "/a", until: 30000 }]
  assert.deepStrictEqual(M.comfyMarks("h", [], stopWait, up, 1000).marks, { [key]: "stop" })
  assert.deepStrictEqual(M.comfyMarks("h", [], stopWait, {}, 1000), { marks: {}, settling: [] })
})

test("comfyFindRows: what the Find card offers for each folder", () => {
  const found = [
    install({ managed: false, sources: ["scan"] }),
    install({ path: "/m", managed: true, sources: ["record", "scan"] }),
    install({ path: "/usb", managed: false, json_capable: false, sources: ["service", "scan"], tool: { tag: "v0.0.5" } }),
    install({ path: "/run", managed: false, sources: ["process"] }),
    { path: "/ComfyUI", kind: "foreign", present: true, managed: false, sources: ["scan"], reason: "a ComfyUI without dgx-comfyui.sh: startdgx doesn't manage it" },
    install({ path: "/gone", managed: false, present: false })]
  const rows = M.comfyFindRows(found)
  assert.deepStrictEqual(rows.map((r) => r.offer), ["adopt", "", "adopt", "adopt", "", ""])
  assert.strictEqual(rows[0].text, "v0.1.0")
  assert.strictEqual(rows[1].managed, true)
  assert.strictEqual(rows[2].text, "v0.0.5 · older than startdgx reads · starts at boot")
  assert.strictEqual(rows[3].text, "v0.1.0 · running now")
  assert.match(rows[4].text, /doesn't manage it/)
})

test("rows and keys: the Find row ends a machine's ComfyUI group and opens the card", () => {
  const up = { loaded: true, online: true, status: { models: {} } }
  const r = M.rows(["h"], { h: up }, { h: [{ path: "/a" }] })
  assert.deepStrictEqual(r.map((x) => x.kind), ["host", "add", "comfy", "comfyinstall", "comfyfind"])
  assert.deepStrictEqual(M.rows(["h"], { h: { loaded: true, online: false, status: null } }, {}).map((x) => x.kind), ["host"], "not on a machine that is away")
  assert.deepStrictEqual(M.keyAction("enter", { kind: "comfyfind", host: "h" }, null, "", false, false, ""), { type: "findComfy", host: "h" })
  assert.strictEqual(M.keyAction("enter", { kind: "comfyfind", host: "h" }, null, "", true, false, ""), null, "away: nothing")
})

const answerOf = (over, status) => Object.assign({ install: install({}), too_old: false, running_elsewhere: [], job: { state: "none", log: [] },
  update: null, status: Object.assign({ port: 8188, bind: "0.0.0.0", service: { installed: true, active: true, enabled: "enabled" }, comfy: { version: "v0.3.50", newer_release: "" },
    models_bytes: 30 * 2 ** 30, disk_free_bytes: 80 * 2 ** 30 }, status || {}) }, over)
const runningStatus = { comfyui: [{ path: "/home/u/dgx-comfyui", rss_mib: 6144 }] }

test("parseComfyStatus: the install's answer, or null", () => {
  assert.ok(M.parseComfyStatus(JSON.stringify(answerOf({}))))
  assert.strictEqual(M.parseComfyStatus("nope"), null)
  assert.strictEqual(M.parseComfyStatus("{}"), null)
})

test("comfyUrl: only where another machine can reach it", () => {
  assert.strictEqual(M.comfyUrl("me@gx10", { port: 8188, bind: "0.0.0.0" }), "http://gx10:8188")
  assert.strictEqual(M.comfyUrl("me@gx10", { port: 8188, bind: "100.64.0.2" }), "http://gx10:8188")
  assert.strictEqual(M.comfyUrl("me@gx10", { port: 8188, bind: "127.0.0.1" }), "")
  assert.strictEqual(M.comfyUrl("me@gx10", { bind: "0.0.0.0" }), "")
  assert.strictEqual(M.comfyUrl("me@gx10", null), "")
})

test("comfyPages: a running install can be opened; a stopped one says to start it", () => {
  const field = (pages, key) => pages.flatMap((p) => p.fields).find((f) => f.key === key)
  const info = M.comfyRow(install({}), runningStatus)
  const up = M.comfyPages({ host: "me@gx10", info: info, answer: answerOf({}), error: "", pending: "" })
  assert.deepStrictEqual(up.map((p) => p.title), ["General", "About", "Manage"])
  assert.strictEqual(field(up, "state").hint, "Running · 6 GiB · port 8188")
  assert.strictEqual(field(up, "open").disabled, false)
  assert.strictEqual(field(up, "open").hint, "http://gx10:8188")
  const down = M.comfyPages({ host: "me@gx10", info: M.comfyRow(install({}), {}), answer: answerOf({}), error: "", pending: "" })
  assert.strictEqual(field(down, "open").disabled, true)
  assert.strictEqual(field(down, "open").hint, "Start it first.")
  assert.strictEqual(field(down, "state").hint, "Stopped")
  const local = M.comfyPages({ host: "me@gx10", info: info, answer: answerOf({}, { bind: "127.0.0.1" }), error: "", pending: "" })
  assert.strictEqual(field(local, "open").disabled, true)
  assert.match(field(local, "open").hint, /listens on the machine itself/)
})

test("comfyPages: the facts, and what waits or fails", () => {
  const field = (pages, key) => pages.flatMap((p) => p.fields).find((f) => f.key === key)
  const info = M.comfyRow(install({}), {})
  const pages = M.comfyPages({ host: "h", info: info, answer: answerOf({ update: { from: "v0.1.0", to: "v0.2.0" }, pinned: "v0.2.0" }, { comfy: { version: "v0.3.50", newer_release: "v0.3.60" } }), error: "", pending: "" })
  assert.strictEqual(field(pages, "folder").hint, "/home/u/dgx-comfyui")
  assert.strictEqual(field(pages, "tool").hint, "v0.1.0 \u00b7 v0.1.0 \u2192 v0.2.0 is available")
  assert.strictEqual(field(pages, "comfy").hint, "v0.3.50 · v0.3.60 is out")
  assert.strictEqual(field(pages, "models").hint, "30.0 GiB \u00b7 80.0 GiB free")
  assert.strictEqual(field(M.comfyPages({ host: "h", info: info, answer: null, error: "", pending: "" }), "state").hint, "Reading…")
  assert.strictEqual(field(M.comfyPages({ host: "h", info: info, answer: null, error: "h didn't answer", pending: "" }), "state").hint, "h didn't answer")
  // While a click waits, the switch and Forget can't be clicked again.
  const busy = M.comfyPages({ host: "h", info: info, answer: answerOf({}), error: "", pending: "start" })
  assert.strictEqual(field(busy, "service").disabled, true)
  assert.strictEqual(field(busy, "forget").disabled, true)
  assert.strictEqual(field(M.comfyPages({ host: "h", info: info, answer: answerOf({}), error: "", pending: "" }), "service").disabled, false)
  // One that is not installed, or too old to read, has no switch.
  assert.strictEqual(field(M.comfyPages({ host: "h", info: M.comfyRow(install({ installed: false }), {}), answer: answerOf({}), error: "", pending: "" }), "service").disabled, true)
  assert.strictEqual(field(M.comfyPages({ host: "h", info: info, answer: answerOf({ too_old: true, status: null }), error: "", pending: "" }), "service").disabled, true)
})

test("comfyValues and comfyChange: the switch follows the service; a click asks for the matching action", () => {
  assert.deepStrictEqual(M.comfyValues(answerOf({})), { service: true })
  assert.deepStrictEqual(M.comfyValues(answerOf({}, { service: { enabled: "disabled" } })), { service: false })
  assert.deepStrictEqual(M.comfyValues(null), { service: false })
  const info = M.comfyRow(install({}), {})
  assert.deepStrictEqual(M.comfyChange("me@gx10", info, answerOf({}), "service", true), { type: "comfyToggle", host: "me@gx10", path: "/home/u/dgx-comfyui", kind: "autostart-on" })
  assert.deepStrictEqual(M.comfyChange("me@gx10", info, answerOf({}), "service", false).kind, "autostart-off")
  assert.deepStrictEqual(M.comfyChange("me@gx10", info, answerOf({}), "open", true), { type: "comfyOpen", url: "http://gx10:8188" })
  assert.strictEqual(M.comfyChange("me@gx10", info, answerOf({}, { bind: "127.0.0.1" }), "open", true), null)
  assert.deepStrictEqual(M.comfyChange("me@gx10", info, answerOf({}), "forget", true), { type: "comfyForget", host: "me@gx10", path: "/home/u/dgx-comfyui" })
  assert.strictEqual(M.comfyChange("me@gx10", info, answerOf({}), "nope", true), null)
})

test("comfyCommand and comfyMarks: the service switch and Forget", () => {
  assert.deepStrictEqual(M.comfyCommand("h", { kind: "autostart-on", path: "/a" }), ["comfyui", "autostart", "h", "on", "--dir", "/a", "--timeout", "120"])
  assert.deepStrictEqual(M.comfyCommand("h", { kind: "autostart-off", path: "/a" }), ["comfyui", "autostart", "h", "off", "--dir", "/a", "--timeout", "120"])
  assert.deepStrictEqual(M.comfyCommand("h", { kind: "forget", path: "/a" }), ["comfyui", "forget", "h", "--dir", "/a", "--timeout", "60"])
  assert.deepStrictEqual(M.comfyCommand("h", { kind: "forget", path: "/a", stopService: true }), ["comfyui", "forget", "h", "--dir", "/a", "--stop-service", "--timeout", "60"])
  // The switch shows on the row as the start or stop it is.
  assert.deepStrictEqual(M.comfyMarks("h", [{ kind: "autostart-on", path: "/a" }], [], {}, 0).marks, { [M.comfyKey("h", "/a")]: "start" })
  assert.deepStrictEqual(M.comfyMarks("h", [{ kind: "autostart-off", path: "/a" }], [], {}, 0).marks, { [M.comfyKey("h", "/a")]: "stop" })
  assert.deepStrictEqual(M.comfyMarks("h", [{ kind: "forget", path: "/a" }], [], {}, 0).marks, { [M.comfyKey("h", "/a")]: "forget" })
})

const planOf = (over) => Object.assign({ places: [{ mount: "/", fstype: "ext4", free_bytes: 1.2e12 }, { mount: "/media/u/usb", fstype: "exfat", free_bytes: 1.5e12 }],
  home: "/home/u", min_free_bytes: 40 * 2 ** 30, problems: [] }, over)

test("parseComfyPlan: the host's plan, or null", () => {
  assert.ok(M.parseComfyPlan(JSON.stringify(planOf({}))))
  assert.strictEqual(M.parseComfyPlan("x"), null)
  assert.strictEqual(M.parseComfyPlan(JSON.stringify({ places: [] })), null)
})

test("comfyFolderChoices: one per disk, the root's in the home folder", () => {
  assert.deepStrictEqual(M.comfyFolderChoices(planOf({})).map((c) => c.folder), ["/home/u/dgx-comfyui", "/media/u/usb/dgx-comfyui"])
  assert.match(M.comfyFolderChoices(planOf({}))[1].text, /^\/media\/u\/usb {2}· {2}1\.4 TiB free$|free$/)
  assert.deepStrictEqual(M.comfyFolderChoices(null), [])
})

test("comfyProblemText and comfyInstallReady: the folder typed, in words", () => {
  assert.strictEqual(M.comfyProblemText(planOf({ path: "/p", free_bytes: 1e12 })), "")
  assert.match(M.comfyProblemText(planOf({ problems: ["exists_not_empty"] })), /isn't empty/)
  assert.match(M.comfyProblemText(planOf({ problems: ["inside_managed"] })), /already manages/)
  assert.match(M.comfyProblemText(planOf({ problems: ["not_writable"] })), /can't write/)
  assert.match(M.comfyProblemText(planOf({ problems: ["too_small"], free_bytes: 20 * 2 ** 30 })), /needs 40\.0 GiB free; there is 20\.0 GiB/)
  assert.deepStrictEqual(M.comfyInstallReady(null, ""), { ready: false, text: "" })
  assert.deepStrictEqual(M.comfyInstallReady(planOf({}), "/p"), { ready: false, text: "Checking…" }, "a plan with no folder is not for this one")
  assert.strictEqual(M.comfyInstallReady(planOf({ path: "/p", free_bytes: 1e12 }), "/p").ready, true)
  assert.strictEqual(M.comfyInstallReady(planOf({ path: "/p", free_bytes: 1e9, problems: ["too_small"] }), "/p").ready, false)
})

test("comfyRow with a job: installing shows its last log line, a failed install can be run again", () => {
  const fresh = install({ installed: false })
  const running = M.comfyRow(fresh, {}, { state: "running", log: ["cloning", "", "building torch…"] })
  assert.deepStrictEqual([running.state, running.work, running.note], ["working", "Installing", "building torch…"])
  assert.strictEqual(M.comfyRow(install({}), {}, { state: "running", log: [] }).work, "Updating", "an installed one is updating")
  assert.strictEqual(M.comfyRow(fresh, {}, { state: "running", log: [] }).note, "Installing…")
  const failed = M.comfyRow(fresh, {}, { state: "failed", exit_status: 1, log: ["no space left"] })
  assert.deepStrictEqual([failed.state, failed.note], ["failed", "The install failed: no space left"])
  assert.deepStrictEqual(M.comfyToggle(failed, "", [failed]), { action: "retry", reason: "" })
  assert.strictEqual(M.comfyRow(fresh, {}, { state: "none", log: [] }).state, "unfinished")
  assert.strictEqual(M.comfyRow(fresh, {}).state, "unfinished", "no job read yet")
  assert.strictEqual(M.comfyRow(install({}), {}, { state: "failed", log: [] }).state, "stopped", "a failed update leaves a working install")
})

test("comfyWatchPaths and parseComfyJob: which installs' jobs to ask about", () => {
  const list = [install({ path: "/a" }), install({ path: "/b", installed: false }), install({ path: "/c" })]
  assert.deepStrictEqual(M.comfyWatchPaths(list, []), ["/b"])
  assert.deepStrictEqual(M.comfyWatchPaths(list, ["/c", "/b"]), ["/b", "/c"])
  assert.deepStrictEqual(M.comfyWatchPaths([], ["/x"]), [])
  assert.strictEqual(M.parseComfyJob(JSON.stringify({ path: "/b", state: "running", log: [] })).state, "running")
  assert.strictEqual(M.parseComfyJob("x"), null)
  assert.strictEqual(M.parseComfyJob("{}"), null)
})

test("comfyCommand: install, and its row key on a machine", () => {
  assert.deepStrictEqual(M.comfyCommand("h", { kind: "install", path: "/a", label: "x" }), ["comfyui", "install", "h", "--dir", "/a", "--label", "x", "--timeout", "120"])
  assert.deepStrictEqual(M.comfyCommand("h", { kind: "install", path: "/a" }), ["comfyui", "install", "h", "--dir", "/a", "--timeout", "120"])
  assert.deepStrictEqual(M.keyAction("enter", { kind: "comfyinstall", host: "h" }, null, "", false, false, ""), { type: "installComfy", host: "h" })
})

const oldTool = (over) => install({ tool: Object.assign({ tag: "v0.0.5", commit: "abc", branch: "", dirty: false, unpushed: 0 }, over) })
const offer = (over) => Object.assign({ update: { from: "v0.0.5", to: "v0.1.0" }, pinned: "v0.1.0", too_old: true, status: null }, over)

test("comfyUpdatePlan: a clean checkout on an older release can update, and says what it does", () => {
  const info = M.comfyRow(oldTool({}), {})
  const plan = M.comfyUpdatePlan(info, offer({}), "")
  assert.deepStrictEqual([plan.action, plan.target], ["update", "v0.1.0"])
  assert.match(plan.hint, /v0\.0\.5 → v0\.1\.0\. It updates dgx-comfyui/)
})

test("comfyUpdatePlan: a changed or unpushed checkout is not moved: the git commands are given", () => {
  for (const [tool, words] of [[{ dirty: true }, /uncommitted changes/], [{ unpushed: 2 }, /aren't pushed/], [{ tag: "", branch: "main", dirty: true }, /uncommitted changes/]]) {
    const info = M.comfyRow(oldTool(tool), {})
    const plan = M.comfyUpdatePlan(info, offer({ update: null }), "")
    assert.strictEqual(plan.action, "")
    assert.match(plan.hint, words)
    assert.match(plan.hint, /startdgx won't move it\. To move it yourself: git -C \/home\/u\/dgx-comfyui fetch --tags && git -C \/home\/u\/dgx-comfyui checkout v0\.1\.0$/)
  }
})

test("comfyUpdatePlan: a clean checkout on a branch moves, and the hint says how to go back", () => {
  const plan = M.comfyUpdatePlan(M.comfyRow(oldTool({ tag: "", branch: "main" }), {}), offer({ update: null }), "")
  assert.deepStrictEqual([plan.action, plan.target], ["update", "v0.1.0"])
  assert.match(plan.hint, /It is on the branch main: it moves to v0\.1\.0 and stays there; git -C \/home\/u\/dgx-comfyui checkout main goes back\./)
  assert.doesNotMatch(M.comfyUpdatePlan(M.comfyRow(oldTool({}), {}), offer({}), "").hint, /goes back/, "a tag has no branch to go back to")
})

test("comfyUpdatePlan: nothing to update, a job running, or running", () => {
  const info = M.comfyRow(install({}), {})
  assert.deepStrictEqual(M.comfyUpdatePlan(info, { update: null, pinned: "v0.1.0", too_old: false }, ""), { action: "", target: "", hint: "Up to date (v0.1.0)" })
  assert.strictEqual(M.comfyUpdatePlan(M.comfyRow(oldTool({}), {}), offer({}), "update").action, "", "a click waits")
  assert.match(M.comfyUpdatePlan(M.comfyRow(oldTool({}), {}, { state: "running", log: [] }), offer({}), "").hint, /job is running/)
  const running = M.comfyRow(oldTool({}), { comfyui: [{ path: "/home/u/dgx-comfyui", rss_mib: 1 }] })
  assert.match(M.comfyUpdatePlan(running, offer({}), "").hint, /Stop it first/)
  assert.strictEqual(M.comfyUpdatePlan(info, null, "").action, "", "not read yet")
  // Too old and untagged moves to the pin.
  assert.strictEqual(M.comfyUpdatePlan(M.comfyRow(oldTool({ tag: "" }), {}), offer({ update: null }), "").target, "v0.1.0")
})

test("comfyUpdatePlan and comfyChange: the ComfyUI update has the same conditions", () => {
  const info = M.comfyRow(oldTool({}), {})
  const ans = offer({ status: { comfy: { version: "v1", newer_release: "v2" } } })
  assert.strictEqual(M.comfyUpdatePlan(info, ans, "", true).action, "update-comfyui")
  assert.strictEqual(M.comfyUpdatePlan(M.comfyRow(oldTool({ branch: "main", tag: "" }), {}), ans, "", true).action, "update-comfyui", "a clean branch moves too")
  assert.strictEqual(M.comfyUpdatePlan(M.comfyRow(oldTool({ dirty: true }), {}), ans, "", true).action, "")
  assert.deepStrictEqual(M.comfyChange("h", info, ans, "update", true), { type: "comfyToggle", host: "h", path: "/home/u/dgx-comfyui", kind: "update" })
  assert.strictEqual(M.comfyChange("h", info, ans, "update-comfyui", true).kind, "update-comfyui")
  assert.strictEqual(M.comfyChange("h", M.comfyRow(oldTool({ dirty: true }), {}), ans, "update", true), null)
  assert.deepStrictEqual(M.comfyCommand("h", { kind: "update", path: "/a" }), ["comfyui", "update", "h", "--dir", "/a", "--timeout", "120"])
  assert.deepStrictEqual(M.comfyCommand("h", { kind: "update-comfyui", path: "/a" }), ["comfyui", "update", "h", "--dir", "/a", "--comfyui", "--timeout", "120"])
  assert.deepStrictEqual(M.comfyMarks("h", [{ kind: "update-comfyui", path: "/a" }], [], {}, 0).marks, { [M.comfyKey("h", "/a")]: "update" })
})

test("comfyPages: the About page offers Update only when there is something to update", () => {
  const field = (pages, key) => pages.flatMap((p) => p.fields).find((f) => f.key === key)
  const info = M.comfyRow(oldTool({}), {})
  const old = M.comfyPages({ host: "h", info: info, answer: offer({}), error: "", pending: "" })
  assert.strictEqual(field(old, "update").disabled, false)
  const blocked = M.comfyPages({ host: "h", info: M.comfyRow(oldTool({ dirty: true }), {}), answer: offer({ update: null }), error: "", pending: "" })
  assert.strictEqual(field(blocked, "update").disabled, true)
  assert.match(field(blocked, "update").hint, /git -C/)
  const current = M.comfyPages({ host: "h", info: M.comfyRow(install({}), {}), answer: { update: null, pinned: "v0.1.0", too_old: false, status: { comfy: {} } }, error: "", pending: "" })
  assert.strictEqual(field(current, "update").disabled, true)
  assert.strictEqual(field(current, "update").hint, "Up to date (v0.1.0)")
  assert.strictEqual(field(current, "update-comfyui"), undefined)
})

const recipeList = [
  { name: "krea", valid: true, title: "Krea-2 Turbo", description: "", models: 4, total_bytes: 19 * 2 ** 30, nodes: 0 },
  { name: "mini", valid: true, title: "MiniMax", description: "needs a token", models: 2, total_bytes: 56 * 2 ** 30, nodes: 1 },
  { name: "bad", valid: false, title: "Broken", models: 0, total_bytes: 0, nodes: 0 }]
const model = (state, over) => Object.assign({ file: "a.safetensors", dest: "loras", size: 10, state: state }, over)

test("parseComfyRecipes and parseComfyRecipeCheck: the lists the CLI sends, or null", () => {
  assert.strictEqual(M.parseComfyRecipes(JSON.stringify({ path: "/p", recipes: recipeList })).length, 3)
  assert.strictEqual(M.parseComfyRecipes("x"), null)
  assert.strictEqual(M.parseComfyRecipes(JSON.stringify({ recipes: [{ title: "no name" }] })), null)
  assert.ok(M.parseComfyRecipeCheck(JSON.stringify({ path: "/p", recipe: { models: [], nodes: [] } })))
  assert.strictEqual(M.parseComfyRecipeCheck(JSON.stringify({ recipe: {} })), null)
  assert.strictEqual(M.parseComfyRecipeCheck("x"), null)
})

test("comfyRecipePlan: what a checked workflow needs, and whether it can be installed", () => {
  const need = M.comfyRecipePlan({ models: [model("have"), model("missing", { source: { ok: true, problem: "", detail: [] } })], nodes: [{ id: "n", installed: false }], download_bytes: 6 * 2 ** 30 })
  assert.deepStrictEqual([need.action, need.text], ["install", "Needs 1 of 2 models to download (6.0 GiB) and 1 node to install."])
  const done = M.comfyRecipePlan({ models: [model("have")], nodes: [{ id: "n", installed: true }], download_bytes: 0 })
  assert.deepStrictEqual([done.action, done.text], ["", "Installed: all 1 models and 1 nodes are there."])
  const gated = M.comfyRecipePlan({ models: [model("missing", { file: "m.bin", source: { ok: false, problem: "gated", detail: ["HF_TOKEN", "401"] } })], nodes: [] })
  assert.strictEqual(gated.action, "")
  assert.match(gated.text, /m\.bin is gated: it needs HF_TOKEN\. startdgx never stores a token: put HF_TOKEN=… in ~\/\.config\/startdgx\/comfyui\.env/)
  assert.match(M.comfyRecipePlan({ models: [model("missing", { source: { ok: false, problem: "gone", detail: [] } })], nodes: [] }).text, /can't be fetched \(gone\)/)
  assert.match(M.comfyRecipePlan({ models: [model("size", { file: "x.bin" })], nodes: [] }).text, /x\.bin on disk doesn't match/)
})

test("comfyWorkflowFields: one action per workflow, Check then Install", () => {
  const info = M.comfyRow(install({}), {})
  const fields = (w) => M.comfyPages({ host: "h", info: info, answer: answerOf({}), error: "", pending: "", workflows: w }).find((p) => p.title === "Workflows").fields
  const unchecked = fields({ list: recipeList, checks: {}, checking: "" })
  assert.deepStrictEqual(unchecked.map((f) => f.key), ["wf-check:krea", "wf-check:mini", "wf-check:bad"])
  assert.strictEqual(unchecked[0].button, "Check")
  assert.strictEqual(unchecked[0].hint, "4 models · 19.0 GiB")
  assert.strictEqual(unchecked[1].hint, "2 models · 56.0 GiB · 1 node · needs a token")
  assert.strictEqual(unchecked[2].type, "info", "an invalid recipe is only said")
  const checked = fields({ list: recipeList, checks: { krea: { models: [model("missing", { source: { ok: true, problem: "", detail: [] } })], nodes: [], download_bytes: 1 } }, checking: "" })
  assert.deepStrictEqual([checked[0].key, checked[0].button], ["wf-install:krea", "Install"])
  // One check at a time, and none while a job runs.
  assert.strictEqual(fields({ list: recipeList, checks: {}, checking: "mini" })[0].disabled, true)
  assert.strictEqual(fields({ list: recipeList, checks: {}, checking: "mini" })[1].button, "Checking…")
  assert.strictEqual(M.comfyPages({ host: "h", info: info, answer: answerOf({}), error: "", pending: "update", workflows: { list: recipeList, checks: {}, checking: "" } }).find((p) => p.title === "Workflows").fields[0].disabled, true)
  assert.strictEqual(fields({ list: null, loading: true })[0].hint, "Reading…")
  assert.strictEqual(fields({ list: null, error: "too old" })[0].hint, "too old")
  assert.strictEqual(fields({ list: [], checks: {}, checking: "" })[0].hint, "This install has no workflow recipes.")
  assert.strictEqual(fields({ installable: false, reason: "Update it first." })[0].hint, "Update it first.")
})

test("comfyChange: a click on a workflow asks for its check or its install", () => {
  const info = M.comfyRow(install({}), {})
  assert.deepStrictEqual(M.comfyChange("h", info, answerOf({}), "wf-check:krea", true), { type: "comfyRecipeCheck", host: "h", path: "/home/u/dgx-comfyui", name: "krea" })
  assert.deepStrictEqual(M.comfyChange("h", info, answerOf({}), "wf-install:a:b", true), { type: "comfyRecipeInstall", host: "h", path: "/home/u/dgx-comfyui", name: "a:b" })
  assert.strictEqual(M.comfyChange("h", info, answerOf({}), "wf-other:x", true), null)
  assert.deepStrictEqual(M.comfyChange("h", info, answerOf({}), "doctor", true), { type: "comfyDoctor", host: "h", path: "/home/u/dgx-comfyui" })
  assert.deepStrictEqual(M.comfyCommand("h", { kind: "recipe-install", path: "/a", label: "krea" }), ["comfyui", "recipe", "install", "h", "krea", "--dir", "/a", "--timeout", "120"])
  assert.deepStrictEqual(M.comfyMarks("h", [{ kind: "recipe-install", path: "/a", label: "krea" }], [], {}, 0).marks, { [M.comfyKey("h", "/a")]: "recipe" })
  assert.strictEqual(M.comfyRow(install({}), {}, { state: "running", kind: "recipe", log: [] }).work, "Installing workflow")
})

test("comfyHealthFields: run the checks, then what they said", () => {
  const info = M.comfyRow(install({}), {})
  const fields = (h) => M.comfyPages({ host: "h", info: info, answer: answerOf({}), error: "", pending: "", health: h }).find((p) => p.title === "Health").fields
  const before = fields({ available: true, running: false })
  assert.deepStrictEqual([before.length, before[0].button, before[0].disabled], [1, "Run checks", false])
  assert.strictEqual(fields({ available: true, running: true })[0].button, "Checking…")
  assert.deepStrictEqual([fields({ available: false, reason: "Update it first." })[0].disabled, fields({ available: false, reason: "Update it first." })[0].hint], [true, "Update it first."])
  const doc = { healthy: false, problems: 1, changes: 0, items: [{ level: "log", text: "Host" }, { level: "ok", text: "GB10" }, { level: "warn", text: "swap is enabled" }, { level: "bad", text: "manager is missing" }] }
  const after = fields({ available: true, running: false, doc: doc })
  assert.deepStrictEqual(after.slice(1).map((f) => [f.label, f.hint]), [["1 problem", ""], ["Host", ""], ["OK", "GB10"], ["Warning", "swap is enabled"], ["Problem", "manager is missing"]])
  assert.strictEqual(fields({ available: true, running: false, doc: { healthy: true, problems: 0, items: [] } })[1].label, "Healthy")
  assert.strictEqual(fields({ available: true, running: false, error: "h didn't answer" })[1].hint, "h didn't answer")
  assert.ok(M.parseComfyDoctor(JSON.stringify({ path: "/p", doctor: doc })))
  assert.strictEqual(M.parseComfyDoctor("x"), null)
  assert.strictEqual(M.parseComfyDoctor("{}"), null)
})

test("comfyListPartial: a look that was cut short says so", () => {
  assert.strictEqual(M.comfyListPartial(JSON.stringify({ installs: [], partial: true })), true)
  assert.strictEqual(M.comfyListPartial(JSON.stringify({ installs: [], partial: false })), false)
  assert.strictEqual(M.comfyListPartial(JSON.stringify({ installs: [] })), false)
  assert.strictEqual(M.comfyListPartial("x"), false)
})

test("comfyPages: the Update buttons are on Manage with Forget; About only says things", () => {
  const info = M.comfyRow(oldTool({}), {})
  const ans = offer({ status: { comfy: { version: "v1", newer_release: "v2" } } })
  const pages = M.comfyPages({ host: "h", info: info, answer: ans, error: "", pending: "" })
  const keys = (title) => pages.find((p) => p.title === title).fields.map((f) => f.key)
  assert.deepStrictEqual(keys("Manage"), ["update", "update-comfyui", "forget"])
  assert.ok(M.comfyPages({ host: "h", info: info, answer: ans, error: "", pending: "" }).find((p) => p.title === "About").fields.every((f) => f.type === "info"), "About has nothing to click")
})
