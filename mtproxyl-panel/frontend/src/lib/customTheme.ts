export const CUSTOM_THEME_STORAGE_KEY = 'mtproxyl-panel-custom-colors'

export const CUSTOM_THEME_GROUPS = [
  {
    title: 'Фон, карточки и границы',
    colors: [
      { key: 'bg', label: 'Фон страницы' },
      { key: 'surface-sunken', label: 'Углублённый фон' },
      { key: 'surface', label: 'Карточки' },
      { key: 'surface-2', label: 'Поля и наведение' },
      { key: 'surface-3', label: 'Второй уровень поверхности' },
      { key: 'border', label: 'Границы' },
      { key: 'border-strong', label: 'Выделенные границы' },
    ],
  },
  {
    title: 'Текст',
    colors: [
      { key: 'text', label: 'Основной текст' },
      { key: 'text-muted', label: 'Второстепенный текст' },
      { key: 'text-faint', label: 'Подписи и заголовки таблиц' },
    ],
  },
  {
    title: 'Акценты и кнопки',
    colors: [
      { key: 'accent', label: 'Ссылки и акценты' },
      { key: 'accent-strong', label: 'Фон основных кнопок' },
      { key: 'accent-hover', label: 'Акцент при наведении' },
      { key: 'accent-text', label: 'Текст основных кнопок' },
      { key: 'focus-ring', label: 'Рамка фокуса' },
      { key: 'control-knob', label: 'Переключатели' },
    ],
  },
  {
    title: 'Состояния',
    colors: [
      { key: 'ok', label: 'Успех' },
      { key: 'warn', label: 'Предупреждение' },
      { key: 'error', label: 'Ошибка' },
      { key: 'error-strong', label: 'Фон опасных действий' },
      { key: 'error-text', label: 'Текст опасных действий' },
      { key: 'muted', label: 'Приглушённые элементы' },
    ],
  },
  {
    title: 'Брендинг, графики и фоновые слои',
    colors: [
      { key: 'brand-from', label: 'Градиент: начало' },
      { key: 'brand-to', label: 'Градиент: конец' },
      { key: 'brand-text', label: 'Текст на градиенте' },
      { key: 'bar-track', label: 'Шкалы: фон' },
      { key: 'bar-fill', label: 'Шкалы: заполнение' },
      { key: 'bar-fill-warn', label: 'Шкалы: предупреждение' },
      { key: 'bar-fill-full', label: 'Шкалы: предел' },
      { key: 'scrim', label: 'Затемнение под окнами' },
    ],
  },
] as const

export type ThemeColorKey = (typeof CUSTOM_THEME_GROUPS)[number]['colors'][number]['key']
export type CustomThemeColors = Partial<Record<ThemeColorKey, string>>

export const CUSTOM_THEME_COLOR_KEYS: ThemeColorKey[] = CUSTOM_THEME_GROUPS.flatMap(
  (group) => group.colors.map((color) => color.key),
)

export function normalizeThemeHex(value: unknown): string | null {
  if (typeof value !== 'string') return null
  const hex = value.trim().toLowerCase()
  if (/^#[0-9a-f]{6}$/.test(hex)) return hex
  if (/^#[0-9a-f]{3}$/.test(hex)) {
    return `#${hex.slice(1).split('').map((digit) => digit + digit).join('')}`
  }
  return null
}

export function hexToRgbTriplet(hex: string): string {
  return `${parseInt(hex.slice(1, 3), 16)} ${parseInt(hex.slice(3, 5), 16)} ${parseInt(hex.slice(5, 7), 16)}`
}

function rgbTripletToHex(value: string): string | null {
  const parts = value.trim().split(/\s+/).map(Number)
  if (parts.length !== 3 || parts.some((part) => !Number.isInteger(part) || part < 0 || part > 255)) {
    return null
  }
  return `#${parts.map((part) => part.toString(16).padStart(2, '0')).join('')}`
}

export function sanitizeCustomThemeColors(value: unknown): CustomThemeColors {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return {}
  const values = value as Record<string, unknown>
  const colors: CustomThemeColors = {}
  for (const key of CUSTOM_THEME_COLOR_KEYS) {
    const hex = normalizeThemeHex(values[key])
    if (hex) colors[key] = hex
  }
  return colors
}

export function readCustomThemeColors(): CustomThemeColors {
  try {
    const raw = localStorage.getItem(CUSTOM_THEME_STORAGE_KEY)
    return sanitizeCustomThemeColors(raw ? JSON.parse(raw) : null)
  } catch {
    return {}
  }
}

/** Снимает палитру пресета без видимого переключения темы или потери inline-стилей. */
export function captureThemeColors(theme: string): CustomThemeColors {
  const root = document.documentElement
  const previousTheme = root.getAttribute('data-theme')
  const previousInline = CUSTOM_THEME_COLOR_KEYS.map((key) => root.style.getPropertyValue(`--${key}`))
  for (const key of CUSTOM_THEME_COLOR_KEYS) root.style.removeProperty(`--${key}`)
  if (theme === 'system') root.removeAttribute('data-theme')
  else root.setAttribute('data-theme', theme)

  const computed = getComputedStyle(root)
  const colors: CustomThemeColors = {}
  for (const key of CUSTOM_THEME_COLOR_KEYS) {
    const hex = rgbTripletToHex(computed.getPropertyValue(`--${key}`))
    if (hex) colors[key] = hex
  }

  if (previousTheme === null) root.removeAttribute('data-theme')
  else root.setAttribute('data-theme', previousTheme)
  CUSTOM_THEME_COLOR_KEYS.forEach((key, index) => {
    if (previousInline[index]) root.style.setProperty(`--${key}`, previousInline[index])
    else root.style.removeProperty(`--${key}`)
  })
  return colors
}

export function isLightCustomTheme(colors: CustomThemeColors): boolean {
  const bg = normalizeThemeHex(colors.bg)
  if (!bg) return false
  const channels = [1, 3, 5].map((index) => parseInt(bg.slice(index, index + 2), 16) / 255)
  const linear = channels.map((channel) =>
    channel <= 0.04045 ? channel / 12.92 : ((channel + 0.055) / 1.055) ** 2.4,
  )
  return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722 > 0.3
}
