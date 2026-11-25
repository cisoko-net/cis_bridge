// package.js -- build dist/cis_bridge-<version>.zip, the file a server owner
// downloads.
//
// Why this exists
//
// GitHub's "Source code (zip)" unpacks to `cis_bridge-<version>/`, carries the
// tests, tools and CI files, and a folder under that name is not the resource
// every product calls by `exports.cis_bridge`. This zip unpacks to exactly one
// folder, `cis_bridge/`, holding what the server loads plus the documents an
// owner reads, and nothing else.
//
// The file set is the manifest: every `.lua` that fxmanifest.lua lists, so a
// file added there is shipped without editing this list, and a listed file
// that is missing fails the build. Next to it go api.lua, the type stubs and
// the owner-facing documents.
//
// Reproducible. Entries are stored (no compression), sorted by name, and carry
// one fixed timestamp (SOURCE_DATE_EPOCH when set, else 1980-01-01 UTC), so the
// same tree builds the same bytes and a release zip can be checked by hash.
// The build runs twice and the two buffers are compared.
//
// Usage:  node tools/package.js
const crypto = require('crypto')
const fs = require('fs')
const path = require('path')

const root = path.join(__dirname, '..')
const read = (rel) => fs.readFileSync(path.join(root, rel))

// What an owner reads.
const DOCUMENTS = [
  'README.md',
  'CHANGELOG.md',
  'LICENSE.md',
  'SECURITY.md',
  'API.md',
  'DOCUMENTATION.md',
  'docs/INSTALL.md',
  'docs/V1.md',
  'api.lua',
  'types/cis_bridge.lua',
]

function fileSet() {
  const manifest = read('fxmanifest.lua').toString('utf8')
  const listed = [...manifest.matchAll(/['"]([^'"@]+\.lua)['"]/g)].map((m) => m[1])
  const all = [...new Set(['fxmanifest.lua', ...listed, ...DOCUMENTS])]
  const missing = all.filter((rel) => !fs.existsSync(path.join(root, rel)))
  return { all, missing }
}

function crc32(buf) {
  let c = ~0
  for (let i = 0; i < buf.length; i++) {
    c ^= buf[i]
    for (let k = 0; k < 8; k++) c = (c >>> 1) ^ (0xedb88320 & -(c & 1))
  }
  return ~c >>> 0
}

function stamp() {
  const raw = process.env.SOURCE_DATE_EPOCH
  const epoch = Date.UTC(1980, 0, 1)
  if (raw === undefined || raw === '') return new Date(epoch)
  if (!/^\d+$/.test(raw)) throw new Error(`SOURCE_DATE_EPOCH must be whole seconds, got ${JSON.stringify(raw)}`)
  return new Date(Math.max(Number(raw) * 1000, epoch))
}

function zipStore(entries, when) {
  const time = ((when.getUTCSeconds() / 2) | 0) | (when.getUTCMinutes() << 5) | (when.getUTCHours() << 11)
  const date = when.getUTCDate() | ((when.getUTCMonth() + 1) << 5) | ((when.getUTCFullYear() - 1980) << 9)
  const sorted = entries.slice().sort((a, b) => Buffer.compare(Buffer.from(a.name), Buffer.from(b.name)))
  const locals = []
  const centrals = []
  let offset = 0
  for (const e of sorted) {
    const name = Buffer.from(e.name, 'utf8')
    const crc = crc32(e.data)
    const local = Buffer.alloc(30)
    local.writeUInt32LE(0x04034b50, 0)
    local.writeUInt16LE(20, 4)
    local.writeUInt16LE(0x0800, 6) // names are UTF-8
    local.writeUInt16LE(0, 8)
    local.writeUInt16LE(time, 10)
    local.writeUInt16LE(date, 12)
    local.writeUInt32LE(crc, 14)
    local.writeUInt32LE(e.data.length, 18)
    local.writeUInt32LE(e.data.length, 22)
    local.writeUInt16LE(name.length, 26)
    local.writeUInt16LE(0, 28)
    const full = Buffer.concat([local, name, e.data])
    locals.push(full)
    const central = Buffer.alloc(46)
    central.writeUInt32LE(0x02014b50, 0)
    central.writeUInt16LE(20, 4)
    central.writeUInt16LE(20, 6)
    central.writeUInt16LE(0x0800, 8)
    central.writeUInt16LE(0, 10)
    central.writeUInt16LE(time, 12)
    central.writeUInt16LE(date, 14)
    central.writeUInt32LE(crc, 16)
    central.writeUInt32LE(e.data.length, 20)
    central.writeUInt32LE(e.data.length, 24)
    central.writeUInt16LE(name.length, 28)
    central.writeUInt32LE(offset, 42)
    centrals.push(Buffer.concat([central, name]))
    offset += full.length
  }
  const dir = Buffer.concat(centrals)
  const end = Buffer.alloc(22)
  end.writeUInt32LE(0x06054b50, 0)
  end.writeUInt16LE(sorted.length, 8)
  end.writeUInt16LE(sorted.length, 10)
  end.writeUInt32LE(dir.length, 12)
  end.writeUInt32LE(offset, 16)
  return Buffer.concat([...locals, dir, end])
}

function main() {
  const version = JSON.parse(read('package.json').toString('utf8')).version
  const { all, missing } = fileSet()
  if (missing.length) {
    console.log(`  FAIL  listed but missing: ${missing.join(', ')}`)
    process.exit(1)
  }
  // Text files keep the bytes git checked out, but a Windows checkout with
  // core.autocrlf would ship CRLF; normalise so the zip does not depend on it.
  const entries = all.map((rel) => ({ name: `cis_bridge/${rel}`, data: Buffer.from(read(rel).toString('utf8').replace(/\r\n/g, '\n'), 'utf8') }))
  const when = stamp()
  const a = zipStore(entries, when)
  const b = zipStore(entries, when)
  if (!a.equals(b)) {
    console.log('  FAIL  two builds of the same tree differ')
    process.exit(1)
  }
  const out = path.join(root, 'dist', `cis_bridge-${version}.zip`)
  fs.mkdirSync(path.dirname(out), { recursive: true })
  fs.writeFileSync(out, a)
  const sha = crypto.createHash('sha256').update(a).digest('hex')
  console.log(`  PASS  ${all.length} files under cis_bridge/, ${a.length} bytes, two builds identical`)
  console.log(`  ${path.relative(root, out)}  sha256 ${sha}`)
}

main()
