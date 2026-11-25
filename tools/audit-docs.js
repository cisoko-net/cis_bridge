// audit-docs.js -- is the DOCUMENTATION true?
//
// `npm run test:api` proves api.lua matches the source. `docs:check` proves
// API.md is what the generator would write. Neither asks whether the prose is
// right, and the prose is where documentation actually fails: an export that is
// declared and generated correctly but never mentioned in DOCUMENTATION.md is
// an export nobody can find, and a claim in a table that stopped being true is
// worse than no table.
//
// Written as a script rather than a shell one-liner because the thing being
// checked is spread across four files and a regex-in-a-string stopped working
// the moment a path separator changed.
//
// Usage:  node tools/audit-docs.js
// Exit 0 clean, 1 on a finding.
const fs = require('fs')
const path = require('path')
const { loadManifest } = require('./validate-api.js')
const { scanResource } = require('./lua-exports.js')

const root = path.join(__dirname, '..')
const read = (rel) => (fs.existsSync(path.join(root, rel))
  ? fs.readFileSync(path.join(root, rel), 'utf8') : null)

const api = loadManifest(path.join(root, 'api.lua'), path.join(root, 'api.lua')).table
const surface = scanResource(root)
const apiMd = read('API.md') || ''
const types = read('types/cis_bridge.lua') || ''
const doc = read('DOCUMENTATION.md') || ''
const readme = read('README.md') || ''

let bad = 0
const fail = (m) => { console.log(`  FAIL  ${m}`); bad++ }
const pass = (m) => console.log(`  PASS  ${m}`)

// ---------------------------------------------------------------- 1. Realms
//
// The scanner derives realm from which manifest section loads the file, so it
// is the authority here and api.lua is the claim being checked. Checking it a
// second way -- by re-parsing fxmanifest.lua with a regex -- is how a check
// ends up disagreeing with the thing it checks.
const scanned = new Map(surface.exports.map((e) => [e.name, e]))
let realmOk = true
for (const [name, spec] of Object.entries(api.exports || {})) {
  const found = scanned.get(name)
  // 'both' is one name exported from each realm; the scanner keeps one entry
  // per name, so the claim is checked against every entry it saw.
  if (spec.realm === 'both') {
    const realms = new Set(surface.exports.filter((e) => e.name === name).map((e) => e.realm))
    if (!(realms.has('server') && realms.has('client'))) {
      fail(`${name}: api.lua says realm=both, the manifest loads it as ${[...realms].join(', ') || 'nothing'}`)
      realmOk = false
    }
    continue
  }
  if (found && found.realm !== spec.realm) {
    fail(`${name}: api.lua says realm=${spec.realm}, the manifest loads it as ${found.realm}`)
    realmOk = false
  }
}
if (realmOk) pass(`all ${Object.keys(api.exports || {}).length} exports agree with the realm their file is loaded in`)

// ------------------------------------------------------------ 2. API.md covers
for (const [name, spec] of Object.entries(api.exports || {})) {
  if (!apiMd.includes('`' + name + '`')) fail(`API.md does not mention ${name}`)
  if (!types.includes(`cis_bridge.${name}`)) fail(`types/cis_bridge.lua has no class for ${name}`)
  // Every export must be reachable from DOCUMENTATION too, or it is an export
  // an integrator cannot find. Section references are prose, so this is a
  // presence check rather than a link check.
  if (!doc.includes(name)) fail(`DOCUMENTATION.md never mentions ${name}`)
}
if (bad === 0) pass('API.md, types and DOCUMENTATION.md all name every export')

// ------------------------------------------- 3. API.md stability matches api.lua
for (const [name, spec] of Object.entries(api.exports || {})) {
  const found = scanned.get(name)
  if (!found) continue
  // The row's "Declared in" cell must name the file the scanner found.
  if (!apiMd.includes(`\`${found.file}\``)) {
    fail(`API.md has no row naming ${found.file} for ${name}`)
  }
}
if (bad === 0) pass('API.md names the file each export is actually declared in')

