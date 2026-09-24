import { cn } from '@/lib/utils'

interface ToggleProps {
  checked: boolean
  onChange: (next: boolean) => void
  disabled?: boolean
  'aria-label': string
  className?: string
}

export function Toggle({ checked, onChange, disabled, className, ...rest }: ToggleProps) {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={checked}
      aria-label={rest['aria-label']}
      disabled={disabled}
      onClick={() => onChange(!checked)}
      className={cn(
        'relative inline-flex h-[25px] w-[42px] shrink-0 items-center rounded-full',
        'transition-colors disabled:cursor-not-allowed disabled:opacity-50',
        checked ? 'bg-accent-strong' : 'bg-surface-3',
        className,
      )}
    >
      <span
        aria-hidden="true"
        className={cn(
          'absolute top-[2.5px] h-5 w-5 rounded-full bg-control-knob shadow-sm transition-[left]',
          checked ? 'left-[19.5px]' : 'left-[2.5px]',
        )}
      />
    </button>
  )
}
