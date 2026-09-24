import { createContext, useContext, useEffect, useState } from 'react'

export const NAV_LAYOUTS = ['modern', 'classic'] as const
export type NavLayout = (typeof NAV_LAYOUTS)[number]

export const NAV_LAYOUT_LABELS: Record<NavLayout, string> = {
  modern: 'Новая',
  classic: 'Классическая',
}

const STORAGE_KEY = 'mtproxyl-panel-nav'

interface NavLayoutContextValue {
  layout: NavLayout
  setLayout: (next: NavLayout) => void
}

export const NavLayoutContext = createContext<NavLayoutContextValue>({
  layout: 'modern',
  setLayout: () => {},
})

export function isNavLayout(value: unknown): value is NavLayout {
  return typeof value === 'string' && (NAV_LAYOUTS as readonly string[]).includes(value)
}

function getInitialLayout(): NavLayout {
  try {
    const stored = localStorage.getItem(STORAGE_KEY)
    if (isNavLayout(stored)) return stored
  } catch {}
  return 'modern'
}

export function useNavLayoutProvider(): NavLayoutContextValue {
  const [layout, setLayout] = useState<NavLayout>(getInitialLayout)
  useEffect(() => {
    try {
      localStorage.setItem(STORAGE_KEY, layout)
    } catch {}
  }, [layout])
  return { layout, setLayout }
}

export function useNavLayout() {
  return useContext(NavLayoutContext)
}
