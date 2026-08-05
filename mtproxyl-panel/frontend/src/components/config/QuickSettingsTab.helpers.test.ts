import { applyEdits } from './QuickSettingsTab.helpers';

function edits(pairs: [string, string, unknown][]): Map<string, Map<string, unknown>> {
  const changes = new Map<string, Map<string, unknown>>();
  for (const [section, key, value] of pairs) {
    if (!changes.has(section)) changes.set(section, new Map());
    changes.get(section)!.set(key, value);
  }
  return changes;
}

function drops(pairs: [string, string][]): Map<string, Set<string>> {
  const removals = new Map<string, Set<string>>();
  for (const [section, key] of pairs) {
    if (!removals.has(section)) removals.set(section, new Set());
    removals.get(section)!.add(key);
  }
  return removals;
}

function expect(got: string, want: string, what: string) {
  if (got !== want) {
    throw new Error(`${what}\n--- expected ---\n${want}\n--- got ---\n${got}`);
  }
}

// Чужой конфиг меняется по одной строке: порядок секций, отступы, комментарии и
// незнакомые ключи остаются ровно такими, какими были.
const foreign = [
  '# telemt config',
  '[server]',
  'port = 443    # оставлено провайдером',
  'listen_addr_ipv4 = "0.0.0.0"',
  '',
  '[timeouts]',
  'client_ack = 30',
  '',
  '[general]',
  'use_middle_proxy = true',
  'ad_tag = "deadbeef"',
  '',
  '[general.limits]',
  'per_user = 10',
  '',
].join('\n');

expect(
  applyEdits(foreign, edits([['server', 'port', 8443]]), new Map()),
  foreign.replace('port = 443    #', 'port = 8443    #'),
  'смена одного значения не должна трогать остальной файл'
);

expect(
  applyEdits(foreign, edits([['general', 'tg_connect', 15]]), new Map()),
  foreign.replace('ad_tag = "deadbeef"\n', 'ad_tag = "deadbeef"\ntg_connect = 15\n'),
  'новый ключ дописывается в конец своей секции, до вложенной [general.limits]'
);

expect(
  applyEdits(foreign, new Map(), drops([['general', 'ad_tag']])),
  foreign.replace('ad_tag = "deadbeef"\n', ''),
  'снятое поле убирает свою строку'
);

// Секция может остаться без единого ключа — например, все её поля только что
// сняли в форме. Новый ключ обязан вернуться внутрь неё, а не создать вторую
// таблицу с тем же именем: повторный [timeouts] движок уже не прочитает.
const emptySection = ['[timeouts]', '', '[network]', 'ipv4 = true', ''].join('\n');

expect(
  applyEdits(emptySection, edits([['timeouts', 'client_ack', 30]]), new Map()),
  ['[timeouts]', 'client_ack = 30', '', '[network]', 'ipv4 = true', ''].join('\n'),
  'пустая секция принимает ключ у себя, а не вторым заголовком в конце'
);

// Секции нет вовсе — её создаём в конце файла.
expect(
  applyEdits('[server]\nport = 443\n', edits([['network', 'ipv4', true]]), new Map()),
  '[server]\nport = 443\n\n[network]\nipv4 = true',
  'отсутствующая секция создаётся в конце файла'
);

// Строки, похожие на присваивание, но закомментированные, — чужой текст.
expect(
  applyEdits('[server]\n# port = 111\nport = 443\n', edits([['server', 'port', 8443]]), new Map()),
  '[server]\n# port = 111\nport = 8443\n',
  'закомментированный ключ не считается присваиванием'
);

// Правки в нескольких секциях сразу не должны сбивать позиции вставки друг у
// друга: после splice в ранней секции все более поздние точки съезжают.
expect(
  applyEdits(
    foreign,
    edits([
      ['server', 'listen_addr_ipv6', '::'],
      ['timeouts', 'client_handshake', 10],
      ['general', 'tg_connect', 15],
    ]),
    new Map()
  ),
  foreign
    .replace('listen_addr_ipv4 = "0.0.0.0"\n', 'listen_addr_ipv4 = "0.0.0.0"\nlisten_addr_ipv6 = "::"\n')
    .replace('client_ack = 30\n', 'client_ack = 30\nclient_handshake = 10\n')
    .replace('ad_tag = "deadbeef"\n', 'ad_tag = "deadbeef"\ntg_connect = 15\n'),
  'вставки в разные секции не смещают друг друга'
);

console.log('QuickSettingsTab.helpers: ok');
