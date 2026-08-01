import { useEffect, useRef, useState } from 'react';
import Editor from '@monaco-editor/react';
import { useTheme } from '@/hooks/useTheme';

interface AdvancedEditorTabProps {
  content: string;
  onChange: (content: string) => void;
}

/**
 * Monaco на телефоне не прокручивается пальцем: он перехватывает touch-события
 * ради собственного выделения, а вложенный скролл-контейнер вокруг него
 * довершает дело. Ниже этой ширины показываем обычную textarea — она
 * прокручивается нативно, нормально дружит с экранной клавиатурой и умеет
 * выделять текст так, как ожидает мобильный браузер.
 */
const MOBILE_BREAKPOINT_PX = 768;

function useIsNarrow(): boolean {
  const [narrow, setNarrow] = useState(
    () => typeof window !== 'undefined' && window.innerWidth < MOBILE_BREAKPOINT_PX,
  );

  useEffect(() => {
    const mq = window.matchMedia(`(max-width: ${MOBILE_BREAKPOINT_PX - 1}px)`);
    const onChange = (e: MediaQueryListEvent) => setNarrow(e.matches);
    setNarrow(mq.matches);
    mq.addEventListener('change', onChange);
    return () => mq.removeEventListener('change', onChange);
  }, []);

  return narrow;
}

export function AdvancedEditorTab({ content, onChange }: AdvancedEditorTabProps) {
  const editorRef = useRef<any>(null);
  const { theme } = useTheme();
  const narrow = useIsNarrow();

  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      if ((e.ctrlKey || e.metaKey) && e.key === 's') {
        e.preventDefault();
        // Save is handled by parent component
      }
    };

    window.addEventListener('keydown', handleKeyDown);
    return () => window.removeEventListener('keydown', handleKeyDown);
  }, []);

  const handleEditorDidMount = (editor: any) => {
    editorRef.current = editor;
  };

  if (narrow) {
    return (
      <div className="flex h-full flex-col">
        <p className="px-3 py-2 text-xs text-text-secondary border-b border-border">
          Простой редактор для узкого экрана: подсветки нет, зато текст листается и выделяется
          как обычно.
        </p>
        <textarea
          value={content}
          onChange={(e) => onChange(e.target.value)}
          spellCheck={false}
          autoCapitalize="off"
          autoCorrect="off"
          className="flex-1 w-full resize-none bg-background px-3 py-2 font-mono text-xs leading-relaxed text-text-primary outline-none"
        />
      </div>
    );
  }

  return (
    <div className="h-full">
      <Editor
        height="100%"
        defaultLanguage="toml"
        value={content}
        onChange={(value) => onChange(value || '')}
        onMount={handleEditorDidMount}
        theme={theme === 'dark' ? 'vs-dark' : 'light'}
        options={{
          minimap: { enabled: false },
          fontSize: 14,
          lineNumbers: 'on',
          scrollBeyondLastLine: false,
          automaticLayout: true,
          tabSize: 2,
          wordWrap: 'on',
        }}
      />
    </div>
  );
}
