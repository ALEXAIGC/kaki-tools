const { test } = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { spawnSync } = require('node:child_process')

const script = path.join(__dirname, '../scripts/install-local-update.sh')
const shellQuote = value => "'" + value.replace(/'/g, "'\\''") + "'"

function fixture(t, options = {}) {
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'kaki-local-update-test-')))
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const source = path.join(root, 'source', 'Kaki Tools.app')
  const installed = path.join(root, 'installed', 'Kaki Tools.app')
  const backups = path.join(root, 'backups')
  const staging = path.join(root, 'staging')
  const tools = path.join(root, 'tools')
  const userData = path.join(root, 'user-data')
  for (const dir of [source, installed, staging, tools]) fs.mkdirSync(dir, { recursive: true })
  fs.writeFileSync(path.join(source, 'version'), 'new')
  fs.writeFileSync(path.join(installed, 'version'), 'old')
  fs.mkdirSync(path.join(userData, 'images'), {recursive:true})
  fs.mkdirSync(path.join(userData, 'deskflow'), {recursive:true})
  fs.mkdirSync(path.join(userData, 'updates'), {recursive:true})
  fs.mkdirSync(path.join(userData, 'Cache'), {recursive:true})
  fs.writeFileSync(path.join(userData, 'history.json'), JSON.stringify({items:Array.from({length:500},(_,i)=>({id:i,text:'fixture-'+i}))}))
  fs.writeFileSync(path.join(userData, 'history.backup.json'), '{"items":[]}')
  fs.writeFileSync(path.join(userData, 'settings.json'), '{"maxHistoryItems":500}')
  fs.writeFileSync(path.join(userData, 'images','sample.png'), 'fixture image')
  fs.writeFileSync(path.join(userData, 'deskflow','layout.json'), '{"fixture":true}')
  fs.writeFileSync(path.join(userData, 'updates','excluded.txt'), 'excluded update')
  fs.writeFileSync(path.join(userData, 'Cache','excluded.txt'), 'excluded cache')
  const config = path.join(root, 'config.json')
  const state = path.join(root, 'state.json')
  const trace = path.join(root, 'trace.jsonl')
  fs.writeFileSync(config, JSON.stringify({ root, source, installed, backups, staging, userData, ...options }))
  fs.writeFileSync(state, JSON.stringify({ alive: !!options.running, reused: false }))
  const runner = path.join(tools, 'runner.cjs')
  fs.writeFileSync(runner, `
const fs = require('node:fs'), path = require('node:path')
const command = process.argv[2], args = process.argv.slice(3)
const config = JSON.parse(fs.readFileSync(process.env.KAKI_TEST_CONFIG))
const stateFile = process.env.KAKI_TEST_STATE
const state = JSON.parse(fs.readFileSync(stateFile))
const save = () => fs.writeFileSync(stateFile, JSON.stringify(state))
fs.appendFileSync(process.env.KAKI_TEST_TRACE, JSON.stringify({command,args}) + '\\n')
const main = '/private/var/folders/test/AppTranslocation/id/d/Kaki Tools.app/Contents/MacOS/Kaki Tools'
const identity = 'Fri Oct  2 12:00:00 2026 ' + main
const version = file => { try { return fs.readFileSync(path.join(file,'version'),'utf8') } catch { return '' } }
switch (command) {
  case 'codesign': {
    const target = args.at(-1)
    if (config.failSource && target === config.source) process.exit(1)
    if (config.failStage && target.startsWith(config.staging + path.sep)) process.exit(1)
    if (config.failInstalled && target === config.installed && version(target) === 'new') process.exit(config.failInstalledExit || 1)
    break
  }
  case 'ditto':
    if (config.failDataCopy && args.at(-2).startsWith(config.userData + path.sep)) process.exit(1)
    fs.cpSync(args.at(-2), args.at(-1), {recursive:true}); break
  case 'mv': {
    if (config.failMove && args[0].startsWith(config.staging + path.sep)) process.exit(1)
    fs.renameSync(args[0], args[1]); break
  }
  case 'ps':
    if (args.includes('-axo')) {
      if (state.alive) process.stdout.write('43210 ' + main + '\\n')
      process.stdout.write('43211 ' + main + ' Helper\\n43212 /Applications/Other.app/Contents/MacOS/Other\\n')
    } else if (args.includes('43210') && state.alive) {
      process.stdout.write(state.reused ? 'Fri Oct  2 12:00:01 2026 /Applications/Other.app/Contents/MacOS/Other\\n' : identity + '\\n')
    } else process.exit(1)
    break
  case 'kill':
    if (args[1] !== '43210') process.exit(2)
    if (args[0] === '-TERM') {
      if (config.reusePid) state.reused=true
      else if (!config.stubborn) state.alive=false
    } else if (args[0] === '-KILL') state.alive=false
    save(); break
  case 'sleep': case 'open': break
  default: process.exit(2)
}
`)
  const env = {
    ...process.env, KAKI_UPDATE_TEST_MODE: '1', KAKI_UPDATE_TEST_ROOT: root,
    KAKI_UPDATE_SOURCE_APP: source, KAKI_UPDATE_INSTALLED_APP: installed,
    KAKI_UPDATE_BACKUP_DIR: backups, KAKI_UPDATE_STAGE_BASE: staging, KAKI_UPDATE_USER_DATA_DIR: userData,
    KAKI_TEST_CONFIG: config, KAKI_TEST_STATE: state, KAKI_TEST_TRACE: trace,
  }
  for (const command of ['codesign', 'ditto', 'ps', 'kill', 'sleep', 'open', 'mv']) {
    const executable = path.join(tools, command)
    fs.writeFileSync(executable, '#!/bin/sh\nexec ' + shellQuote(process.execPath) + ' ' + shellQuote(runner) + ' ' + shellQuote(command) + ' "$@"\n', { mode: 0o700 })
    env['KAKI_UPDATE_' + command.toUpperCase()] = executable
  }
  const run = () => spawnSync('/bin/bash', [script], { env, encoding: 'utf8', timeout: 15000 })
  const entries = () => fs.existsSync(trace) ? fs.readFileSync(trace,'utf8').trim().split('\n').filter(Boolean).map(JSON.parse) : []
  const roots = () => fs.existsSync(backups) ? fs.readdirSync(backups).map(name => path.join(backups,name)) : []
  return { root, source, installed, backups, staging, userData, env, run, entries, roots }
}

