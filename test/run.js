const fs = require('fs')
const path = require('path')
const fengari = require('fengari')

const lua = fengari.lua
const lauxlib = fengari.lauxlib
const lualib = fengari.lualib
const toLua = fengari.to_luastring

const root = path.join(__dirname, '..')

// fengari's default package.path is the process working directory. Rooting it
// here means a `require` in a suite resolves the same from any directory.
const LUA_PATH = root.replace(/\\/g, '/') + '/?.lua'

// A fresh interpreter per suite. The resource keeps state in file locals, so a
// shared interpreter would let one suite read what another left behind and
// make the result depend on suite order.
function newState() {
  const L = lauxlib.luaL_newstate()
  lualib.luaL_openlibs(L)
  lauxlib.luaL_dostring(L, toLua(`package.path = ${JSON.stringify(LUA_PATH)}`))
  return L
}

function runFile(L, rel) {
  const src = fs.readFileSync(path.join(root, rel), 'utf8')
  const status = lauxlib.luaL_dostring(L, toLua(src))
  if (status !== lua.LUA_OK) {
    const err = lua.lua_tojsstring(L, -1)
    throw new Error(`${rel}: ${err}`)
  }
}

// Read a global off the Lua stack and leave the stack as it was found.
//
// `lua_getglobal` pushes, so the value has to be popped whatever it turns out to
// be. `-2` is the standard "pop one" index; writing it as `-(2) - 1` produces
// -3, which asks Lua to shrink the stack below its base and raises "invalid new
// top" -- a crash in the harness that reads exactly like a crash in the code
// under test.
function readGlobal(L, name) {
  lua.lua_getglobal(L, toLua(name))
  const value = lua.lua_toboolean(L, -1)
  lua.lua_settop(L, -2)
  return value
}

