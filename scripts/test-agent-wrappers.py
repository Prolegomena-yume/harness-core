#!/usr/bin/env python3
"""Fake CLI checks for the delegation wrappers; no model is started."""
import json
import os
import re
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


def load_models_env():
    """scripts/models.env を実際に bash で source して解決済みの値を読む(python 側で
    `${VAR:-...}` の展開ロジックを再実装しない、役員 人見 2026-09-24 裁定 A1/A2)。"""
    script = f'set -a; source "{CORE}/scripts/models.env"; set +a; env -0'
    out = subprocess.run(['bash', '-c', script], capture_output=True, timeout=10, check=True).stdout
    env = {}
    for chunk in out.split(b'\x00'):
        if b'=' in chunk:
            key, _, value = chunk.partition(b'=')
            env[key.decode()] = value.decode()
    return env


MODELS = load_models_env()

# ---- 退役した ID / 別名が scripts・agents・setup・各プロンプト(claude/codex/kimi)に残っていないか ----
_RETIRED_PATTERN = re.compile(r'gpt-5\.6-[a-z]+|claude-opus-5(?!-5)|--model[= ](opus|sonnet)\b')
_SCAN_DIRS = ['scripts', 'agents', 'setup', 'claude', 'codex', 'kimi']
_offenders = []
_self_path = Path(__file__).resolve()
for _dir_name in _SCAN_DIRS:
    _base = CORE / _dir_name
    if not _base.exists():
        continue
    for _path in sorted(_base.rglob('*')):
        if not _path.is_file() or _path.resolve() == _self_path:
            continue
        try:
            _text = _path.read_text()
        except (UnicodeDecodeError, OSError):
            continue
        for _match in _RETIRED_PATTERN.finditer(_text):
            _offenders.append(f'{_path.relative_to(CORE)}: {_match.group(0)!r}')
assert not _offenders, '退役した model id / 別名の --model が残っている:\n' + '\n'.join(_offenders)
passed('no retired model ids (gpt-5.6-*, bare claude-opus-5) or --model opus|sonnet aliases remain '
       'in scripts/agents/setup/claude/codex/kimi')

# ---- agents/*.md の frontmatter model: が scripts/models.env の値と一致するか ----
_frontmatter_expect = {
    'agents/minase.md': MODELS['MINASE_MODEL'],
    'agents/anno.md': MODELS['ANNO_MODEL'],
}
for _rel, _expect in _frontmatter_expect.items():
    _text = (CORE / _rel).read_text()
    _match = re.search(r'^model:\s*(\S+)\s*$', _text, re.MULTILINE)
    assert _match, f'{_rel}: frontmatter に model: が無い'
    assert _match.group(1) == _expect, f'{_rel}: frontmatter model {_match.group(1)!r} != models.env {_expect!r}'
passed('agents/*.md frontmatter model: matches scripts/models.env')

# ---- codex/agents/*.toml.tmpl の model が scripts/models.env の値と一致するか ----
_toml_expect = {
    'codex/agents/makabe.toml.tmpl': MODELS['MAKABE_CODEX_MODEL'],
}
for _rel, _expect in _toml_expect.items():
    _text = (CORE / _rel).read_text()
    _match = re.search(r'^model\s*=\s*"([^"]+)"', _text, re.MULTILINE)
    assert _match, f'{_rel}: model = が無い'
    assert _match.group(1) == _expect, f'{_rel}: toml model {_match.group(1)!r} != models.env {_expect!r}'
passed('codex/agents/*.toml.tmpl model matches scripts/models.env')


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

    for persona, name in [('takano', '鷹野'), ('minase', '水無瀬'), ('kashiwagi', '柏木'), ('makabe', '真壁'),
                          ('niekawa', '贄川'), ('anno', '庵野'), ('gennai', '源内')]:
        for alias in (persona, name):
            result = run('git-as', alias, 'status', '--short')
            assert result.returncode == 0, result.stderr
            data = json.loads(capture.read_text())
            assert data['argv'] == ['-c', f'user.name={name}', '-c', f'user.email={persona}@ai.yumemism.dev', 'status', '--short']
            assert data['identity'] == [name, f'{persona}@ai.yumemism.dev'] * 2
    passed('git-as accepts all seven English/Japanese roles (incl. 贄川/庵野/源内) and overrides author/committer')
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
    assert args[:5] == ['-p', '--model', 'claude-opus-5-5', '--output-format', 'json']
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

    # ---- genai.sh(源内の日本語リライト、fake agy / fake kimi)----
    agy_fake = '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
prompt = args[args.index('-p') + 1] if '-p' in args else ''
Path(os.environ['FAKE_CAPTURE']).write_text(json.dumps({'argv': args, 'cwd': os.getcwd(), 'prompt': prompt}))
if os.environ.get('FAKE_AGY_FAIL'):
    print('boom', file=sys.stderr)
    sys.exit(1)
