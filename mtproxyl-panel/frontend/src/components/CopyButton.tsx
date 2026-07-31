import { useState } from 'react';
import { Copy, Check } from 'lucide-react';

export function CopyButton({ text, label }: { text: string; label?: string }) {
  const [copied, setCopied] = useState(false);

  const handleCopy = async () => {
    try {
      if (navigator.clipboard) {
        await navigator.clipboard.writeText(text);
      } else {
        // Fallback for non-secure contexts (HTTP)
        const textarea = document.createElement('textarea');
        textarea.value = text;
        textarea.style.position = 'fixed';
        textarea.style.opacity = '0';
        document.body.appendChild(textarea);
        textarea.select();
        document.execCommand('copy');
        document.body.removeChild(textarea);
      }
      setCopied(true);
      setTimeout(() => setCopied(false), 2000);
    } catch {
      // Ignore copy failures
    }
  };

  return (
    <button
      onClick={handleCopy}
      className="inline-flex items-center gap-1 px-2 py-1 rounded text-xs bg-background hover:bg-surface-hover text-text-secondary hover:text-text-primary transition-colors"
      title={label || 'Copy'}
    >
      {copied ? <Check size={12} className="text-green-500" /> : <Copy size={12} />}
      {label && <span>{copied ? 'Copied' : label}</span>}
    </button>
  );
}
