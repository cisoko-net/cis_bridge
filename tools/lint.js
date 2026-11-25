// lint.js -- run luacheck, and fail when it is not there.
//
// `npm run test:syntax` checks that every file parses, with fengari and nothing
// else installed. This runs luacheck for the rest: unused locals, shadowed
// names, accidental globals. luacheck is a luarock, not an npm package, so
// `npm ci` does not bring it; install it with `luarocks install luacheck`.
//
// An absent luacheck is a failure, because "no findings" from a check that did
// not run is not a pass. Set LUACHECK_OPTIONAL=1 to skip it on purpose; the
// run then says it was skipped and exits 0.
//
// On Windows the call goes through a shell, so a missing executable is not a
// spawn error: the shell prints "'luacheck' is not recognized ..." and exits 1,
// the same status as one finding. The message text is what tells them apart.
//
// Usage:  node tools/lint.js
// Exit 0 clean, 1 on a finding or when luacheck is absent, 0-and-warned when
// absent with LUACHECK_OPTIONAL=1.
const { spawnSync } = require('child_process')
const path = require('path')

const root = path.join(__dirname, '..')
const useShell = process.platform === 'win32'

function probe() {
  const r = spawnSync('luacheck', ['--version'], {
    cwd: root,
    encoding: 'utf8',
    shell: useShell,
  })
  const output = `${r.stdout || ''}${r.stderr || ''}`
  const notFound = r.error !== undefined && r.error !== null
    || /not recognized|not found|command not found|no such file/i.test(output)
  return { available: !notFound, output }
}

if (!probe().available) {
  const optional = process.env.LUACHECK_OPTIONAL === '1'
  console.warn('')
  console.warn(optional
    ? '  luacheck is not installed and LUACHECK_OPTIONAL=1, so this check was skipped.'
    : '  luacheck is not installed, so this check did not run, and that is a failure.')
  console.warn('  Install it with:  luarocks install luacheck')
  console.warn('')
  process.exit(optional ? 0 : 1)
}

const result = spawnSync('luacheck', ['.'], {
  cwd: root,
  stdio: 'inherit',
  shell: useShell,
})

process.exit(result.status === null ? 1 : result.status)