print(json.dumps({'response': f'AGY:{prompt}'}))
'''
    (binary / 'agy').write_text(agy_fake)
    (binary / 'agy').chmod(0o755)

    kimi_fake = '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
prompt = args[args.index('-p') + 1] if '-p' in args else ''
agent_file = args[args.index('--agent-file') + 1] if '--agent-file' in args else ''
agent_file_text = Path(agent_file).read_text() if agent_file and Path(agent_file).exists() else ''
Path(os.environ['FAKE_CAPTURE']).write_text(json.dumps(
    {'argv': args, 'cwd': os.getcwd(), 'prompt': prompt, 'agent_file': agent_file,
     'agent_file_text': agent_file_text}))
print(json.dumps({'role': 'meta', 'type': 'system.version', 'version': 'fake'}))
print(json.dumps({'role': 'assistant', 'content': f'KIMI:{prompt}'}))
print(json.dumps({'role': 'meta', 'type': 'session.resume_hint', 'session_id': 'session_fake'}))
'''
    (binary / 'kimi').write_text(kimi_fake)
    (binary / 'kimi').chmod(0o755)

    genai_in = root / 'genai-in.md'
    genai_in.write_text('# heading\n\nsome text with `code`\n')
    genai_out = root / 'genai-out.md'
    result = run('genai.sh', genai_in, genai_out)
    assert result.returncode == 0, result.stderr
    data = json.loads(capture.read_text())
    assert data['argv'][0] == '-p'
    assert data['argv'][2:] == ['--model', 'gemini-3.8-flash-high', '--output-format', 'json',
                               '--dangerously-skip-permissions', '--disable-slash-commands']
    assert '日本語を整える、意味を変えない、Markdown 構造と code block を保つ、括弧で原文の語を添えない、本文だけを返す。' in data['prompt']
    assert 'some text with `code`' in data['prompt']
    assert data['cwd'] != str(root)  # 空の一時 cwd で走る
    assert genai_out.read_text() == f"AGY:{data['prompt']}"
    passed('genai.sh calls agy with the exact contract argv in an empty cwd and writes .response to out')

    result_k3 = run('genai.sh', genai_in, genai_out, '--k3')
    assert result_k3.returncode == 0, result_k3.stderr
    data_k3 = json.loads(capture.read_text())
    assert data_k3['argv'][0] == '-p'
    assert '--agent-file' in data_k3['argv'] and '-m' in data_k3['argv']
    assert data_k3['argv'][data_k3['argv'].index('-m') + 1] == 'kimi-code/k3-256k'
    assert data_k3['argv'][data_k3['argv'].index('--output-format') + 1] == 'stream-json'
    assert 'disallowedTools: [Bash, Write, Edit, Agent]' in data_k3['agent_file_text']
    assert genai_out.read_text() == f"KIMI:{data_k3['prompt']}\n"
    passed('genai.sh --k3 calls kimi with a disallowedTools agent-file and takes the last assistant content')

    result_fail = run('genai.sh', genai_in, genai_out, overrides={'FAKE_AGY_FAIL': '1'})
    assert result_fail.returncode != 0 and 'agy が失敗した' in result_fail.stderr
    passed('genai.sh surfaces an agy failure instead of writing a stale out file')

    big_in = root / 'genai-big.md'
    big_in.write_text('x' * 110_000)
    result_big = run('genai.sh', big_in, genai_out)
    assert result_big.returncode == 2 and '100KB を超える' in result_big.stderr
    passed('genai.sh refuses input over 100KB with exit 2 instead of splitting it')

    for args in [(), ('one',), ('a', 'b', 'c'), ('/absent', genai_out)]:
        assert run('genai.sh', *args).returncode == 2
    assert run('genai.sh', '--help').returncode == 0
    passed('genai.sh rejects a wrong argument count and a missing input file')

    # ---- harness-route.sh(4 サービスの rates、fake rates)----
    rates_fake = '''#!/usr/bin/env python3
import json, os, sys
service = sys.argv[1] if len(sys.argv) > 1 else ''
weekly_by_service = json.loads(os.environ.get('FAKE_RATES_WEEKLY', '{}'))
weekly = weekly_by_service.get(service)
print(json.dumps({'email': 'fake@example.invalid', 'remaining': {'5h': None, 'weekly': weekly, 'monthly': None}}))
'''
    (binary / 'rates').write_text(rates_fake)
    (binary / 'rates').chmod(0o755)

    result = run('harness-route.sh', overrides={'FAKE_RATES_WEEKLY': json.dumps(
        {'claude': 15, 'codex': 69, 'kimi': 25, 'agy': 10})})
    assert result.returncode == 0, result.stderr
    assert '源内: K3(agy が減りすぎ)' in result.stdout
    assert '贄川: Codex sol(kimi weekly < 30%)' in result.stdout
    assert 'Claude: 鷹野の窓だけに絞る' in result.stdout
    assert '実装: 真壁(通常)' in result.stdout
    passed('harness-route applies the threshold table to fake rates output and never launches anything')

    result_null = run('harness-route.sh', overrides={'FAKE_RATES_WEEKLY': json.dumps(
        {'claude': None, 'codex': None, 'kimi': None, 'agy': None})})
    assert result_null.returncode == 0, result_null.stderr
    assert result_null.stdout.count('claude: 不明') == 1
    assert result_null.stdout.count('codex : 不明') == 1
    assert result_null.stdout.count('kimi  : 不明') == 1
    assert result_null.stdout.count('agy   : 不明') == 1
    assert '源内: agy(通常)' in result_null.stdout
    assert '贄川: Kimi K3(通常)' in result_null.stdout
    passed('harness-route shows 不明 for null weekly and does not switch routing on it')

print(f'1..{count}')
