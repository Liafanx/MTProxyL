import { useEffect, useState } from 'react'
import { RotateCcw } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { useTheme } from '@/hooks/useTheme'
import {
  CUSTOM_THEME_GROUPS,
  type ThemeColorKey,
} from '@/lib/customTheme'

function ColorField({ colorKey, label, value, onChange }: {
  colorKey: ThemeColorKey
  label: string
  value: string
  onChange: (key: ThemeColorKey, value: string) => void
}) {
  const [draft, setDraft] = useState(value)
  useEffect(() => setDraft(value), [value])

  const handleTextChange = (next: string) => {
    setDraft(next)
    if (/^#[0-9a-fA-F]{6}$/.test(next)) onChange(colorKey, next)
  }

  return (
    <div className="flex min-w-0 items-center gap-2">
      <label htmlFor={`theme-color-${colorKey}`} className="min-w-0 flex-1 text-sm text-text">
        {label}
      </label>
      <input
        id={`theme-color-${colorKey}`}
        type="color"
        value={value}
        onChange={(event) => onChange(colorKey, event.target.value)}
        className="h-10 w-12 shrink-0 cursor-pointer rounded-lg border border-border bg-surface p-1"
      />
      <Input
        type="text"
        value={draft}
        onChange={(event) => handleTextChange(event.target.value)}
        onBlur={() => setDraft(value)}
        aria-label={`HEX: ${label}`}
        maxLength={7}
        spellCheck={false}
        className="w-24 shrink-0 font-mono text-xs"
      />
    </div>
  )
}

export function CustomThemeEditor() {
  const { customColors, setCustomColor, copyThemeColors } = useTheme()

  const reset = () => {
    if (window.confirm('Заменить свою палитру стандартными цветами тёмной темы?')) {
      copyThemeColors('dark')
    }
  }

  return (
    <div className="space-y-4 rounded-lg border border-border bg-surface-2/50 p-3 sm:p-4">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <div className="text-sm font-medium text-text">Своя палитра</div>
          <p className="mt-1 text-meta text-text-muted">
            Изменения видны сразу и автоматически сохраняются в панели.
          </p>
        </div>
        <Button variant="outline" size="sm" onClick={reset}>
          <RotateCcw size={14} />
          Сбросить цвета
        </Button>
      </div>

      {CUSTOM_THEME_GROUPS.map((group) => (
        <details key={group.title} className="rounded-lg border border-border bg-surface">
          <summary className="cursor-pointer px-3 py-2.5 text-sm font-medium text-text">
            {group.title} <span className="text-text-muted">({group.colors.length})</span>
          </summary>
          <div className="grid gap-3 border-t border-border p-3 lg:grid-cols-2">
            {group.colors.map((color) => (
              <ColorField
                key={color.key}
                colorKey={color.key}
                label={color.label}
                value={customColors[color.key] || '#000000'}
                onChange={setCustomColor}
              />
            ))}
          </div>
        </details>
      ))}
    </div>
  )
}
