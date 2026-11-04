#!/usr/bin/env python3
"""Полные CLI/installer в mount+network namespaces, транспорт и службы — локальные."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile

if '--inside' not in sys.argv:
    os.execvp('unshare', ['unshare', '-m', '-n', '--fork', sys.executable, __file__, '--inside'])

repo = Path(__file__).resolve().parent.parent
base = Path(tempfile.mkdtemp(prefix='mtproxyl-upgrade-'))
print('Upgrade test logs:', base, flush=True)
subprocess.run(['mount', '--make-rprivate', '/'], check=True)
private_opt = base / 'opt'
private_opt.mkdir()
subprocess.run(['mount', '--bind', str(private_opt), '/opt'], check=True)
Path('/opt/mtproxyl').mkdir()
Path('/opt/mtproxyl-tgbot').mkdir()
inst = base / 'install'
inst.mkdir()
subprocess.run(['mount', '--bind', str(inst), '/opt/mtproxyl'], check=True)
for name in ['/run', '/usr/local/bin', '/etc/systemd/system', '/etc/sudoers.d', '/etc/profile.d', '/opt/mtproxyl-tgbot']:
    if Path(name).is_dir():
        folder = base / name.strip('/').replace('/', '-')
        folder.mkdir()
        subprocess.run(['mount', '--bind', str(folder), name], check=True)
old = base / 'old'
old.mkdir()
archive = subprocess.check_output(['git', '-C', str(repo), 'archive', 'v1.7.17'])
(base / 'old.tar').write_bytes(archive)
with tarfile.open(base / 'old.tar') as f:
    f.extractall(old, filter='data')
new = base / 'new'
new.mkdir()
for file in subprocess.check_output(['git', '-C', str(repo), 'ls-files'], text=True).splitlines():
    source = repo / file
    if source.is_file():
        dest = new / file
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, dest)
version = (new / 'version').read_text().strip()
future = base / 'future'
shutil.copytree(new, future)
(future / 'version').write_text('9.0.1\n')
p = future / 'mtproxyl.sh'
p.write_text(p.read_text().replace(f'VERSION="{version}"', 'VERSION="9.0.1"'))
(future / 'lib/utils.sh').write_text((future / 'lib/utils.sh').read_text() + '\n# future fixture\n')
dist = base / 'dist'
dist.mkdir()
for tree, number in [(old, '1.7.17'), (new, version), (future, '9.0.1')]:
    root = base / ('archive-' + number) / ('mtproxyl-' + number)
    root.mkdir(parents=True)
    for name in ['mtproxyl.sh', 'version', 'lib', 'mtproxyl-tgbot']:
        source = tree / name
        if source.is_dir():
            shutil.copytree(source, root / name)
        else:
            shutil.copy2(source, root / name)
    sums = ''.join(hashlib.sha256(f.read_bytes()).hexdigest() + '  ' + str(f.relative_to(root)) + '\n'
                   for f in sorted(root.rglob('*')) if f.is_file())
    (root / 'SHA256SUMS').write_text(sums)
    target = dist / f'mtproxyl-{number}.tar.gz'
    with tarfile.open(target, 'w:gz') as f:
        f.add(root, arcname=root.name)
    Path(str(target) + '.sha256').write_text(hashlib.sha256(target.read_bytes()).hexdigest() + '  ' + target.name + '\n')
bin_dir = base / 'bin'
bin_dir.mkdir()
(bin_dir / 'curl').write_text('''#!/usr/bin/python3
import os,sys,pathlib,urllib.parse
a=sys.argv[1:]; url=next((v for v in a if v.startswith('https://')), '')
out=a[a.index('-o')+1] if '-o' in a else None
with open(os.environ['TEST_ROOT']+'/requests','a') as f:f.write(url+'\\n')
if os.environ.get('FAIL_PATH') and os.environ['FAIL_PATH'] in url:
 if out:pathlib.Path(out).write_bytes(b'partial')
 sys.exit(28)
path=urllib.parse.urlparse(url).path
if '/commits/' in path:
 if os.environ.get('FAIL_PIN'):sys.exit(22)
 data=b'a'*40
elif '/releases/download/' in path:
 if os.environ.get('NO_ARCHIVES'):sys.exit(22)
 file=pathlib.Path(os.environ['TEST_ROOT'])/'dist'/path.split('/')[-1]
 if not file.exists():sys.exit(22)
 data=file.read_bytes()
 if os.environ.get('CORRUPT_ARCHIVE') and path.endswith('.tar.gz'):data+=b'corrupt'
else:
 parts=path.split('/')[3:]
 if parts[:2]==['refs','heads']:parts=parts[2:]
 file=pathlib.Path(os.environ['TEST_TREE']).joinpath(*parts[1:])
 if not file.is_file():sys.exit(22)
 data=file.read_bytes()
if out:pathlib.Path(out).write_bytes(data)
else:sys.stdout.buffer.write(data)
''')
(bin_dir / 'install').write_text('''#!/bin/bash
if [ -n "${FAIL_INSTALL:-}" ] && [[ "$*" == *"/.version.new"* ]] && [ ! -e "$TEST_ROOT/failed-install" ]; then
 touch "$TEST_ROOT/failed-install"; exit 1
fi
exec /usr/bin/install "$@"
''')
(bin_dir / 'cp').write_text('''#!/bin/bash
if [ -n "${FAIL_SNAPSHOT:-}" ] && [[ "$*" == *"/.snap."* ]]; then exit 1; fi
exec /usr/bin/cp "$@"
''')
for name in ['systemctl', 'nft', 'docker', 'sysctl', 'sleep', 'apt-get', 'journalctl', 'pgrep']:
    (bin_dir / name).write_text('#!/bin/sh\n' + ('exit 0\n' if name == 'sleep' else 'exit 1\n'))
for f in bin_dir.iterdir():
    f.chmod(0o755)
env = dict(os.environ, PATH=f'{bin_dir}:/usr/sbin:/usr/bin:/sbin:/bin', TEST_ROOT=str(base),
           TEST_TREE=str(new), MTPROXYL_ASSUME_YES='1', TERM='dumb')
for key in ['MTPROXYL_BRANCH', 'MTPROXYL_VERSION', 'SUDO_USER', 'BASH_ENV', 'MTPROXYL_LOCK_HELD']:
    env.pop(key, None)
count = 0

def run(args, success=True, **flags):
    global count
    count += 1
    log = base / f'command-{count}.log'
    with log.open('wb') as f:
        result = subprocess.run(args, env=dict(env, **flags), stdin=subprocess.DEVNULL,
                                stdout=f, stderr=f, timeout=90)
    assert (result.returncode == 0) == success, (args, result.returncode, str(log), log.read_text()[-1200:])

def reset(tree=new):
    for item in inst.iterdir():
        if item.is_dir(): shutil.rmtree(item)
        else: item.unlink()
    shutil.copy2(tree / 'mtproxyl.sh', inst / 'mtproxyl.sh')
    (inst / 'mtproxyl.sh').chmod(0o755)
    shutil.copytree(tree / 'lib', inst / 'lib')
    shutil.copy2(tree / 'version', inst / 'version')
    (inst / 'settings.conf').write_text("MTPROXYL_MODE='manager'\nENGINE_BACKEND='docker'\nPROXY_PORT='9443'\nPROXY_MODE='combined'\nWEB_ENABLED='false'\nCUSTOM_IP='203.0.113.9'\n")
    (inst / 'secrets.conf').write_text('alice|000102030405060708090a0b0c0d0e0f|1|true|4|2|1048576|0|note||\n')
    (inst / 'expert.conf').write_text('general|prefer_ipv6|false\n')
    (inst / 'mtproxy').mkdir()
    (inst / 'mtproxy/config.toml').write_text('# preserve running engine config\n')
    (inst / '.telemt_version').write_text('3.5.13-d3de986\n')
    Path('/usr/local/bin/mtproxyl').unlink(missing_ok=True)
    Path('/usr/local/bin/mtproxyl').symlink_to('/opt/mtproxyl/mtproxyl.sh')
    (base / 'failed-install').unlink(missing_ok=True)
    (base / 'requests').write_text('')

def check(number, tree, legacy=False):
    if not legacy:
        assert (inst / 'version').read_text().strip() == number
    assert (inst / 'mtproxyl.sh').read_bytes() == (tree / 'mtproxyl.sh').read_bytes()
    for file in (tree / 'lib').glob('*.sh'):
        assert (inst / 'lib' / file.name).read_bytes() == file.read_bytes(), file.name
    assert (inst / 'secrets.conf').read_text().endswith('|note||\n')
    assert (inst / 'mtproxy/config.toml').read_text() == '# preserve running engine config\n'
    assert (inst / '.telemt_version').read_text() == '3.5.13-d3de986\n'
    assert "PROXY_PORT='9443'" in (inst / 'settings.conf').read_text()
    run(['/opt/mtproxyl/mtproxyl.sh', 'version'])

cli = '/opt/mtproxyl/mtproxyl.sh'
reset(old)
run([cli, 'update', '--no-restart'])
check(version, new, legacy=True)
print('PASS actual 1.7.17 CLI -> new loader/libraries, state preserved', flush=True)
run([cli, 'update', '--version', '9.0.1', '--no-restart'])
check('9.0.1', future)
run([cli, 'update', '--rollback', '--no-restart'])
check(version, new)
print('PASS archive upgrade and rollback restore exact code', flush=True)
run([cli, 'update', '--version', '1.7.17', '--yes', '--no-restart'])
check('1.7.17', old)
print('PASS explicit downgrade to actual 1.7.17', flush=True)
for flags in [dict(CORRUPT_ARCHIVE='1'), dict(FAIL_PATH='/lib/colors.sh', NO_ARCHIVES='1'),
              dict(FAIL_PATH='/bot/notify.py', NO_ARCHIVES='1'), dict(FAIL_SNAPSHOT='1'),
              dict(NO_ARCHIVES='1', FAIL_PIN='1'), dict(FAIL_INSTALL='1')]:
    reset()
    run([cli, 'update', '--no-restart'], success=False, TEST_TREE=str(future), **flags)
    check(version, new)
print('PASS invalid archive, interrupted transfer, failed replacement preserve code', flush=True)
reset(old)
run(['bash', str(new / 'install.sh'), '--', '--help'])
check(version, new)
assert (inst / 'releases/previous').read_text().strip() == '1.7.17'
run([cli, 'update', '--rollback', '--no-restart'])
check('1.7.17', old)
print('PASS new installer -> local snapshot -> rollback to 1.7.17', flush=True)
for flags in [dict(FAIL_PATH='/lib/colors.sh', NO_ARCHIVES='1'), dict(CORRUPT_ARCHIVE='1'),
              dict(NO_ARCHIVES='1', FAIL_PIN='1'), dict(FAIL_INSTALL='1')]:
    reset(old)
    run(['bash', str(new / 'install.sh'), '--', '--help'], success=False, **flags)
    check('1.7.17', old)
print('PASS installer failures leave original 1.7.17 usable', flush=True)
reset(old)
run(['bash', str(new / 'install.sh'), '--branch', 'dev', '--', '--help'], NO_ARCHIVES='1')
check(version, new)
assert 'a'*40 in (base / 'requests').read_text()
print('PASS installer branch fallback pinned to one commit', flush=True)

bot = Path('/opt/mtproxyl-tgbot')
if not bot.is_dir():
    raise AssertionError('Bot fixture needs private mount')
shutil.copytree(old / 'mtproxyl-tgbot/bot', bot / 'bot', dirs_exist_ok=True)
shutil.copy2(old / 'mtproxyl-tgbot/requirements.txt', bot / 'requirements.txt')
(bot / 'venv/bin').mkdir(parents=True)
(bot / 'venv/bin/python').write_text('#!/bin/sh\nexit 0\n')
(bot / 'venv/bin/python').chmod(0o755)
(bot / 'config.json').write_text('{"token":"synthetic-test-token","admin_ids":[12345]}')
reset(old)
run(['bash', str(new / 'install.sh'), '--', '--help'])
assert (bot / 'bot/notify.py').read_bytes() == (new / 'mtproxyl-tgbot/bot/notify.py').read_bytes()
assert json.loads((bot / 'config.json').read_text())['token'] == 'synthetic-test-token'
run([cli, 'update', '--rollback', '--no-restart'])
assert (bot / 'bot/notify.py').read_bytes() == (old / 'mtproxyl-tgbot/bot/notify.py').read_bytes()
print('PASS installed bot code upgrades/rolls back, token preserved', flush=True)
for tag in ['v1.6.22', 'v1.7.0']:
    tree = base / tag
    tree.mkdir()
    data = subprocess.check_output(['git', '-C', str(repo), 'archive', tag])
    source = base / (tag + '.tar')
    source.write_bytes(data)
    with tarfile.open(source) as f:
        f.extractall(tree, filter='data')
    reset(tree)
    run([cli, 'update', '--no-restart'])
    check(version, new, legacy=True)
    print('PASS actual legacy CLI ' + tag + ' -> new version', flush=True)
