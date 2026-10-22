// Focused UI regression gate. Run with the installed game root; --ref tests old Git source.
// node tools/ui_compatibility_check.cjs <game-root> [--ref <git-ref>] [--commands <json-output>]
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const { execFileSync } = require('node:child_process')
const root = path.resolve(__dirname, '..')
const game = path.resolve(process.argv[2])
const option = flag => process.argv.includes(flag) ? process.argv[process.argv.indexOf(flag) + 1] : null
const ref = option('--ref')
const read = file => ref ? execFileSync('git', ['show', `${ref}:${file}`], { cwd: root, encoding: 'utf8' }) : fs.readFileSync(path.join(root, file), 'utf8')
const source = file => read(file).replace(/^import .*\r?\n/gm, '').replace(/^export /gm, '')
const refValue = value => ({ value })
const computed = fn => ({ get value() { return fn() } })
const storage = { getItem: () => null, setItem() {}, removeItem() {} }
const gameAPI = fs.readFileSync(path.join(game, 'ui/ui-vue/src/bridge/libs/BeamNGAPI.js'), 'utf8')
const API = new Function(gameAPI.replace('export default class', 'return class'))()
const api = new API({ on() {} }, {})
const commands = []
api.engineLua = (command, callback) => { commands.push(command); callback?.({ ok: true }) }
const base = () => ({
  console, ref: refValue, computed, localStorage: storage, window: { localStorage: storage },
  useBridge: () => ({ api, events: { on() {}, off() {} } }),
  TextEncoder, TextDecoder, btoa, atob, nextTick: fn => fn(), onMounted() {}, onUnmounted() {},
  beammpTextStyleMap: { '^1': 'color-1' },
})
let failures = 0
async function check(name, fn) {
  try { await fn(); console.log(`PASS ${name}`) }
  catch (error) { failures++; console.error(`FAIL ${name}: ${error.message}`) }
}

function chat2() {
  const code = read('ui/modules/apps/BeamMP-Chat2/app.vue').match(/<script setup>([\s\S]*?)<\/script>/)[1].replace(/^import .*\r?\n/gm, '')
  // A benign HTML element is allowed by the old server-HTML bypass; no browser is needed
  // to prove the new text-only policy escapes it instead of forwarding the markup.
  const context = vm.createContext({ ...base(), DOMParser: class {
    parseFromString() { return { body: { querySelectorAll: () => [{ tagName: 'B', attributes: [] }] } } }
  } })
  vm.runInContext(code + '\nglobalThis.test = { formatChatMessage, inputText, lastSentMessage, isFocused, chatInputRef, focusChat, blurChat, onInputKeydown };', context)
  return context.test
}

