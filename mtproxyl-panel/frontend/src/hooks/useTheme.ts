import { createContext, useContext, useEffect, useRef, useState } from 'react'
import { themeApi } from '@/lib/api'
import {
  CUSTOM_THEME_COLOR_KEYS,
  CUSTOM_THEME_STORAGE_KEY,
  captureThemeColors,
  hexToRgbTriplet,
  isLightCustomTheme,
  normalizeThemeHex,
  readCustomThemeColors,
  sanitizeCustomThemeColors,
  type CustomThemeColors,
  type ThemeColorKey,
} from '@/lib/customTheme'

export const THEMES = ['system', 'light', 'dark', 'mocha', 'parchment', 'matrix', 'custom'] as const
export type Theme = (typeof THEMES)[number]
export type ColorScheme = 'dark' | 'light'
export type ThemeSyncStatus = 'loading' | 'saved' | 'pending' | 'saving' | 'error'

export const THEME_LABELS: Record<Theme, string> = {
  system: 'Системная',
  light: 'Светлая',
  dark: 'Тёмная',
  mocha: 'Мокко',
  parchment: 'Пергамент',
  matrix: 'Матрица',
  custom: 'Своя',
}

const STORAGE_KEY = 'mtproxyl-panel-theme'

const SCHEME: Record<Exclude<Theme, 'system' | 'custom'>, ColorScheme> = {
  dark: 'dark',
  light: 'light',
  mocha: 'dark',
  parchment: 'light',
  matrix: 'dark',
}

const THEME_COLOR: Record<Exclude<Theme, 'system' | 'custom'>, string> = {
  dark: '#12171d',
  light: '#f3f5f8',
  mocha: '#211e1a',
  parchment: '#f3ead9',
  matrix: '#050c08',
}

interface ThemeContextValue {
  theme: Theme
  scheme: ColorScheme
  customColors: CustomThemeColors
  syncStatus: ThemeSyncStatus
  syncError: string
  retrySave: () => void
  setTheme: (next: Theme) => void
  setCustomColor: (key: ThemeColorKey, value: string) => void
  copyThemeColors: (source: Exclude<Theme, 'custom'>) => void
  toggle: () => void
}

