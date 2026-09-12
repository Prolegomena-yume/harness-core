#!/usr/bin/env python3
"""Fake CLI checks for the delegation wrappers; no model is started."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

CORE = Path(__file__).resolve().parent.parent
count = 0


def passed(label):
    global count
    count += 1
    print(f'ok {count} - {label}')


with tempfile.TemporaryDirectory(prefix='agent-wrappers-') as directory:
    root = Path(directory)
    binary = root / 'bin'
    binary.mkdir()
    capture = root / 'capture.json'
    env = dict(os.environ, PATH=f'{binary}:{os.environ["PATH"]}',
               CODEX_AGENT_STATE_DIR=str(root / 'state'), FAKE_CAPTURE=str(capture),
               GIT_AUTHOR_NAME='old', GIT_COMMITTER_NAME='old',
               GIT_AUTHOR_EMAIL='old@example.invalid', GIT_COMMITTER_EMAIL='old@example.invalid')
    fake = '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
Path(os.environ['FAKE_CAPTURE']).write_text(json.dumps({
    'argv': sys.argv[1:], 'cwd': os.getcwd(),
    'stdin': os.readlink('/proc/self/fd/0'),
    'identity': [os.environ.get(k) for k in (
        'GIT_AUTHOR_NAME', 'GIT_AUTHOR_EMAIL', 'GIT_COMMITTER_NAME', 'GIT_COMMITTER_EMAIL')]
}))
if Path(sys.argv[0]).name == 'claude':
    if os.environ.get('FAKE_INVALID'):
        print('invalid JSON')
    else:
        print(json.dumps({'session_id': 'test-session', 'permission_denials': [{}],
                          'result': 'PONG\\nsecond line'}))
    sys.exit(int(os.environ.get('FAKE_STATUS', '0')))
'''
    for name in ('claude', 'git'):
        path = binary / name
        path.write_text(fake)
        path.chmod(0o755)

    def run(script, *args, input='', overrides=None):
        return subprocess.run([str(CORE / 'scripts' / script), *map(str, args)],
                              input=input, text=True, capture_output=True, timeout=10,
                              env=env | (overrides or {}))

    for persona, name in [('takano', '鷹野'), ('minase', '水無瀬'), ('kashiwagi', '柏木'), ('makabe', '真壁')]:
        for alias in (persona, name):
            result = run('git-as', alias, 'status', '--short')
            assert result.returncode == 0, result.stderr
            data = json.loads(capture.read_text())
            assert data['argv'] == ['-c', f'user.name={name}', '-c', f'user.email={persona}@ai.yumemism.dev', 'status', '--short']
            assert data['identity'] == [name, f'{persona}@ai.yumemism.dev'] * 2
    passed('git-as accepts all four English/Japanese roles and overrides author/committer')
    for args in [(), ('unknown', 'status'), ('makabe',)]:
        assert run('git-as', *args).returncode == 2
    passed('git-as rejects missing arguments and unknown roles')

    # Claude の作業ルート判定には本物の git を使う。
    (binary / 'git').unlink()
    first, second = root / 'one.md', root / 'two.md'
    first.write_text('file one `literal` $(literal)')
    second.write_text('file two')
    log = root / 'copy.json'
    result = run('claude-minase.sh', '-f', first, '-f', second, '-C', root,
                 '--resume', 'prior-session', '--effort', 'high', '--log', log,
                 'argument `literal` $(literal)')
    assert result.returncode == 0, result.stderr
    data = json.loads(capture.read_text())
    args = data['argv']
    assert args[:5] == ['-p', '--model', 'claude-opus-5', '--output-format', 'json']
    assert args[args.index('--resume') + 1] == 'prior-session'
    assert args[args.index('--effort') + 1] == 'high'
    assert args[-2] == '--'
    assert args[-1] == 'file one `literal` $(literal)\nfile two\nargument `literal` $(literal)'
    assert data['cwd'] == str(root) and data['stdin'] == '/dev/null'
    assert data['identity'] == ['水無瀬', 'minase@ai.yumemism.dev'] * 2
    prompt = args[args.index('--append-system-prompt') + 1]
    role = (CORE / 'roles/minase.md').read_text()
    agent = (CORE / 'agents/minase.md').read_text()
    body = agent.split('---', 2)[2] if agent.startswith('---\n') else agent
    assert prompt == (role + '\n' + body.removeprefix('\n')).rstrip('\n')
    allowed = args[args.index('--allowedTools') + 1]
    assert allowed == 'Read,Glob,Grep,Edit,Write,WebFetch,WebSearch,Bash(ls:*),Bash(cat:*),Bash(git status:*),Bash(git diff:*),Bash(git log:*),Bash(git add:*),Bash(git commit:*)'
    assert result.stdout.endswith('session_id: test-session\npermission_denials: 1\nresult:\nPONG\nsecond line\n')
    raws = list((root / 'state/runs').glob('minase-claude-*/last.json'))
    assert len(raws) == 1 and raws[0].read_bytes() == log.read_bytes()
    passed('Claude argv, literal prompts, cwd, /dev/null stdin, identity, JSON copy and output contract')

    result = run('claude-minase.sh', '-C', root, input='stdin task')
    assert result.returncode == 0, result.stderr
    assert json.loads(capture.read_text())['argv'][-1] == 'stdin task'
    result = run('claude-minase.sh', '-C', root, 'failure', overrides={'FAKE_STATUS': '7'})
    assert result.returncode == 7 and result.stdout.endswith('PONG\nsecond line\n')
    result = run('claude-minase.sh', '-C', root, 'bad JSON', overrides={'FAKE_INVALID': '1'})
    assert result.returncode != 0 and 'JSON を解析できない' in result.stderr
    passed('Claude stdin fallback, CLI failure status, and malformed JSON diagnostics')
    for args in [('--unknown',), ('--resume', ''), ('-f', root / 'absent'), ('-C', root / 'absent')]:
        assert run('claude-minase.sh', *args).returncode == 2
    assert run('claude-minase.sh', '-C', root, input=' \n').returncode == 2
    assert run('claude-minase.sh', '--help').returncode == 0
    passed('Claude help and invalid inputs')

    # PATH を限定し、マシンに Claude がある場合も「未導入」を再現する。
    missing = root / 'missing-bin'
    missing.mkdir()
    for name in ('bash', 'dirname', 'readlink', 'git'):
        (missing / name).symlink_to(shutil.which(name))
    result = run('claude-minase.sh', 'task', overrides={'PATH': str(missing)})
    assert result.returncode == 2 and 'claude が見つからない' in result.stderr
    passed('missing Claude explicitly exits 2')

    # 不正な role 本文は、bin/home の配置に入る前に失敗させる。
    fixture = root / 'invalid-core'
    for name in ('setup', 'roles', 'codex/agents'):
        (fixture / name).mkdir(parents=True, exist_ok=True)
    shutil.copyfile(CORE / 'setup/install-codex-agents.sh', fixture / 'setup/install-codex-agents.sh')
    shutil.copyfile(CORE / 'codex/agents/makabe.toml.tmpl', fixture / 'codex/agents/makabe.toml.tmpl')
    (fixture / 'codex/makabe.md').write_text('contract')
    for invalid, message in [("'" * 3, '三連単引用符'), ('control' + chr(1), '制御文字')]:
        (fixture / 'roles/makabe.md').write_text(invalid)
        result = subprocess.run(['bash', str(fixture / 'setup/install-codex-agents.sh'),
                                 '--consumer', str(root)], capture_output=True, text=True, timeout=10)
        assert result.returncode != 0 and message in result.stderr
        assert not (root / '.codex/agents/makabe.toml').exists()
    passed('installer rejects triple quotes and control characters before writing consumer or home files')

print(f'1..{count}')