async function main() {
  await check('all stock conditions exactly match the installed game', () => {
    const file = 'ui/ui-vue/src/modules/options/runtime/conditions.js'
    const evaluate = text => new Function(text.replace('export default function', 'return function'))()({ SysInfo: {} }).conditions
    const stock = evaluate(fs.readFileSync(path.join(game, file), 'utf8'))
    const shipped = evaluate(read(file))
    const missing = Object.keys(stock).filter(name => !shipped[name])
    const extra = Object.keys(shipped).filter(name => !name.startsWith('beammp') && !stock[name])
    assert.equal(missing.length + extra.length, 0, `missing stock conditions: ${missing}; stale stock conditions: ${extra}`)
    for (const [name, fn] of Object.entries(stock)) assert.equal(shipped[name]?.toString(), fn.toString(), name)
    assert.deepEqual(Object.keys(shipped).filter(name => !name.startsWith('beammp')).sort(), Object.keys(stock).sort())
    assert.equal(Object.keys(shipped).filter(name => name.startsWith('beammp')).length, 10)
    assert.equal(shipped.richPresenceEnabled({ richPresence: true }), true)
    assert.equal(shipped.beammpNametagsEnabled({ hideNameTags: false }), true)
    console.log(`  ${Object.keys(stock).length} stock functions; 10 BeamMP functions`)
  })

  await check('Angular chat escapes text, retains formatting, and reloads without global redeclarations', () => {
    let code = read('ui/modules/apps/BeamMP-Chat/app.js').replace(/^import\(.*\)\r?\n/gm, '')
    const exportFn = '\nglobalThis.format = formatChatMessage;\n'
    code = /\}\)\(\);\s*$/.test(code) ? code.replace(/\}\)\(\);\s*$/, exportFn + '})();') : code + exportFn
    const context = vm.createContext({ ...base(), angular: { module: () => ({ directive() {}, controller() {} }) },
      document: { createElement: () => ({ getElementsByTagName: () => [{ tagName: 'B', attributes: [] }] }) },
    })
    vm.runInContext(code, context)
    assert.equal(context.format('Server: <b>hello & goodbye</b>'), 'Server: &lt;b&gt;hello &amp; goodbye&lt;/b&gt;')
    assert.equal(context.format('^1red^r plain'), '<span class="color-1">red</span> plain')
    vm.runInContext(code, context)
  })

  await check('Chat2 server messages use the same escaped text policy', () => {
    assert.equal(chat2().formatChatMessage('Server: <b>hello & goodbye</b>'), 'Server: &lt;b&gt;hello &amp; goodbye&lt;/b&gt;')
  })

  await check('Chat2 native input wires history/focus/Enter and sends once without deprecated calls', () => {
    const template = read('ui/modules/apps/BeamMP-Chat2/app.vue').split('<script setup>')[0]
    const input = template.match(/<input\s[\s\S]*?\/>/)?.[0] || ''
    assert.match(input, /ref="chatInputRef"/)
    assert.match(input, /@focus="focusChat"/)
    assert.match(input, /@blur="blurChat"/)
    assert.match(template, /<form[^>]+@keydown.capture="onInputKeydown"/)
    const chat = chat2()
    const sentAt = commands.length
    chat.focusChat(); assert.equal(chat.isFocused.value, true)
    chat.blurChat(); assert.equal(chat.isFocused.value, false)
    assert.equal(commands.length, sentAt)
    let selection
    chat.chatInputRef.value = { setSelectionRange: (...args) => { selection = args } }
    chat.lastSentMessage.value = 'previous message'
    const event = key => ({ key, preventDefault() { this.prevented = true }, stopPropagation() { this.stopped = true } })
    const up = event('ArrowUp'); chat.onInputKeydown(up)
    assert.equal(chat.inputText.value, 'previous message')
    assert.deepEqual(selection, [16, 16]); assert(up.prevented && up.stopped)
    const enter = event('Enter'); chat.onInputKeydown(enter)
    assert.equal(commands.length, sentAt + 1); assert(enter.prevented && enter.stopped)
    assert.equal(chat.inputText.value, '')
    chat.inputText.value = 'composing'
    chat.onInputKeydown({ ...event('Enter'), isComposing: true })
    assert.equal(commands.length, sentAt + 1)
  })

  await check('disconnect dialog renders HTML, Vue expressions and BBCode as text without double-escaping props', async () => {
    let captured
    const context = vm.createContext({ ...base(), $translate: { instant: key => key }, ACCENTS: {},
      h: (tag, props, children) => ({ tag, props, children }),
      openConfirmation: (...args) => { captured = args; return Promise.resolve('continueOffline') },
    })
    vm.runInContext(source('ui/ui-vue/mods/BeamMP/index.js') + '\nglobalThis.showDialog = showBeamMPDialog;', context)
    const text = '<img src=x> & "text" {{ 1 + 1 }} [url=https://example.com]link[/url]'
    await context.showDialog({ title: '<b>title</b>', text, okText: '<i>ok</i>' })
    assert.equal(captured[0], '<b>title</b>')
    assert.equal(typeof captured[1].component, 'function')
    const vnode = captured[1].component(captured[1].props)
    assert.equal(vnode.tag, 'span')
    assert.equal(vnode.children, text)
    assert.equal(vnode.props.style.whiteSpace, 'pre-wrap')
    assert.equal(captured[2][0].label, '<i>ok</i>')
  })

  await check('connect arguments retain the guarded bridge and serialize quoted/unicode input', async () => {
    const context = vm.createContext(base())
    vm.runInContext(source('ui/ui-vue/mods/BeamMP/shared/beammpState.js') + '\nglobalThis.stateAPI = useBeamMPState();', context)
    const samples = [
      ['127.0.0.1', 30814, 'LAN server', false],
      ['host"\\name', 30814, 'Café "test"\\folder\nsecond line', true],
      ['127.0.0.1', 30814, '"); error("must remain data"); --', false],
    ]
    const connectionCommands = []
    for (const [ip, port, name, skip] of samples) {
      const before = commands.length
      await context.stateAPI.connectToServer(ip, port, name, skip)
      const command = commands[before]
      assert.match(command, /local _extension = MPCoreNetwork;/)
      assert.match(command, /local _method = _extension.connectToServer;/)
      assert(command.includes(`pcall(_method, ${api.serializeToLua(ip)}, ${port}, ${api.serializeToLua(name)}, ${skip})`))
      connectionCommands.push({ command, expected: [ip, port, name, skip] })
    }
    if (option('--commands')) fs.writeFileSync(option('--commands'), JSON.stringify(connectionCommands, null, 2))
  })

  console.log(`RESULT: ${failures ? 'FAIL' : 'PASS'} (${failures} failures${ref ? `, source ${ref}` : ''})`)
  process.exitCode = failures ? 1 : 0
}
main().catch(error => { console.error(error); process.exitCode = 1 })
