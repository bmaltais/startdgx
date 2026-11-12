// DgxModel.js is a QML library (.pragma library, no imports): load it as a plain script and hand back what it defines.
const fs = require("node:fs")
const path = require("node:path")

const source = fs.readFileSync(path.join(__dirname, "..", "..", "DgxModel.js"), "utf8").replace(/^\.pragma.*$/m, "")
const names = [...source.matchAll(/^(?:function|var)\s+([A-Za-z_]\w*)/gm)].map((m) => m[1])
module.exports = new Function(source + "\nreturn {" + names.join(", ") + "}")()
