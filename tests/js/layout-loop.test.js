// A list's scroll bar must never take itself out of its layout. A layout skips an invisible item, so a ScrollTrack whose
// `visible` followed the list's height changed the list's width, which re-wrapped its text and changed the height again:
// a loop that never settled while a floating window was resized, and froze the whole shell (one GUI thread) at 100%.
const test = require("node:test")
const assert = require("node:assert")
const fs = require("node:fs")
const path = require("node:path")

const read = (name) => fs.readFileSync(path.join(__dirname, "..", "..", name), "utf8")

test("ScrollTrack keeps its place in the layout and only fades", () => {
  const source = read("ScrollTrack.qml").replace(/\/\/.*$/gm, "")
  assert.ok(!/^\s*visible\s*:/m.test(source), "ScrollTrack must not bind visible: an invisible item leaves the layout")
  assert.match(source, /opacity\s*:\s*bar\.extent\s*>\s*1/)
})

test("the manager does not size itself from the height of its list", () => {
  const source = read("ManagerView.qml").replace(/\/\/.*$/gm, "")
  assert.ok(!/preferredHeight\s*:\s*\w*\.?contentHeight/.test(source), "the list's height request must not follow its content")
  assert.ok(!/^\s*implicitHeight\s*:/m.test(source), "the window sets the manager's size, not its content")
})