test('local update verifies copies, installs the new version and keeps a unique old-version backup', t => {
  const f = fixture(t)
  const result = f.run()
  assert.equal(result.status, 0, result.stderr)
  assert.equal(fs.readFileSync(path.join(f.installed,'version'),'utf8'), 'new')
  const [backupRoot] = f.roots()
  assert.equal(fs.readFileSync(path.join(backupRoot,'Kaki Tools.app','version'),'utf8'), 'old')
  assert.match(result.stdout, /上一版本备份：/)
  const dataBackup = path.join(backupRoot, 'user-data')
  assert.deepEqual(fs.readdirSync(dataBackup).sort(), ['deskflow','history.backup.json','history.json','images','settings.json'])
  assert.equal(fs.readFileSync(path.join(dataBackup,'history.json'),'utf8'), fs.readFileSync(path.join(f.userData,'history.json'),'utf8'))
  assert.equal(fs.readFileSync(path.join(dataBackup,'settings.json'),'utf8'), '{"maxHistoryItems":500}')
  assert.equal(fs.readFileSync(path.join(dataBackup,'images','sample.png'),'utf8'), 'fixture image')
  assert.equal(fs.readFileSync(path.join(dataBackup,'deskflow','layout.json'),'utf8'), '{"fixture":true}')
  assert.equal(f.entries().filter(entry => entry.command === 'codesign').length, 4)
  assert.equal(f.entries().filter(entry => entry.command === 'open').length, 1)
  assert.deepEqual(fs.readdirSync(f.staging), [])
  const second = f.run()
  assert.equal(second.status, 0, second.stderr)
  assert.equal(f.roots().length, 2)
})

test('post-install signature failure isolates the new version and restores the verified old app', t => {
  const f = fixture(t, { failInstalled: true })
  const result = f.run()
  assert.notEqual(result.status, 0)
  assert.equal(fs.readFileSync(path.join(f.installed,'version'),'utf8'), 'old')
  const [backupRoot] = f.roots()
  assert.equal(fs.readFileSync(path.join(backupRoot,'failed-Kaki Tools.app','version'),'utf8'), 'new')
  assert.equal(fs.existsSync(path.join(backupRoot,'Kaki Tools.app')), false)
  assert.match(result.stderr, /已恢复上一版本/)
  assert.equal(f.entries().filter(entry => entry.command === 'open').length, 0)
  assert.equal(f.entries().filter(entry => entry.command === 'codesign').length, 5)
})

test('an unexpected move failure after backup triggers EXIT rollback', t => {
  const f = fixture(t, { failMove: true })
  const result = f.run()
  assert.notEqual(result.status, 0)
  assert.equal(fs.readFileSync(path.join(f.installed,'version'),'utf8'), 'old')
  assert.match(result.stderr, /已恢复上一版本/)
  assert.deepEqual(fs.readdirSync(f.staging), [])
  assert.equal(f.entries().filter(entry => entry.command === 'open').length, 0)
})

test('a staging signature failure leaves the installed app and its process untouched', t => {
  const f = fixture(t, { failStage: true, running: true })
  const result = f.run()
  assert.notEqual(result.status, 0)
  assert.equal(fs.readFileSync(path.join(f.installed,'version'),'utf8'), 'old')
  assert.equal(f.entries().filter(entry => entry.command === 'kill').length, 0)
  assert.equal(f.roots().length, 0)
  assert.deepEqual(fs.readdirSync(f.staging), [])
})

