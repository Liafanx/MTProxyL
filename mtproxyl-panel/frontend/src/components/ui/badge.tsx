import React from 'react'
import { cn } from '@/lib/utils'

const variantStyles = {
  default: 'bg-accent/15 text-accent',
  success: 'bg-ok/15 text-ok',
  warning: 'bg-warn/15 text-warn',
  danger: 'bg-error/15 text-error',
  outline: 'bg-surface-2 text-text-muted',
}

export interface BadgeProps extends React.HTMLAttributes<HTMLSpanElement> {
  variant?: keyof typeof variantStyles
}

const Badge = React.forwardRef<HTMLSpanElement, BadgeProps>(
  ({ className, variant = 'default', ...props }, ref) => {
    return (
      <span
        ref={ref}
        className={cn(
          'inline-flex items-center rounded-full px-2.5 py-0.5 text-micro font-semibold transition-colors',
          variantStyles[variant],
          className,
        )}
        {...props}
      />
    )
  },
)
Badge.displayName = 'Badge'

export { Badge }
