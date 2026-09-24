import { createContext, useContext, useEffect, useState } from 'react'

export const THEMES = ['system', 'light', 'dark', 'mocha', 'parchment'] as const
export type Theme = (typeof THEMES)[number]
export type ColorScheme = 'dark' | 'light'

export const THEME_LABELS: Record<Theme, string> = {
  system: 'Системная',
  light: 'Светлая',
  dark: 'Тёмная',
  mocha: 'Мокко',
  parchment: 'Пергамент',
}

const STORAGE_KEY = 'mtproxyl-panel-theme'

const SCHEME: Record<Exclude<Theme, 'system'>, ColorScheme> = {
  dark: 'dark',
  light: 'light',
  mocha: 'dark',
  parchment: 'light',
}

const THEME_COLOR: Record<Exclude<Theme, 'system'>, string> = {
  dark: '#12171d',
  light: '#f3f5f8',
  mocha: '#211e1a',
  parchment: '#f3ead9',
}

interface ThemeContextValue {
  theme: Theme
  scheme: ColorScheme
  setTheme: (next: Theme) => void
  toggle: () => void
}

export const ThemeContext = createContext<ThemeContextValue>({
  theme: 'dark',
  scheme: 'dark',
  setTheme: () => {},
  toggle: () => {},
})

export function isTheme(value: unknown): value is Theme {
  return typeof value === 'string' && (THEMES as readonly string[]).includes(value)
}

function getInitialTheme(): Theme {
  try {
    const stored = localStorage.getItem(STORAGE_KEY)
    if (isTheme(stored)) return stored
  } catch {}
  return 'dark'
}

export function resolveScheme(theme: Theme): ColorScheme {
  if (theme === 'system') {
    return window.matchMedia('(prefers-color-scheme: light)').matches ? 'light' : 'dark'
  }
  return SCHEME[theme]
}

function applyTheme(theme: Theme) {
  const root = document.documentElement
  if (theme === 'system') {
    root.removeAttribute('data-theme')
  } else {
    root.setAttribute('data-theme', theme)
  }
  const meta = document.getElementById('theme-color-meta')
  if (meta) meta.setAttribute('content', THEME_COLOR[theme === 'system' ? resolveScheme(theme) : theme])
}

export function useThemeProvider(): ThemeContextValue {
  const [theme, setThemeState] = useState<Theme>(getInitialTheme)
  const [scheme, setScheme] = useState<ColorScheme>(() => resolveScheme(theme))

  useEffect(() => {
    applyTheme(theme)
    setScheme(resolveScheme(theme))
    try {
      localStorage.setItem(STORAGE_KEY, theme)
    } catch {}
    if (theme !== 'system') return
    const mq = window.matchMedia('(prefers-color-scheme: light)')
    const onChange = () => {
      applyTheme('system')
      setScheme(resolveScheme('system'))
    }
    mq.addEventListener('change', onChange)
    return () => mq.removeEventListener('change', onChange)
  }, [theme])

  const setTheme = (next: Theme) => setThemeState(next)
  const toggle = () => setThemeState(resolveScheme(theme) === 'dark' ? 'light' : 'dark')

  return { theme, scheme, setTheme, toggle }
}

export function useTheme() {
  return useContext(ThemeContext)
}
