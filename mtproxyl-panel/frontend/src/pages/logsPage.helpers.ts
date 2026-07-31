export type LogPartKind =
  | 'timestamp'
  | 'host'
  | 'service'
  | 'level-error'
  | 'level-warn'
  | 'level-info'
  | 'level-debug'
  | 'ip'
  | 'key'
  | 'plain';

export interface LogPart {
  kind: LogPartKind;
  text: string;
}

const OUTER_TS_RE = /^\d{4}-\d{2}-\d{2}T[\d:.]+Z\s+/;
const JOURNAL_PREFIX_RE = /^(\d{4}-\d{2}-\d{2}T[^\s]+)(\s+)(?:(\S+)(\s+))?([^\s[]+(?:\[\d+\])?:)(\s*)/;
const MESSAGE_TOKEN_RE = new RegExp(
  [
    '(\\d{4}-\\d{2}-\\d{2}T[^\\s]+)',
    '\\b(ERROR|ERR|FATAL|PANIC|CRITICAL)\\b',
    '\\b(WARN(?:ING)?)\\b',
    '\\b(INFO|NOTICE)\\b',
    '\\b(DEBUG|TRACE)\\b',
    '(\\d{1,3}(?:\\.\\d{1,3}){3}(?::\\d+)?)',
    '([A-Za-z_][\\w.-]*=)',
  ].join('|'),
  'gi',
);

function pushPart(parts: LogPart[], kind: LogPartKind, text: string) {
  if (text) {
    parts.push({ kind, text });
  }
}

function messageKind(match: RegExpExecArray): LogPartKind {
  if (match[1]) return 'timestamp';
  if (match[2]) return 'level-error';
  if (match[3]) return 'level-warn';
  if (match[4]) return 'level-info';
  if (match[5]) return 'level-debug';
  if (match[6]) return 'ip';
  return 'key';
}

function parseMessageParts(text: string): LogPart[] {
  const parts: LogPart[] = [];
  let last = 0;
  MESSAGE_TOKEN_RE.lastIndex = 0;

  let m: RegExpExecArray | null;
  while ((m = MESSAGE_TOKEN_RE.exec(text)) !== null) {
    pushPart(parts, 'plain', text.slice(last, m.index));
    pushPart(parts, messageKind(m), m[0]);
    last = m.index + m[0].length;
  }
  pushPart(parts, 'plain', text.slice(last));

  return parts.length ? parts : [{ kind: 'plain', text }];
}

export function parseLogLineParts(raw: string): LogPart[] {
  const cleaned = raw.replace(OUTER_TS_RE, '');
  const m = JOURNAL_PREFIX_RE.exec(cleaned);
  if (!m) {
    return parseMessageParts(cleaned);
  }

  const parts: LogPart[] = [
    { kind: 'timestamp', text: m[1] },
    { kind: 'plain', text: m[2] },
  ];
  if (m[3]) {
    parts.push({ kind: 'host', text: m[3] });
    parts.push({ kind: 'plain', text: m[4] });
  }
  parts.push({ kind: 'service', text: m[5] });
  parts.push({ kind: 'plain', text: m[6] });
  parts.push(...parseMessageParts(cleaned.slice(m[0].length)));
  return parts;
}
