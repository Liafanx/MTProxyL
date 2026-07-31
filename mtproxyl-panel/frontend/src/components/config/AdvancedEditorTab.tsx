import { useEffect, useRef } from 'react';
import Editor from '@monaco-editor/react';
import { useTheme } from '@/hooks/useTheme';

interface AdvancedEditorTabProps {
  content: string;
  onChange: (content: string) => void;
}

export function AdvancedEditorTab({ content, onChange }: AdvancedEditorTabProps) {
  const editorRef = useRef<any>(null);
  const { theme } = useTheme();

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
