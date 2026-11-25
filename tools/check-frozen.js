// check-frozen.js -- the 1.x public surface has not moved.
//
// Why this exists
//
// 1.0.0 is the first public release of the v1 product API, and a product
// written against it must keep working on every 1.x. `npm run test:api` proves
// api.lua matches the code; it does not notice when api.lua itself changes,
// because a renamed export changed in both places at once is still consistent.
// So the surface a product depends on is written down once, in
// test/frozen.json, and this compares the live source against it:
//
//   - every frozen export is still declared, on the same realm, with the same
//     signature. It may become deprecated in a minor; it may not go away or
//     change shape before the next major.
//   - every frozen event is still fired by name somewhere in the shipped Lua.
//   - every frozen reason code is still answered somewhere in the shipped Lua,
//     and every code the shipped Lua answers is named in docs/V1.md
//     § Reason codes, so a product author can branch on it.
//
// A new export, event or documented code is allowed: that is a minor. Each
// release appends what it added with --append, which never drops or changes
// an entry already frozen, so the surface a minor shipped is guarded too.
// Write a new snapshot only for a new major, with --write.
//
// Usage:  node tools/check-frozen.js            exit 0 clean, 1 on a change
//         node tools/check-frozen.js --append   add new surface to test/frozen.json
//         node tools/check-frozen.js --write    rewrite test/frozen.json
const fs = require('fs')
const path = require('path')
const { loadManifest } = require('./validate-api.js')

const root = path.join(__dirname, '..')
const read = (rel) => fs.readFileSync(path.join(root, rel), 'utf8')
const FROZEN = path.join(root, 'test', 'frozen.json')

const loaded = loadManifest(path.join(root, 'api.lua'), path.join(root, 'api.lua'))
if (!loaded.table) {
  console.log(`  FAIL  api.lua did not load: ${loaded.error}`)
  process.exit(1)
}
const api = loaded.table
const major = Number(String(api.version).split('.')[0])

// The shipped Lua, read from the manifest so a file added later is covered.
const manifest = read('fxmanifest.lua')
const listed = [...manifest.matchAll(/['"]([^'"@]+\.lua)['"]/g)].map((m) => m[1])
const shipped = listed.map((rel) => read(rel)).join('\n')

// A reason code is the string after `false,` or `nil,` in a return.
const answered = new Set([...shipped.matchAll(/return\s+(?:false|nil)\s*,\s*'([a-z_]+)'/g)].map((m) => m[1]))

const v1 = read('docs/V1.md')
const reasonSection = (v1.split(/^## Reason codes\s*$/m)[1] || '').split(/^## /m)[0]
const documented = new Set([...reasonSection.matchAll(/`([a-z_]+)`/g)].map((m) => m[1]))
const eventSection = (v1.split(/^## Events\s*$/m)[1] || '').split(/^## /m)[0]
const documentedEvents = [...new Set([...eventSection.matchAll(/^\| `(cis_bridge:[A-Za-z]+)`/gm)].map((m) => m[1]))]

const sig = (s) => JSON.stringify(s)

if (process.argv.includes('--write') || process.argv.includes('--append')) {
  const append = process.argv.includes('--append')
  const old = append ? JSON.parse(fs.readFileSync(FROZEN, 'utf8')) : { exports: {}, events: [], reasons: [] }
  if (append && old.major !== major) {
    console.log(`  FAIL  --append keeps major ${old.major}; api.lua is ${api.version}`)
    process.exit(1)
  }
  const exports = { ...old.exports }
  for (const [name, meta] of Object.entries(api.exports || {}).sort(([a], [b]) => a.localeCompare(b))) {
    if (meta.stable === true && meta.deprecated !== true && !exports[name]) {
      exports[name] = { realm: meta.realm, signature: meta.signature }
    }
  }
  const out = {
    $comment: 'The public surface frozen for this major. tools/check-frozen.js compares the source against it; rewrite it only for a new major, with --write.',
    major,
    exports: Object.fromEntries(Object.entries(exports).sort(([a], [b]) => a.localeCompare(b))),
    events: [...new Set([...old.events, ...documentedEvents])].sort(),
    reasons: [...new Set([...old.reasons, ...documented])].sort(),
  }
  fs.writeFileSync(FROZEN, `${JSON.stringify(out, null, 2)}\n`)
  console.log(`wrote test/frozen.json: ${Object.keys(exports).length} exports, ${out.events.length} events, ${out.reasons.length} reason codes`)
  process.exit(0)
}

const frozen = JSON.parse(fs.readFileSync(FROZEN, 'utf8'))
let bad = 0
const fail = (m) => { console.log(`  FAIL  ${m}`); bad++ }
const pass = (m) => console.log(`  PASS  ${m}`)

if (major !== frozen.major) {
  fail(`api.lua is ${api.version} but test/frozen.json freezes major ${frozen.major}; for a new major, review the break and run node tools/check-frozen.js --write`)
}

let n = bad
for (const [name, want] of Object.entries(frozen.exports)) {
  const got = (api.exports || {})[name]
  if (!got) { fail(`frozen export ${name} is no longer declared in api.lua`); continue }
  if (got.realm !== want.realm) fail(`frozen export ${name} moved realm: ${want.realm} -> ${got.realm}`)
  if (sig(got.signature) !== sig(want.signature)) {
    fail(`frozen export ${name} changed signature: ${sig(want.signature)} -> ${sig(got.signature)}`)
  }
}
if (bad === n) pass(`all ${Object.keys(frozen.exports).length} frozen exports are declared with their realm and signature`)

n = bad
for (const ev of frozen.events) {
  if (!shipped.includes(`'${ev}'`)) fail(`frozen event ${ev} is no longer fired by name in the shipped Lua`)
  if (!documentedEvents.includes(ev)) fail(`frozen event ${ev} is no longer in docs/V1.md § Events`)
}
if (bad === n) pass(`all ${frozen.events.length} frozen events are fired and documented`)

n = bad
for (const code of frozen.reasons) {
  if (!shipped.includes(`'${code}'`)) fail(`frozen reason code ${code} is no longer answered by the shipped Lua`)
  if (!documented.has(code)) fail(`frozen reason code ${code} is no longer in docs/V1.md § Reason codes`)
}
for (const code of answered) {
  if (!documented.has(code)) fail(`the shipped Lua answers ${code}, which docs/V1.md § Reason codes does not name`)
}
if (bad === n) pass(`all ${frozen.reasons.length} frozen reason codes are answered and documented, and every answered code is documented`)

console.log('')
if (bad > 0) {
  console.log(`  ${bad} change(s) to the frozen ${frozen.major}.x surface.`)
  process.exit(1)
}
console.log(`  the ${frozen.major}.x surface is unchanged`)
