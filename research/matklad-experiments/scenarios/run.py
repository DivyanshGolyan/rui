#!/usr/bin/env python3
"""Drive real historical runtime fixtures; this file contains no runtime model."""
import hashlib, json, os, pathlib, re, shutil, subprocess, tarfile, tempfile, time
HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[2]
OUT = HERE / 'generated'
OUT.mkdir(exist_ok=True)

def call(args, **kw):
    return subprocess.run(list(map(str, args)), text=True, capture_output=True, timeout=180, **kw)

def require(ok, message):
    if not ok: raise AssertionError(message)

# Use the repository-pinned cached package, not the system SQLite library.
zon = (ROOT / 'build.zig.zon').read_text()
pkg = re.search(r'\.sqlite = .*?\.hash = "([^"]+)"', zon, re.S)[1]
env = call(['zig', 'env']).stdout
cache = pathlib.Path(re.search(r'\.global_cache_dir = "([^"]+)"', env)[1])
archive = cache / 'p' / (pkg + '.tar.gz')
if not archive.exists():
    fetched = call(['zig', 'build', '--fetch=all'], cwd=ROOT)
    require(fetched.returncode == 0, fetched.stderr)
sqlite = OUT / 'sqlite'
sqlite.mkdir(exist_ok=True)
if not any(sqlite.rglob('sqlite3.c')):
    with tarfile.open(archive) as package:
        package.extractall(sqlite, filter='data')
source = next(sqlite.rglob('sqlite3.c'))
build = (ROOT / 'build.zig').read_text().split('fn configureSqlite(', 1)[1].split('\nfn ', 1)[0]
macros = ['-D' + k + '=' + v for k,v in re.findall(r'addCMacro\("([^"]+)", "([^"]+)"\)', build)]
fixtures = {}
builds = []
for kind in ('effect', 'patch'):
    original = ROOT / 'src' / (kind + '_recovery_fixture.zig')
    binary = OUT / (kind + '-fixture')
    args = ['zig','build-exe',original,'-O','ReleaseSafe','-lc','-I',source.parent,
            '-cflags','-std=c99','-fno-strict-aliasing',*macros,'--',source,
            '-femit-bin=' + str(binary), '--cache-dir', OUT / 'zig-cache']
    started = time.monotonic()
    result = call(args, cwd=ROOT)
    require(result.returncode == 0, result.stderr)
    builds.append({'fixture':kind,'seconds':round(time.monotonic()-started,3),'source_sha256':hashlib.sha256(original.read_bytes()).hexdigest()})
    fixtures[kind] = binary

# Expectations are small data; mode-specific internal assertions remain in Zig.
CASES = [
 ('candidate-not-published','effect','crash-prepublication-model',86,[('recover-prepublication-model','finished')],None),
 ('transaction-not-committed','effect','crash-transaction-model',88,[('recover-prepublication-model','finished')],None),
 ('completion-published','effect','crash-published-model',87,[('recover-published-model','finished')],None),
 ('uncertain-bash-no-replay','effect','start-bash',0,[('resume-bash','indeterminate'),('resume-bash','indeterminate')],('uncertain.txt','x','x')),
 ('authorized-bash-dispatch','effect','start-authorized-bash',0,[('resume-authorized-bash','finished')],('uncertain.txt',None,'x')),
 ('patch-postimage-reconciliation','patch','start-mutation',0,[('resume-applied','finished'),('resume-finished','finished')],('note.txt','new\n','new\n')),
 ('patch-divergence-preserved','patch','start-attempt',0,[('resume-indeterminate','finished')],('note.txt','old\n','mine\n')),
 ('model-retry-and-late-evidence','effect','start-model',0,[('finish-model','finished'),('late-model','audited')],None),
]

def observation(path):
    return path.read_text() if path.exists() else None

def check_file(path, expected):
    require(observation(path) == expected, f'{path.name}: expected {expected!r}, observed {observation(path)!r}')

results, controls = [], []
with tempfile.TemporaryDirectory(prefix='rui-scenarios-') as temp:
    for name,kind,start,exit_code,steps,file_check in CASES:
        case = pathlib.Path(temp)/name
        state,repo = case/'state',case/'repo'
        state.mkdir(parents=True); repo.mkdir()
        require(call(['git','init','-q',repo]).returncode == 0,'git init failed')
        if kind == 'patch':
            (repo/'note.txt').write_text('old\n')
            require(call(['git','-C',repo,'add','note.txt']).returncode == 0,'git add failed')
        started = time.monotonic()
        first = call([fixtures[kind],start,state,repo])
        require(first.returncode == exit_code, f'{name}: exit {first.returncode}: {first.stderr}')
        identity = first.stdout.strip()
        require(bool(re.fullmatch(r'[0-9a-f]{16}(:[0-9a-f]{16})?',identity)), f'{name}: invalid identity {identity}')
        if file_check: check_file(repo/file_check[0],file_check[1])
        if name == 'patch-divergence-preserved': (repo/'note.txt').write_text('mine\n')
        if name == 'completion-published':
            wrong = call([fixtures[kind],'recover-prepublication-model',state,identity+':0000000000000001'])
            require(wrong.returncode != 0 and 'PrepublicationCrashGainedCompletionAuthority' in wrong.stderr, 'wrong recovery oracle did not reject committed candidate authority: ' + wrong.stderr)
            controls.append({'name':'published-as-unpublished','caught':True,'exit':wrong.returncode,'stderr':wrong.stderr.splitlines()[:2]})
        events = [{'mode':start,'exit':first.returncode}]
        for mode,expected in steps:
            args = [fixtures[kind],mode,state] + ([repo] if kind == 'patch' else []) + [identity]
            result = call(args)
            require(result.returncode == 0 and result.stdout.strip() == expected, f'{name}/{mode}: {result.stderr} {result.stdout}')
            events.append({'mode':mode,'exit':result.returncode,'observed':result.stdout.strip()})
            if file_check: check_file(repo/file_check[0],file_check[2])
        # Validate checker sensitivity without modifying production or its DB.
        if name == 'uncertain-bash-no-replay':
            (repo/'uncertain.txt').write_text('xx')
            try: check_file(repo/'uncertain.txt','x')
            except AssertionError as error: controls.append({'name':'duplicated-bash-side-effect','caught':True,'message':str(error)})
            else: raise AssertionError('negative control escaped')
        results.append({'name':name,'passed':True,'elapsed_seconds':round(time.monotonic()-started,3),'events':events})
report = {'source_commit':call(['git','rev-parse','HEAD'],cwd=ROOT).stdout.strip(), 'zig':call(['zig','version']).stdout.strip(), 'sqlite_package':pkg,'builds':builds,'cases':results,'negative_controls':controls,'scope':'historical production implementation; no relational Session/Turn, disk-first, physical custody, live provider or power-loss certification'}
(HERE/'results.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps({'cases_passed':len(results),'negative_controls_caught':len(controls),'results':str(HERE/'results.json')}))
