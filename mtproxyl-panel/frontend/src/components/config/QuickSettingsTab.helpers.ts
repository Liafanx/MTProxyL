// Render a form value the way TOML spells it.
function tomlValue(value: unknown): string {
  if (typeof value === 'boolean' || typeof value === 'number') return String(value);
  return JSON.stringify(String(value));
}

// Apply key/value edits to the config text itself, touching only the lines that
// change.
//
// Parsing the whole file and printing it back was rewriting configs wholesale:
// nested sections came back indented, arrays reflowed and section order shifted
// (a one-value edit moved [timeouts] to the end of the file). In reanimator mode
// that file belongs to someone else, and MTProxyL must leave everything it was
// not asked to change exactly as it found it.
export function applyEdits(
  raw: string,
  changes: Map<string, Map<string, unknown>>,
  removals: Map<string, Set<string>>
): string {
  const lines = raw.split('\n');
  const out: string[] = [];
  const pending = new Map<string, Map<string, unknown>>();
  changes.forEach((keys, section) => pending.set(section, new Map(keys)));

  let section = '';
  // Where a new key would go in each section seen so far: after its last
  // non-empty line, so it lands inside the section rather than after the blank
  // line that separates it from the next one.
  const insertAt = new Map<string, number>();

  for (const line of lines) {
    const header = line.match(/^\s*\[([^\]]+)\]\s*$/);
    if (header) {
      section = header[1];
      out.push(line);
      // Секция, объявленная и оставшаяся пустой, — тоже место для вставки:
      // иначе ключ ушёл бы в конец файла вторым заголовком с тем же именем, а
      // повторная таблица делает конфиг нечитаемым для движка.
      insertAt.set(section, out.length);
      continue;
    }

    const assignment = line.match(/^(\s*)([A-Za-z0-9_-]+)(\s*=\s*)(.*)$/);
    if (assignment) {
      const [, indent, key, sep, rest] = assignment;
      if (removals.get(section)?.has(key)) {
        continue;
      }
      const value = pending.get(section);
      if (value?.has(key)) {
        // Хвостовой комментарий — часть чужого файла, его сохраняем.
        const comment = rest.match(/\s+#.*$/);
        out.push(`${indent}${key}${sep}${tomlValue(value.get(key))}${comment ? comment[0] : ''}`);
        value.delete(key);
        insertAt.set(section, out.length);
        continue;
      }
    }

    out.push(line);
    if (line.trim() !== '') insertAt.set(section, out.length);
  }

  // Ключи, которых в файле не было: дописываем в конец своей секции, а если
  // секции нет — создаём её в конце файла.
  pending.forEach((keys, sec) => {
    if (keys.size === 0) return;
    const at = insertAt.get(sec);
    const added = Array.from(keys, ([key, value]) => `${key} = ${tomlValue(value)}`);
    if (at === undefined) {
      if (out.length > 0 && out[out.length - 1].trim() !== '') out.push('');
      out.push(`[${sec}]`, ...added);
    } else {
      out.splice(at, 0, ...added);
      insertAt.forEach((pos, other) => {
        if (pos > at) insertAt.set(other, pos + added.length);
      });
    }
  });

  return out.join('\n');
}
