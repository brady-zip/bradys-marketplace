#!/usr/bin/env python3
"""Deterministic external executables. No network, credentials, or live dashboards."""
import hashlib
import json
import os
from pathlib import Path
import sys

name = Path(sys.argv[0]).name
args = sys.argv[1:]
scenario = os.environ.get('FAKE_SCENARIO', '')
with open(os.environ['FAKE_CALLS'], 'a') as log:
    log.write(json.dumps([name, *args]) + '\n')

def emit(data):
    print(json.dumps(data))

def fail(status):
    print(json.dumps({'status': status, 'error': 'DO_NOT_PRINT_SECRET'}), file=sys.stderr)
    sys.exit(1)

if name == 'chart-room':
    target = Path(os.environ['CHART_ROOM_CONFIG_DIR']) / 'omni-dashboard.schema.json'
    target.write_bytes(Path(os.environ['FAKE_SCHEMA']).read_bytes())
    if '--version' in args:
        print({'old_chart_room': '1.9.0', 'chart_room_before_fixes': '1.10.0'}.get(scenario, '1.10.2'))
    elif '--help' in args:
        print('--provider --profile --format --model --prod-folder --test-folder --remote --json omni validate import models topics fields status login')
    elif args[0] == 'validate':
        emit({'outcome': 'VALIDATED', 'provider': 'omni', 'contractVersion': 1, 'remote': False})
    else:
        sys.exit('Unexpected chart-room command')
elif name == 'omni':
    if '--version' in args:
        print('omni version 1.2.0' if scenario == 'old_omni' else 'omni version 1.3.1')
    elif '--help' in args:
        print('v2-get' if scenario == 'outdated' else 'v2-create v2-get list-drafts v2-patch-draft v2-patch-draft-by-identifier v2-get-draft v2-publish-draft get-permissions')
    elif '--schema' in args:
        endpoint = {'v2-create': '/api/v2/documents', 'run': '/api/v1/query/run', 'whoami': '/api/v1/whoami'}[args[1]]
        emit({'path': endpoint, 'body': {}})
    else:
        assert args[:4] == ['--base-url', 'https://zip.omniapp.co', '--format', 'json']
        assert os.environ.get('OMNI_API_TOKEN') == 'DO_NOT_PRINT_SECRET'
        assert not Path(os.environ['OMNI_CONFIG_PATH']).exists()
        if scenario == 'expired':
            fail(401)
        if scenario == 'unreachable_auth':
            sys.exit(124)
        if args[4:6] == ['whoami', 'whoami']:
            model = os.environ['FAKE_MODEL']
            roles = {} if scenario == 'denied_model' else {model: {'permissions': ['USE_WORKBOOKS', 'QUERY_TOPICS']}}
            emit({'user': {'id': 'fixture-user', 'membershipId': 'fixture-member'}, 'orgRole': 'MEMBER', 'keyScope': 'user', 'rolesByModel': roles})
        elif args[4:6] == ['models', 'list']:
            emit({'records': [] if scenario == 'inaccessible_model' else [{'id': os.environ['FAKE_MODEL'], 'modelKind': 'SHARED', 'deletedAt': None}]})
        elif args[4:6] == ['documents', 'v2-get']:
            if scenario == 'denied_target':
                fail(403)
            if scenario == 'hidden_target':
                fail(404)
            emit({'modelId': os.environ['FAKE_MODEL']})
        elif args[4:6] == ['documents', 'get-permissions']:
            emit({'abilities': {'requirePullRequestToPublish': scenario == 'pr_required'}})
        elif args[4:6] == ['documents', 'list-drafts']:
            emit([{'identifier': 'existing-draft', 'branch': None}] if scenario == 'draft' else [])
        else:
            sys.exit('Unexpected Omni command')
elif name == 'llm':
    if args == ['models', 'list']:
        print('GeminiPro: gemini/gemini-2.5-flash')
    elif scenario == 'unreachable_gemini':
        print('DO_NOT_PRINT_SECRET', file=sys.stderr)
        sys.exit(1)
    elif '-a' not in args:
        print('{"rating":"high"}' if scenario == 'malformed_gemini' else 'OK')
    else:
        attachments = [Path(args[i + 1]) for i, arg in enumerate(args) if arg == '-a']
        mutation = json.loads(os.environ.get('FAKE_MUTATION', '{}'))
        if mutation:
            target = attachments[mutation['attachment']] if 'attachment' in mutation else Path(mutation['target'])
            before = target.read_bytes()
            if mutation.get('delete'):
                target.unlink()
            else:
                target.chmod(0o600)
                target.write_bytes(Path(mutation['replacement']).read_bytes() if 'replacement' in mutation else before + b'\n')
        # Observe attachments after the recapture, as a delayed llm upload would.
        Path(os.environ['FAKE_CALLS']).with_name('attachments.json').write_text(json.dumps([
            {'path': str(path), 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()} for path in attachments
        ]))
        if mutation.get('restore'):
            target.write_bytes(before)
        print(os.environ.get('FAKE_RATING', '{"rating":8,"summary":"Clear comparison.","suggestions":[]}'))
elif name == 'mise':
    print(str(Path(sys.argv[0]).parent.parent))
elif name == 'node':
    print('v22.0.0')
elif name == 'pgrep':
    if scenario == 'deferred_browser':
        sys.exit(3)
    if scenario == 'stopped_browser':
        sys.exit(1)
    print('12345')
else:
    sys.exit('Unexpected fake executable')
