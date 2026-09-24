import React from 'react'
import { cn } from '@/lib/utils'

const variantStyles = {
  default: 'bg-accent-strong text-accent-text hover:bg-accent-hover active:brightness-95',
  outline: 'bg-surface-2 text-text hover:bg-surface-3 active:bg-surface-3',
  ghost: 'bg-transparent text-text-muted hover:bg-surface-2 hover:text-text',
  danger: 'bg-error/12 text-error hover:bg-error/20 active:bg-error/25',
}

const sizeStyles = {
  sm: 'min-h-[34px] px-3 text-xs rounded-md',
  default: 'min-h-[38px] px-4 text-sm rounded-lg',
  lg: 'min-h-[44px] px-5 text-[15px] rounded-lg',
}

export interface ButtonProps extends React.ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: keyof typeof variantStyles
  size?: keyof typeof sizeStyles
}

const Button = React.forwardRef<HTMLButtonElement, ButtonProps>(
  ({ className, variant = 'default', size = 'default', ...props }, ref) => {
    return (
      <button
        ref={ref}
        className={cn(
          'inline-flex items-center justify-center gap-2 whitespace-nowrap font-semibold transition-colors',
          'focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus-ring',
          'disabled:pointer-events-none disabled:opacity-50',
          sizeStyles[size],
          variantStyles[variant],
          className,
        )}
        {...props}
      />
    )
  },
)
Button.displayName = 'Button'

export { Button }