// Comments stripped, string contents preserved.
function stripComments(src) {
  let out = ''
  let i = 0
  const n = src.length
  while (i < n) {
    const c = src[i]
    const d = src[i + 1]
    if (c === '-' && d === '-') {
      const open = /^--\[(=*)\[/.exec(src.slice(i))
      if (open) {
        const close = `]${open[1]}]`
        const end = src.indexOf(close, i + open[0].length)
        i = end < 0 ? n : end + close.length
        out += ' '
        continue
      }
      const end = src.indexOf('\n', i)
      i = end < 0 ? n : end
      out += ' '
      continue
    }
    if (c === '"' || c === "'") {
      const quote = c
      out += c
      i++
      while (i < n) {
        if (src[i] === '\\') {
          out += src.slice(i, i + 2)
          i += 2
          continue
        }
        out += src[i]
        if (src[i] === quote) {
          i++
          break
        }
        i++
      }
      continue
    }
    if (c === '\n') {
      out += ' '
      i++
      continue
    }
    out += c
    i++
  }
  return out
}

// Comments stripped and string contents neutralised, keeping only the
// identifier characters.
//
// Every non-word character inside a string literal becomes `_`, so:
//
//   'Cis.target.* is a client surface'   ->  _Cis_target__is_a_client_surface_
//   exports['cis_libs']:WaitReady        ->  exports[_cis_libs_]:WaitReady
//
// Which solves a real problem. A compliance rule that matches `Cis.target.` also
// matches it inside a user-facing message -- and the first version of the realm
// rule failed the server suite on the string it had written to explain that
// `Cis.target` is a client surface. A rule that fires on prose is a rule whose
// exemption list grows until nobody trusts it.
//
// Identifiers survive, so `exports[_cis_libs_]:WaitReady` is still matchable with
// the brackets relaxed, and `Cis.target.add(` in real code is untouched.
function neutraliseStrings(src) {
  let out = ''
  let i = 0
  const n = src.length
  while (i < n) {
    const c = src[i]
    const d = src[i + 1]
    if (c === '-' && d === '-') {
      const open = /^--\[(=*)\[/.exec(src.slice(i))
      if (open) {
        const close = `]${open[1]}]`
        const end = src.indexOf(close, i + open[0].length)
        i = end < 0 ? n : end + close.length
        out += ' '
        continue
      }
      const end = src.indexOf('\n', i)
      i = end < 0 ? n : end
      out += ' '
      continue
    }
    if (c === '"' || c === "'") {
      const quote = c
      out += c
      i++
      while (i < n) {
        if (src[i] === '\\') {
          out += ' '
          i += 2
          continue
        }
        if (src[i] === quote) {
          out += quote
          i++
          break
        }
        // `[%w_]` survives; everything else in a string becomes `_`.
        out += /[A-Za-z0-9_]/.test(src[i]) ? src[i] : '_'
        i++
      }
      continue
    }
    if (c === '\n') {
      out += ' '
      i++
      continue
    }
    out += c
    i++
  }
  return out
}

// Everything a source-reading suite wants to audit, in one table keyed by
// relative path with forward slashes.
function loadSources(dir, out = {}, bare = {}, depth = 0) {
  const SKIP = new Set(['node_modules', '.git', 'reports', 'cache'])
  if (depth > 8) return out
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (SKIP.has(entry.name)) continue
    const abs = path.join(dir, entry.name)
    if (entry.isDirectory()) {
      loadSources(abs, out, bare, depth + 1)
    } else if (entry.name.endsWith('.lua')) {
      const raw = fs.readFileSync(abs, 'utf8')
      const key = path.relative(root, abs).split(path.sep).join('/')
      out[key] = stripComments(raw)
      bare[key] = neutraliseStrings(raw)
    }
  }
  return out
}

// Each suite names its own file, and may name the fact that it wants the source
// read from disk. `test/contract.lua` is the reason that flag exists: fengari
// has no filesystem, so `io.open` answers nil and a suite that reads the code it
// is auditing cannot run at all. It died on the first call, with "attempt to call
// a nil value (field 'open')" -- which reads like a Lua bug and is actually the
// VM having no disk.
//
// The assertions stay in Lua. The knowledge about which rule exists, and why, is
// the expensive part and does not belong in a harness. Only the bytes come from
// here, because only the harness can get them.
//
// No suite calls os.exit. It would take the whole process down mid-run, so a
// failure in one file was reported against the previous one and the rest never
// ran at all. Each sets the global `__suite_failed` instead, and the exit code
// is decided here -- after every suite has run and every suite has reported.
const SUITES = [
  { file: 'test/report.lua' },
  { file: 'test/ratelimit.lua' },
  { file: 'test/contract.lua', reads: true },
  { file: 'test/globals.lua' },
  { file: 'test/handler.lua' },
  { file: 'test/perf.lua', reads: true },
  { file: 'test/runner.lua' },
  { file: 'test/shim.lua' },
  { file: 'test/v1.lua' },
  { file: 'test/v1-client.lua' },
  { file: 'test/callers.lua' },
]

// A Lua long-bracket string, chosen so no escaping is needed at all.
//
// A source file can contain any byte except a newline -- and it always contains
// newlines -- so `[[ ... ]]` with a leading newline is the form that needs no
// escape sequence. `[==[ ... ]==]` nests, so a file that itself contains `]==]`
// still round-trips; the level is chosen as one more than the longest run of
// `=` appearing anywhere in the file.
function luaLongString(s) {
  // The level must be one no `]=*]` in the source matches, `]]` included
  // (`t[k[1]]`), and the source's own last `]=*` must not join the close.
  let level = 0
  while ((s + ']').includes(']' + '='.repeat(level) + ']')) level++
  const open = '[' + '='.repeat(level) + '['
  const close = ']' + '='.repeat(level) + ']'
  return `${open}\n${s}${close}`
}

// Sources go to Lua as a table constructor, `["path"] = [[source]]`, not as
// JSON. A value is either a source file (a string) or a documented return
// shape (an array of strings).
function luaValue(v) {
  if (typeof v === 'string') return luaLongString(v)
  if (Array.isArray(v)) {
    return '{ ' + v.map((x) => luaLongString(String(x))).join(', ') + ' }'
  }
  return luaLongString(String(v))
}

function luaTableString(map) {
  const parts = Object.keys(map).map((k) =>
    `  [${JSON.stringify(k)}] = ${luaValue(map[k])}`)
  return `{\n${parts.join(',\n')}\n}`
}

let failed = false
for (const suite of SUITES) {
  const L = newState()
  if (suite.reads) {
    const bare = {}
    const sources = loadSources(root, {}, bare)
    // A source the harness could not read is a hard failure, not a silent skip:
    // a suite that audits only the files it could open would report the rest
    // clean.
    const st = lauxlib.luaL_dostring(
      L, toLua(`__SOURCES = ${luaTableString(sources)}
__BARE = ${luaTableString(bare)}`))
    if (st !== lua.LUA_OK) {
      throw new Error(`could not hand sources to ${suite.file}: ${lua.lua_tojsstring(L, -1)}`)
    }
  }
  // A suite that raises part-way is a failed suite, not a crashed harness: the
  // rest still run, and the line says which file died and why. Thrown out of
  // here it ended the process with a Node stack trace and no FAIL line, which
  // the mutation gate cannot tell apart from a runner that never started.
  try {
    runFile(L, suite.file)
  } catch (e) {
    console.error(`FAIL(${suite.file}): suite raised: ${e.message}`)
    failed = true
    continue
  }
  if (readGlobal(L, '__suite_failed')) {
    failed = true
  }
}

if (failed) {
  process.exitCode = 1
}
