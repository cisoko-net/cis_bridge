// check-workflow.js -- every `run:` block in the workflow has to be valid shell.
//
// A workflow step that does not parse as bash fails before it checks anything,
// and the run looks like a broken codebase rather than a broken workflow. This
// runs `bash -n` over every block before GitHub Actions does.
//
// It does not run the blocks. They need an apt install, a FiveM server, or a
// network; this only asks whether they are shell.
//
// Usage:  node tools/check-workflow.js
// Exit 0 clean, 1 on a block that does not parse.
//
// The extractor is written against this workflow's two-space indentation rather
// than a YAML library, because the failure it guards against is a workflow that
// is syntactically fine as YAML and broken as shell -- which a YAML parser would
// report as valid.
const fs = require('fs'), cp = require('child_process')
const lines = fs.readFileSync('.github/workflows/tests.yml', 'utf8').split('\n')
let blocks = [], cur = null, name = null
for (const line of lines) {
  const nm = line.match(/^ {6}- name: (.*)$/)
  if (nm) name = nm[1]
  if (/^ {8}run: \|\s*$/.test(line)) { cur = { name, body: [] }; blocks.push(cur); continue }
  if (cur) {
    if (line === '') { cur.body.push(''); continue }
    if (/^ {10}/.test(line)) { cur.body.push(line.slice(10)); continue }
    cur = null
  }
}
console.log('run blocks found:', blocks.length)
let bad = 0
for (const b of blocks) {
  const script = b.body.join('\n')
  const r = cp.spawnSync('bash', ['-n'], { input: script })
  if (r.status !== 0) {
    bad++
    console.log('--- BLOCK FAILS bash -n:', b.name)
    console.log(String(r.stderr).slice(0, 400))
  }
}
console.log(bad ? 'SYNTAX ERRORS: ' + bad : 'all run blocks parse as bash')

if (blocks.length === 0) {
  console.error('No `run:` blocks were found. The extractor no longer matches this workflow.')
  process.exit(1)
}
if (bad > 0) {
  process.exitCode = 1
}