// A deprecated export must be labelled deprecated in both generated files, and
// must not be labelled stable.
for (const [name, spec] of Object.entries(api.exports || {})) {
  if (spec.deprecated !== true) continue
  const row = apiMd.split('\n').find((l) => l.includes('`' + name + '`') && l.startsWith('|'))
  if (!row) { fail(`API.md has no table row for the deprecated export ${name}`); continue }
  if (!row.includes('deprecated')) fail(`API.md does not mark ${name} as deprecated`)
  if (row.includes('| stable |')) fail(`API.md marks the deprecated export ${name} as stable`)
  const cls = types.split('\n').find((l) => l.includes(`cis_bridge.${name}`))
  if (!cls) fail(`types has no class for the deprecated export ${name}`)
  const deprecatedMarker = types.split('\n').slice(0, types.split('\n').indexOf(cls))
  if (!deprecatedMarker.includes('---@deprecated')) {
    fail(`types/cis_bridge.lua does not carry ---@deprecated for ${name}`)
  }
}
if (bad === 0) pass('every deprecated export is marked deprecated in API.md and in the types')

// ------------------------------------------------ 4. The v1 contract doc
//
// docs/V1.md is the contract a product is written against. An export in
// api.lua that V1.md never names is an export a product author cannot find,
// which in practice means one they reimplement by reaching for the framework.
// The conformance, report and shim exports are operator and migration tools,
// not product API, so they are documented in DOCUMENTATION.md instead.
const v1 = read('docs/V1.md') || ''
const OPERATOR = new Set(['RunConformance', 'GetConformanceResults', 'GetBridgeReport', 'GetLibShim', 'GetDbProxy'])
let v1Ok = true
for (const name of Object.keys(api.exports || {})) {
  if (OPERATOR.has(name)) continue
  if (!v1.includes(name)) { fail(`docs/V1.md never names the v1 export ${name}`); v1Ok = false }
}
if (v1Ok) pass('docs/V1.md names every product export')

// ------------------------------------------- 5. The RUNBOOK'S commands exist
//
// The source scanned is every Lua file the manifest loads, read from the
// manifest itself, so a file added later is covered without editing a list.
const manifest = read('fxmanifest.lua') || ''
const listed = [...manifest.matchAll(/['"]([^'"@]+\.lua)['"]/g)].map((m) => m[1])
const shippedLua = listed.map((rel) => read(rel) || '').join('\n')
const runbook = read('test/live/RUNBOOK.md') || ''
for (const cmd of [...runbook.matchAll(/^\s*(cis_bridge\w*)(\s|$)/gm)].map((m) => m[1])) {
  if (!shippedLua.includes(`RegisterCommand('${cmd}'`)) {
    fail(`the runbook tells an operator to run \`${cmd}\`, which is not registered`)
  }
}
pass('every command the runbook names is registered in the shipped Lua')

// ------------------------------------------- 6. Every adapter is accounted for
//
// One file per third-party target is the unit of support. A file on disk that
// is not in this table is an adapter nobody decided to ship; a name in the
// table with no file is a target the README promises and the code lacks.
const names = {
  target: ['ox', 'qb'],
  inventory: ['cis_inventory', 'ox', 'qb', 'qs', 'codem'],
  framework: ['common', 'esx', 'qbcore', 'qbox', 'cis_core'],
  doors: ['ox_doorlock', 'qb_doorlock'],
  appearance: ['common', 'illenium', 'fivem_appearance', 'qb_clothing', 'skinchanger'],
  billing: ['esx_billing'],
}
// adapters/custom.lua is the owner's own file (empty as shipped), the one
// file directly under adapters/, and the manifest loads it after the rest.
const files = []
for (const dir of fs.readdirSync(path.join(root, 'adapters'))) {
  if (dir === 'custom.lua') {
    if (!manifest.includes("'adapters/custom.lua'")) fail('the manifest does not load adapters/custom.lua')
    continue
  }
  for (const file of fs.readdirSync(path.join(root, 'adapters', dir))) {
    files.push(`${dir}/${file.replace(/\.lua$/, '')}`)
  }
}
for (const dir of Object.keys(names)) {
  for (const n of names[dir]) {
    if (!files.includes(`${dir}/${n}`)) fail(`the adapter ${dir}/${n}.lua does not exist`)
    if (!manifest.includes(`'adapters/${dir}/${n}.lua'`)) fail(`the manifest does not load adapters/${dir}/${n}.lua`)
  }
}
const extra = files.filter((x) => { const [d, n] = x.split('/'); return !(names[d] || []).includes(n) })
if (extra.length > 0) fail(`unexpected adapter files: ${extra.join(', ')}`)
pass(`all ${files.length} adapter files are accounted for and loaded by the manifest`)

console.log('')
if (bad > 0) {
  console.log(`  ${bad} finding(s). The documentation is not yet telling the truth.`)
  process.exit(1)
}
console.log('  documentation agrees with the source')
