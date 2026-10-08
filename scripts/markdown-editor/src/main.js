import {
  Editor,
  rootCtx,
  defaultValueCtx,
  serializerCtx,
} from '@milkdown/kit/core'
import { commonmark } from '@milkdown/kit/preset/commonmark'
import { gfm } from '@milkdown/kit/preset/gfm'
import { history } from '@milkdown/kit/plugin/history'
import { clipboard } from '@milkdown/kit/plugin/clipboard'
import { $prose, getMarkdown as getMarkdownAction } from '@milkdown/kit/utils'
import { Plugin, PluginKey } from '@milkdown/kit/prose/state'

let editor = null
let reporting = false
let loadGeneration = 0

function post(message) {
  window.webkit?.messageHandlers?.dblore?.postMessage(message)
}

function rootElement() {
  return document.getElementById('editor') ?? document.body
}

// Reports user edits at most once per animation frame. Only active after "ready".
const changeReporter = $prose((ctx) => {
  return new Plugin({
    key: new PluginKey('dbloreChangeReporter'),
    view: () => {
      let frame = null
      return {
        update(view, prevState) {
          if (!reporting || prevState.doc.eq(view.state.doc) || frame !== null) return
          frame = requestAnimationFrame(() => {
            frame = null
            if (!reporting) return
            const serializer = ctx.get(serializerCtx)
            post({ type: 'changed', markdown: serializer(view.state.doc) })
          })
        },
        destroy() {
          if (frame !== null) cancelAnimationFrame(frame)
          frame = null
        },
      }
    },
  })
})

function setTheme(vars) {
  if (!vars) return
  const style = document.documentElement.style
  for (const [key, value] of Object.entries(vars)) {
    style.setProperty(key, String(value))
  }
}

async function load(markdown, theme) {
  setTheme(theme)
  reporting = false
  const generation = ++loadGeneration

  if (editor) {
    const previous = editor
    editor = null
    await previous.destroy()
    if (generation !== loadGeneration) return
  }
  const root = rootElement()
  root.replaceChildren()

  const created = await Editor.make()
    .config((ctx) => {
      ctx.set(rootCtx, root)
      ctx.set(defaultValueCtx, markdown ?? '')
    })
    .use(commonmark)
    .use(gfm)
    .use(history)
    .use(clipboard)
    .use(changeReporter)
    .create()

  // A newer load() started while this one was creating: drop this editor.
  if (generation !== loadGeneration) {
    await created.destroy()
    return
  }

  editor = created
  post({ type: 'ready', markdown: editor.action(getMarkdownAction()) })
  reporting = true
}

function getMarkdown() {
  if (!editor) return null
  return editor.action(getMarkdownAction())
}

// Links never navigate the web view; Cmd+click asks the host to open them.
document.addEventListener(
  'click',
  (event) => {
    const target = event.target instanceof Element ? event.target : null
    const link = target?.closest('a[href]')
    if (!link || !rootElement().contains(link)) return
    event.preventDefault()
    if (event.metaKey) {
      post({ type: 'openLink', href: link.getAttribute('href') })
    }
  },
  true,
)

// Middle-click must not open links either.
document.addEventListener(
  'auxclick',
  (event) => {
    const target = event.target instanceof Element ? event.target : null
    const link = target?.closest('a[href]')
    if (link && rootElement().contains(link)) event.preventDefault()
  },
  true,
)

window.dblore = { load, setTheme, getMarkdown }