export const ThemeContext = createContext<ThemeContextValue>({
  theme: 'dark',
  scheme: 'dark',
  customColors: {},
  syncStatus: 'loading',
  syncError: '',
  retrySave: () => {},
  setTheme: () => {},
  setCustomColor: () => {},
  copyThemeColors: () => {},
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

export function resolveScheme(theme: Theme, customColors: CustomThemeColors = {}): ColorScheme {
  if (theme === 'system') {
    return window.matchMedia('(prefers-color-scheme: light)').matches ? 'light' : 'dark'
  }
  if (theme === 'custom') return isLightCustomTheme(customColors) ? 'light' : 'dark'
  return SCHEME[theme]
}

function applyTheme(theme: Theme, customColors: CustomThemeColors) {
  const root = document.documentElement
  for (const key of CUSTOM_THEME_COLOR_KEYS) root.style.removeProperty(`--${key}`)
  if (theme === 'system') {
    root.removeAttribute('data-theme')
  } else {
    root.setAttribute('data-theme', theme)
  }
  if (theme === 'custom') {
    for (const key of CUSTOM_THEME_COLOR_KEYS) {
      const hex = normalizeThemeHex(customColors[key])
      if (hex) root.style.setProperty(`--${key}`, hexToRgbTriplet(hex))
    }
    root.style.colorScheme = resolveScheme(theme, customColors)
  } else {
    root.style.removeProperty('color-scheme')
  }
  const meta = document.getElementById('theme-color-meta')
  if (meta) {
    const color = theme === 'custom'
      ? customColors.bg || '#12171d'
      : THEME_COLOR[theme === 'system' ? resolveScheme(theme) : theme]
    meta.setAttribute('content', color)
  }
}

export function useThemeProvider(authenticated: boolean): ThemeContextValue {
  const [theme, setThemeState] = useState<Theme>(getInitialTheme)
  const [customColors, setCustomColors] = useState<CustomThemeColors>(readCustomThemeColors)
  const [scheme, setScheme] = useState<ColorScheme>(() => resolveScheme(theme, customColors))
  const [serverLoaded, setServerLoaded] = useState(false)
  const [dirtyRevision, setDirtyRevision] = useState(0)
  const [syncStatus, setSyncStatus] = useState<ThemeSyncStatus>('loading')
  const [syncError, setSyncError] = useState('')
  const revisionRef = useRef(0)
  const saveQueueRef = useRef<Promise<void>>(Promise.resolve())

  const markChanged = () => {
    revisionRef.current += 1
    setDirtyRevision(revisionRef.current)
    setSyncError('')
    setSyncStatus('pending')
  }

  useEffect(() => {
    let cancelled = false
    themeApi.get().then((settings) => {
      if (cancelled) return
      if (revisionRef.current === 0) {
        if (settings.configured) {
          const nextTheme = isTheme(settings.theme) ? settings.theme : 'dark'
          const nextColors = sanitizeCustomThemeColors(settings.colors)
          setThemeState(nextTheme)
          setCustomColors(nextTheme === 'custom' && Object.keys(nextColors).length === 0
            ? captureThemeColors('dark') : nextColors)
          if (nextTheme === 'custom' && Object.keys(nextColors).length === 0) markChanged()
          else setSyncStatus('saved')
        } else {
          // Existing browser preferences become the initial server setting after login.
          markChanged()
        }
      }
      setServerLoaded(true)
    }).catch((error: unknown) => {
      if (cancelled) return
      setSyncError(error instanceof Error ? error.message : 'Не удалось загрузить тему панели')
      setSyncStatus('error')
      setServerLoaded(true)
    })
    return () => { cancelled = true }
  }, [])

  useEffect(() => {
    if (theme === 'custom' && Object.keys(customColors).length === 0) {
      setCustomColors(captureThemeColors('dark'))
      return
    }
    applyTheme(theme, customColors)
    setScheme(resolveScheme(theme, customColors))
    try {
      localStorage.setItem(STORAGE_KEY, theme)
      if (Object.keys(customColors).length > 0) {
        localStorage.setItem(CUSTOM_THEME_STORAGE_KEY, JSON.stringify(customColors))
      }
    } catch {}
    if (theme !== 'system') return
    const mq = window.matchMedia('(prefers-color-scheme: light)')
    const onChange = () => {
      applyTheme('system', customColors)
      setScheme(resolveScheme('system'))
    }
    mq.addEventListener('change', onChange)
    return () => mq.removeEventListener('change', onChange)
  }, [theme, customColors])

  useEffect(() => {
    if (!serverLoaded || !authenticated || dirtyRevision === 0) return
    const revision = dirtyRevision
    const nextTheme = theme
    const nextColors = { ...customColors }
    const timer = window.setTimeout(() => {
      setSyncStatus('saving')
      saveQueueRef.current = saveQueueRef.current.catch(() => {}).then(async () => {
        if (revision < revisionRef.current) return
        try {
          await themeApi.update(nextTheme, nextColors)
          if (revision === revisionRef.current) {
            setSyncError('')
            setSyncStatus('saved')
          }
        } catch (error) {
          if (revision === revisionRef.current) {
            setSyncError(error instanceof Error ? error.message : 'Не удалось сохранить тему панели')
            setSyncStatus('error')
          }
        }
      })
    }, 500)
    return () => window.clearTimeout(timer)
  }, [authenticated, customColors, dirtyRevision, serverLoaded, theme])

  const setTheme = (next: Theme) => {
    if (next === theme) return
    if (next === 'custom' && Object.keys(customColors).length === 0) {
      setCustomColors(captureThemeColors(theme))
    }
    setThemeState(next)
    markChanged()
  }
  const setCustomColor = (key: ThemeColorKey, value: string) => {
    const hex = normalizeThemeHex(value)
    if (hex && hex !== customColors[key]) {
      setCustomColors((previous) => ({ ...previous, [key]: hex }))
      markChanged()
    }
  }
  const copyThemeColors = (source: Exclude<Theme, 'custom'>) => {
    setCustomColors(captureThemeColors(source))
    setThemeState('custom')
    markChanged()
  }
  const toggle = () => setTheme(resolveScheme(theme, customColors) === 'dark' ? 'light' : 'dark')

  return { theme, scheme, customColors, syncStatus, syncError,
    retrySave: markChanged, setTheme, setCustomColor, copyThemeColors, toggle }
}

export function useTheme() {
  return useContext(ThemeContext)
}