test('an AppTranslocation main process receives graceful termination without targeting helpers', t => {
  const f = fixture(t, { running: true })
  const result = f.run()
  assert.equal(result.status, 0, result.stderr)
  assert.deepEqual(f.entries().filter(entry => entry.command === 'kill').map(entry => entry.args), [['-TERM','43210']])
})

test('a stubborn verified process gets five seconds to exit before forced termination', t => {
  const f = fixture(t, { running: true, stubborn: true })
  const result = f.run()
  assert.equal(result.status, 0, result.stderr)
  const entries = f.entries()
  assert.deepEqual(entries.filter(entry => entry.command === 'kill').map(entry => entry.args), [['-TERM','43210'],['-KILL','43210']])
  assert.equal(entries.filter(entry => entry.command === 'sleep' && entry.args[0] === '0.2').length, 25)
})

test('a reused PID is never force-killed after its process identity changes', t => {
  const f = fixture(t, { running: true, stubborn: true, reusePid: true })
  const result = f.run()
  assert.equal(result.status, 0, result.stderr)
  assert.deepEqual(f.entries().filter(entry => entry.command === 'kill').map(entry => entry.args), [['-TERM','43210']])
})

test('test mode rejects destination overrides outside its isolated root', t => {
  const f = fixture(t)
  f.env.KAKI_UPDATE_INSTALLED_APP = '/Applications/Kaki Tools.app'
  const result = f.run()
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /测试覆盖路径必须位于测试根目录/)
  assert.equal(f.entries().length, 0)
  assert.equal(fs.readFileSync(path.join(f.installed,'version'),'utf8'), 'old')
})


test('an interrupted verification subprocess triggers rollback while preserving its exit status', t => {
  const f = fixture(t, { failInstalled: true, failInstalledExit: 143 })
  const result = f.run()
  assert.equal(result.status, 143)
  assert.equal(fs.readFileSync(path.join(f.installed,'version'),'utf8'), 'old')
  assert.match(result.stderr, /已恢复上一版本/)
  assert.equal(f.entries().filter(entry => entry.command === 'open').length, 0)
})


test('rollback reopens only the verified old app when the previous instance was running', t => {
  const f = fixture(t, { running:true, failInstalled:true })
  const result = f.run()
  assert.notEqual(result.status, 0)
  assert.equal(fs.readFileSync(path.join(f.installed,'version'),'utf8'), 'old')
  assert.deepEqual(f.entries().filter(entry => entry.command === 'open').map(entry => entry.args), [['-a',f.installed]])
  assert.equal(JSON.parse(fs.readFileSync(path.join(f.roots()[0],'user-data','history.json'),'utf8')).items.length, 500)
})

test('failed user-data backup cancels replacement and reopens the unchanged previous app', t => {
  const f = fixture(t, { running:true, failDataCopy:true })
  const result = f.run()
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /用户数据备份失败/)
  assert.equal(fs.readFileSync(path.join(f.installed,'version'),'utf8'), 'old')
  assert.equal(f.entries().filter(entry => entry.command === 'mv').length, 0)
  assert.equal(f.entries().filter(entry => entry.command === 'open').length, 1)
  assert.equal(JSON.parse(fs.readFileSync(path.join(f.userData,'history.json'),'utf8')).items.length, 500)
})

test('test mode rejects directory traversal and executable symlinks before invoking tools', t => {
  const f = fixture(t)
  f.env.KAKI_UPDATE_INSTALLED_APP = f.root + '/../Kaki Tools.app'
  let result = f.run()
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /测试路径不能跳出测试根目录/)
  f.env.KAKI_UPDATE_INSTALLED_APP = f.installed
  const link = path.join(f.root,'codesign-link')
  fs.symlinkSync('/usr/bin/codesign', link)
  f.env.KAKI_UPDATE_CODESIGN = link
  result = f.run()
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /测试路径不能使用符号链接/)
  assert.equal(f.entries().length, 0)
})


test('test mode rejects an ancestor symlink that resolves outside its root', t => {
  const f = fixture(t)
  const outside = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'kaki-update-outside-test-')))
  t.after(() => fs.rmSync(outside, {recursive:true,force:true}))
  const link = path.join(f.root,'outside-link')
  fs.symlinkSync(outside, link)
  f.env.KAKI_UPDATE_INSTALLED_APP = path.join(link,'Kaki Tools.app')
  const result = f.run()
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /测试路径不能经符号链接跳出测试根目录/)
  assert.equal(f.entries().length, 0)
  assert.equal(fs.readFileSync(path.join(f.installed,'version'),'utf8'), 'old')
})
