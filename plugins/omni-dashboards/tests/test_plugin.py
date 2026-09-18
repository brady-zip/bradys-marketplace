"""Stdlib offline acceptance: real shell wrappers, fake providers, real report gates."""
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
from common import Blocked, read_jsonc, schema_digest
from review import PHASES, parse_rating, validate_ledger

PNG = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j1ioAAAAASUVORK5CYII=')


def png_chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))


OTHER_PNG = (b'\x89PNG\r\n\x1a\n' + png_chunk(b'IHDR', struct.pack('>IIBBBBB', 1, 1, 8, 2, 0, 0, 0)) +
             png_chunk(b'IDAT', zlib.compress(b'\x00\xff\x00\x00')) + png_chunk(b'IEND', b''))
MODEL = '00000000-0000-4000-8000-000000000001'
SECRET = 'DO_NOT_PRINT_SECRET'


class Harness(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='omni-plugin-tests-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.plugin = self.root / 'plugin'
        shutil.copytree(ROOT / 'scripts', self.plugin / 'scripts', ignore=shutil.ignore_patterns('__pycache__'))
        (self.plugin / 'knowledge').mkdir()
        pins = json.loads((ROOT / 'knowledge/dependencies.json').read_text())
        self.schema = self.root / 'fake-schema.json'
        self.schema.write_text(json.dumps({'$id': pins['schema_id'], 'fixture': True}))
        pins['schema_sha256'] = schema_digest(json.loads(self.schema.read_text()))
        self.browser = self.root / 'Chrome Beta'
        self.browser.touch()
        pins['chrome_binary'] = str(self.browser)
        (self.plugin / 'knowledge/dependencies.json').write_text(json.dumps(pins))
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        (self.bin / 'python3').symlink_to(sys.executable)
        for name in ('chart-room', 'omni', 'llm', 'mise', 'pgrep', 'node'):
            shutil.copy2(ROOT / 'tests/fixtures/fake_tool.py', self.bin / name)
            (self.bin / name).chmod(0o755)
        self.config = self.root / 'official/config.json'
        self.config.parent.mkdir()
        self.config.write_text(json.dumps({'defaultProfile': 'zip', 'profiles': {
            'zip': {'apiEndpoint': 'https://zip.omniapp.co', 'apiKey': SECRET}
        }}))
        self.calls = self.root / 'calls.jsonl'
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(('OMNI_', 'CHART_ROOM_', 'FAKE_'))}
        self.env.update(PATH=str(self.bin) + ':/usr/bin:/bin',
                        OMNI_CONFIG_PATH=str(self.config), FAKE_CALLS=str(self.calls),
                        FAKE_SCHEMA=str(self.schema), FAKE_MODEL=MODEL,
                        PYTHONDONTWRITEBYTECODE='1')
        self.source = self.root / 'dashboard with spaces.omni.jsonc'
        shutil.copy2(ROOT / 'tests/fixtures/dashboard.omni.jsonc', self.source)

    def invoke(self, script, *args, scenario=''):
        env = dict(self.env, FAKE_SCENARIO=scenario)
        return subprocess.run(['/bin/bash', str(self.plugin / 'scripts' / script), *map(str, args)],
                              env=env, text=True, capture_output=True, timeout=30)

    def preflight(self, *args, scenario=''):
        result = self.invoke('preflight.sh', '--skill', 'expand', '--file', self.source,
                             '--profile', 'zip', '--require-context', '--json', *args,
                             scenario=scenario)
        self.assertNotIn(SECRET, result.stdout + result.stderr)
        self.assertTrue(result.stdout, result.stderr)
        return result, json.loads(result.stdout)

    def history(self):
        return [json.loads(line) for line in self.calls.read_text().splitlines()] if self.calls.exists() else []

    def remote_calls(self):
        return [x for x in self.history() if x[0] == 'omni' and '--base-url' in x]

    def assert_code(self, report, code):
        self.assertIn(code, [row['code'] for row in report['checks']], report)


class PreflightTests(Harness):
    def test_healthy_context_and_no_remote_mutation(self):
        before = self.config.read_bytes()
        result, report = self.preflight()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(report['status'], 'OK')
        calls = self.history()
        first_auth = next(i for i, call in enumerate(calls) if call[0] == 'omni' and '--base-url' in call)
        self.assertTrue(any('--schema' in call for call in calls[:first_auth]))
        self.assertTrue(all(call[5:7] in (['whoami', 'whoami'], ['models', 'list'],
            ['documents', 'v2-get'], ['documents', 'get-permissions'], ['documents', 'list-drafts'])
            for call in self.remote_calls()))
        self.assertEqual(before, self.config.read_bytes())
        self.assertNotIn(SECRET, self.calls.read_text())

    def test_missing_cli(self):
        (self.bin / 'omni').unlink()
        result, report = self.preflight()
        self.assertEqual(result.returncode, 1)
        self.assert_code(report, 'MISSING_OMNI_CLI')
        self.assertEqual(self.remote_calls(), [])

    def test_old_chart_room_is_not_presence_success(self):
        # Even 1.10.0 with matching schema lacks the required runtime fixes.
        for scenario in ('old_chart_room', 'chart_room_before_fixes'):
            with self.subTest(scenario=scenario):
                result, report = self.preflight(scenario=scenario)
                self.assertEqual(result.returncode, 1)
                self.assert_code(report, 'OUTDATED_CHART_ROOM')
                self.assertIn('1.10.1+', result.stdout)

    def test_outdated_official_capabilities_precede_auth(self):
        for scenario, code in [('old_omni', 'OUTDATED_OMNI_CLI'), ('outdated', 'OUTDATED_CAPABILITIES')]:
            with self.subTest(scenario=scenario):
                result, report = self.preflight(scenario=scenario)
                self.assertEqual(result.returncode, 1)
                self.assert_code(report, code)
                self.assertEqual(self.remote_calls(), [])

    def test_schema_mismatch(self):
        self.schema.write_text('{}')
        result, report = self.preflight()
        self.assertEqual(result.returncode, 1)
        self.assert_code(report, 'SCHEMA_MISMATCH')

    def test_schema_pin_survives_json_serialization(self):
        value = json.loads(self.schema.read_text())
        value["description"] = "Native configuration — preserved"
        pins_path = self.plugin / 'knowledge/dependencies.json'
        pins = json.loads(pins_path.read_text())
        pins["schema_sha256"] = schema_digest(value)
        pins_path.write_text(json.dumps(pins))
        for ascii_only in (True, False):
            with self.subTest(ascii_only=ascii_only):
                self.schema.write_text(json.dumps(value, ensure_ascii=ascii_only, indent=2))
                result, report = self.preflight()
                self.assertEqual(result.returncode, 0, report)

    def test_expired_token(self):
        result, report = self.preflight(scenario='expired')
        self.assertEqual(result.returncode, 1)
        self.assert_code(report, 'UNAUTHENTICATED')
        self.assertFalse(any('models' in call for call in self.remote_calls()))

    def test_wrong_profile_host_never_forwards_credential(self):
        config = json.loads(self.config.read_text())
        config['profiles']['zip']['apiEndpoint'] = 'https://different.omniapp.co'
        self.config.write_text(json.dumps(config))
        result, report = self.preflight()
        self.assertEqual(result.returncode, 1)
        self.assert_code(report, 'WRONG_PROFILE_HOST')
        self.assertEqual(self.remote_calls(), [])

    def test_missing_credentials(self):
        self.config.unlink()
        result, report = self.preflight()
        self.assertEqual(result.returncode, 1)
        self.assert_code(report, 'MISSING_PROFILE')
        self.assertEqual(self.remote_calls(), [])

    def test_resource_failures_are_distinct(self):
        for scenario, code in [('denied_model', 'MODEL_PERMISSION_DENIED'),
                               ('inaccessible_model', 'MODEL_INACCESSIBLE'),
                               ('denied_target', 'PERMISSION_DENIED'),
                               ('hidden_target', 'NOT_FOUND_OR_HIDDEN'),
                               ('pr_required', 'PR_REQUIRED'), ('draft', 'DRAFT_CONFLICT')]:
            with self.subTest(scenario=scenario):
                result, report = self.preflight(scenario=scenario)
                self.assertEqual(result.returncode, 1)
                self.assert_code(report, code)

    def test_unknown_auth_is_deferred_not_success_or_absence(self):
        result, report = self.preflight(scenario='unreachable_auth')
        self.assertEqual(result.returncode, 2)
        self.assertEqual(report['status'], 'DEFERRED')
        self.assert_code(report, 'PROBE_UNAVAILABLE')
        self.assertEqual(report['failed'], 0)

    def test_unreachable_gemini(self):
        for scenario, code in [('unreachable_gemini', 'GEMINI_UNAVAILABLE'),
                               ('malformed_gemini', 'GEMINI_MALFORMED')]:
            with self.subTest(scenario=scenario):
                result, report = self.preflight('--skill', 'iterate', scenario=scenario)
                self.assertEqual(result.returncode, 1)
                self.assert_code(report, code)

    def test_absent_browser_and_deferred_probe(self):
        self.browser.unlink()
        result, report = self.preflight('--skill', 'iterate')
        self.assert_code(report, 'BROWSER_ABSENT')
        self.assertEqual(result.returncode, 1)
        self.browser.touch()
        result, report = self.preflight('--skill', 'iterate', scenario='deferred_browser')
        self.assert_code(report, 'PROBE_UNAVAILABLE')
        self.assertEqual(report['failed'], 0)
        self.assertEqual(result.returncode, 2)

    def test_offline_mode_does_not_authenticate_or_call_gemini(self):
        result = self.invoke('check-setup.sh', '--offline', '--json')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.remote_calls(), [])
        self.assertFalse(any(x[0] == 'llm' and '-m' in x for x in self.history()))

    def test_doctor_rejects_repair(self):
        result = self.invoke('check-setup.sh', '--repair')
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.history(), [])


class ReviewTests(Harness):
    def prepare_evidence(self, multiple=False):
        value = read_jsonc(self.source)
        if multiple:
            value['_meta']['sections'].append({'id': 'detail', 'title': 'Detail', 'questions': [0]})
        value['document']['queryPresentations']['data']['1'] = {
            'type': 'query', 'query': {'fields': ['fixture.count']}}
        self.source.write_text(json.dumps(value))
        self.pass_dir = self.root / 'pass-1'
        self.pass_dir.mkdir()
        (self.pass_dir / 'overview.png').write_bytes(PNG)
        self.snapshot = self.pass_dir / 'source.omni.jsonc'
        shutil.copyfile(self.source, self.snapshot)
        self.evidence = self.pass_dir / 'browser.json'
        evidence = {
            'url': 'https://zip.omniapp.co/dashboards/fixture-test',
            'definition_sha256': hashlib.sha256(self.source.read_bytes()).hexdigest(),
            'publication_verified': True, 'publication_evidence': 'Synthetic test fixture, not live',
            'loading_complete': True, 'visible_errors': [], 'query_health': 'PASS',
            'viewport': {'width': 1440, 'height': 1000}, 'filters': {},
            'time_window': '2026-09-01 to 2026-09-07', 'timezone': 'UTC',
            'tiles': {'1': {'status': 'ready', 'query_executed': True,
                            'query_evidence': 'Synthetic executed-query fixture', 'observed_at': '2026-09-17T00:00:00Z'}},
            'sections': [{'id': 'overview', 'screenshot': 'overview.png'}],
        }
        if multiple:
            (self.pass_dir / 'detail.png').write_bytes(OTHER_PNG)
            evidence['sections'].append({'id': 'detail', 'screenshot': 'detail.png'})
        self.evidence.write_text(json.dumps(evidence))
        return value, evidence

    def evaluate(self, scenario='', raw=None, mutation=None):
        env = dict(self.env, FAKE_SCENARIO=scenario)
        if raw is not None:
            env['FAKE_RATING'] = raw
        if mutation is not None:
            env['FAKE_MUTATION'] = json.dumps(mutation)
        return subprocess.run([sys.executable, str(ROOT / 'scripts/review.py'), 'evaluate',
            '--definition', str(self.source), '--evidence', str(self.evidence),
            '--out', str(self.pass_dir / 'gemini'), '--approved-screenshots'],
            env=env, text=True, capture_output=True, timeout=10)

    def write_session(self, rating_done=True):
        ledger = [{'phase': p, 'status': 'DONE', 'reason': 'Synthetic fixture evidence'} for p in PHASES['iterate']]
        if not rating_done:
            next(x for x in ledger if x['phase'] == 'gemini')['status'] = 'FAILED'
        value = {'workflow': 'iterate', 'definition': str(self.source),
                 'versions': {'chart_room': 'fixture', 'omni': 'fixture'},
                 'acceptance': {'status': 'ACCEPTED', 'reason': 'Fixture user response'},
                 'ledger': ledger, 'passes': [{'definition': 'pass-1/source.omni.jsonc',
                     'evidence': 'pass-1/browser.json', 'evaluation': 'pass-1/gemini/evaluation.json', 'decisions': []}],
                 'gaps': [], 'failures': [], 'merge_route': 'Fixture merge route'}
        path = self.root / 'session.json'
        path.write_text(json.dumps(value))
        return path

    def report(self, session):
        return subprocess.run([sys.executable, str(ROOT / 'scripts/review.py'), 'report', '--session', str(session)],
                              env=self.env, text=True, capture_output=True, timeout=10)

    def test_successful_evaluation_and_self_contained_report(self):
        self.prepare_evidence()
        result = self.evaluate()
        self.assertEqual(result.returncode, 0, result.stderr)
        report = self.report(self.write_session())
        self.assertEqual(report.returncode, 0, report.stderr)
        html = (self.root / 'iteration-report.html').read_text()
        self.assertIn('ACCEPTED', html)
        self.assertIn('data:image/png;base64,', html)
        self.assertIn('fixture-test', html)
        self.assertIn('fixture-prod', html)
        self.assertNotIn('<script', html)
        llm_call = next(c for c in self.history() if c[0] == 'llm')
        self.assertIn('--no-log', llm_call)
        self.assertIn('-a', llm_call)
        evaluation = json.loads((self.pass_dir / 'gemini/evaluation.json').read_text())
        record = evaluation['screenshots'][0]
        self.assertEqual(record['id'], 'overview')
        self.assertEqual(record['sha256'], hashlib.sha256(PNG).hexdigest())
        attachment = self.pass_dir / 'gemini' / record['attachment']
        self.assertEqual(attachment.read_bytes(), PNG)
        self.assertEqual(attachment.stat().st_mode & 0o777, 0o400)
        self.assertIn(str(attachment.resolve()), llm_call)
        self.assertNotIn(str((self.pass_dir / 'overview.png').resolve()), llm_call)
        self.assertIn(base64.b64encode(PNG).decode(), html)

    def assert_stale_report(self, section=None):
        result = self.report(self.write_session())
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn('STALE_EVIDENCE', result.stderr)
        if section:
            self.assertIn(section, result.stderr)
        self.assertFalse((self.root / 'iteration-report.html').exists())

    def test_overwritten_screenshot_invalidates_rating(self):
        self.prepare_evidence()
        self.assertEqual(self.evaluate().returncode, 0)
        before = self.evidence.read_bytes()
        (self.pass_dir / 'overview.png').write_bytes(OTHER_PNG)
        self.assert_stale_report('overview')
        self.assertEqual(self.evidence.read_bytes(), before)

    def test_missing_screenshot_invalidates_rating(self):
        self.prepare_evidence()
        self.assertEqual(self.evaluate().returncode, 0)
        (self.pass_dir / 'overview.png').unlink()
        self.assert_stale_report('overview')

    def test_substituted_screenshot_invalidates_rating(self):
        self.prepare_evidence()
        self.assertEqual(self.evaluate().returncode, 0)
        replacement = self.pass_dir / 'replacement.png'
        replacement.write_bytes(OTHER_PNG)
        screenshot = self.pass_dir / 'overview.png'
        screenshot.unlink()
        screenshot.symlink_to(replacement)
        self.assert_stale_report('overview')

    def test_every_section_is_bound_and_unchanged_sections_render(self):
        self.prepare_evidence(multiple=True)
        self.assertEqual(self.evaluate().returncode, 0)
        for name, original, replacement in [('overview', PNG, OTHER_PNG), ('detail', OTHER_PNG, PNG)]:
            with self.subTest(section=name):
                screenshot = self.pass_dir / (name + '.png')
                screenshot.write_bytes(replacement)
                self.assert_stale_report(name)
                screenshot.write_bytes(original)
        result = self.report(self.write_session())
        self.assertEqual(result.returncode, 0, result.stderr)
        html = (self.root / 'iteration-report.html').read_text()
        self.assertIn('ACCEPTED', result.stdout)
        self.assertEqual(html.count('data:image/png;base64,'), 2)
        for data in (PNG, OTHER_PNG):
            self.assertIn(base64.b64encode(data).decode(), html)

    def test_swapped_section_images_invalidate_rating(self):
        self.prepare_evidence(multiple=True)
        self.assertEqual(self.evaluate().returncode, 0)
        (self.pass_dir / 'overview.png').write_bytes(OTHER_PNG)
        (self.pass_dir / 'detail.png').write_bytes(PNG)
        self.assert_stale_report('overview')

    def test_old_or_incomplete_image_manifests_require_new_evaluation(self):
        self.prepare_evidence(multiple=True)
        self.assertEqual(self.evaluate().returncode, 0)
        path = self.pass_dir / 'gemini/evaluation.json'
        evaluation = json.loads(path.read_text())
        records = evaluation['screenshots']
        for manifest in (None, records[:1], list(reversed(records)), [records[0], records[0]]):
            with self.subTest(manifest=manifest):
                evaluation['screenshots'] = manifest
                path.write_text(json.dumps(evaluation))
                self.assert_stale_report()

    def test_missing_or_changed_evaluation_copy_invalidates_rating(self):
        self.prepare_evidence()
        self.assertEqual(self.evaluate().returncode, 0)
        path = self.pass_dir / 'gemini/screenshots/1.png'
        path.chmod(0o600)
        path.write_bytes(OTHER_PNG)
        self.assert_stale_report('overview')
        path.unlink()
        self.assert_stale_report('overview')

    def test_mutation_during_evaluation_has_no_accepted_rating(self):
        self.prepare_evidence()
        replacement = self.root / 'replacement.png'
        replacement.write_bytes(OTHER_PNG)
        mutations = [
            {'target': str(self.pass_dir / 'overview.png'), 'replacement': str(replacement)},
            {'target': str(self.pass_dir / 'overview.png'), 'delete': True},
            {'attachment': 0, 'replacement': str(replacement)},
            {'target': str(self.evidence)},
            {'target': str(self.source)},
        ]
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                result = self.evaluate(mutation=mutation)
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn('STALE_EVIDENCE', result.stderr)
                self.assertFalse((self.pass_dir / 'gemini/evaluation.json').exists())
                failure = json.loads((self.pass_dir / 'gemini/failure.json').read_text())
                self.assertEqual(failure, {'code': 'STALE_EVIDENCE', 'rating': None})
                shutil.rmtree(self.pass_dir / 'gemini')
                (self.pass_dir / 'overview.png').write_bytes(PNG)

    def test_transient_recapture_cannot_change_submitted_pixels(self):
        self.prepare_evidence()
        replacement = self.root / 'replacement.png'
        replacement.write_bytes(OTHER_PNG)
        result = self.evaluate(mutation={'target': str(self.pass_dir / 'overview.png'),
                                        'replacement': str(replacement), 'restore': True})
        self.assertEqual(result.returncode, 0, result.stderr)
        attachments = json.loads((self.root / 'attachments.json').read_text())
        self.assertEqual([a['sha256'] for a in attachments], [hashlib.sha256(PNG).hexdigest()])
        self.assertNotEqual(attachments[0]['path'], str((self.pass_dir / 'overview.png').resolve()))
        self.assertEqual(self.report(self.write_session()).returncode, 0)

    def test_duplicate_sections_fail_before_gemini(self):
        value, evidence = self.prepare_evidence()
        evidence['sections'] *= 2
        self.evidence.write_text(json.dumps(evidence))
        result = self.evaluate()
        self.assertEqual(result.returncode, 1)
        self.assertIn('exactly once', result.stderr)
        self.assertEqual(self.history(), [])

    def test_broken_query_prevents_gemini_call(self):
        value, evidence = self.prepare_evidence()
        evidence['query_health'] = 'FAILED'
        self.evidence.write_text(json.dumps(evidence))
        result = self.evaluate()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('broken', result.stderr)
        self.assertEqual(self.history(), [])

    def test_missing_data_is_not_a_plausible_empty_tile(self):
        value, evidence = self.prepare_evidence()
        evidence['tiles']['1']['status'] = 'expected_empty'
        evidence['tiles']['1']['empty_reason'] = 'Requested field is absent from complete catalog'
        evidence['tiles']['1']['query_executed'] = False
        evidence['tiles']['1']['empty_accepted'] = False
        self.evidence.write_text(json.dumps(evidence))
        result = self.evaluate()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.history(), [])

    def test_unfilled_skeleton_cannot_pass(self):
        value, evidence = self.prepare_evidence()
        value['document']['queryPresentations']['data']['1'] = {'type': 'blank'}
        self.source.write_text(json.dumps(value))
        evidence['definition_sha256'] = hashlib.sha256(self.source.read_bytes()).hexdigest()
        evidence['tiles'] = {}
        self.evidence.write_text(json.dumps(evidence))
        result = self.evaluate()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('skeleton', result.stderr)
        self.assertEqual(self.history(), [])

    def test_unavailable_gemini_has_no_rating(self):
        self.prepare_evidence()
        result = self.evaluate(scenario='unreachable_gemini')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('GEMINI_UNAVAILABLE', result.stderr)
        self.assertNotIn(SECRET, result.stderr)
        self.assertFalse((self.pass_dir / 'gemini/evaluation.json').exists())
        self.assertIsNone(json.loads((self.pass_dir / 'gemini/failure.json').read_text())['rating'])

    def test_malformed_rating_has_no_evaluation(self):
        self.prepare_evidence()
        result = self.evaluate(raw='RATING: probably 8')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('MALFORMED_RATING', result.stderr)
        self.assertFalse((self.pass_dir / 'gemini/evaluation.json').exists())

    def test_wrong_test_url_missing_section_and_stale_source_block(self):
        value, original = self.prepare_evidence()
        for key, changed in [('url', 'https://zip.omniapp.co/dashboards/fixture-prod'),
                             ('sections', []), ('definition_sha256', 'old-revision')]:
            with self.subTest(key=key):
                evidence = dict(original, **{key: changed})
                self.evidence.write_text(json.dumps(evidence))
                self.assertNotEqual(self.evaluate().returncode, 0)
                self.assertEqual(self.history(), [])

    def test_low_rating_cannot_claim_done(self):
        self.prepare_evidence()
        self.assertEqual(self.evaluate(raw='{"rating":6.5,"summary":"Needs work","suggestions":[]}').returncode, 0)
        self.assertNotEqual(self.report(self.write_session()).returncode, 0)
        result = self.report(self.write_session(rating_done=False))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('NOT PASSED', result.stdout)

    def test_stale_rating_after_source_edit_cannot_claim_done(self):
        self.prepare_evidence()
        self.assertEqual(self.evaluate().returncode, 0)
        self.source.write_text(self.source.read_text() + '\n')
        result = self.report(self.write_session())
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('current', result.stderr)

    def test_pending_acceptance_is_not_done(self):
        self.prepare_evidence()
        self.assertEqual(self.evaluate().returncode, 0)
        path = self.write_session()
        session = json.loads(path.read_text())
        session['acceptance']['status'] = 'PENDING'
        path.write_text(json.dumps(session))
        self.assertNotEqual(self.report(path).returncode, 0)
        next(row for row in session['ledger'] if row['phase'] == 'acceptance')['status'] = 'SKIPPED'
        path.write_text(json.dumps(session))
        result = self.report(path)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('acceptance incomplete', result.stdout)

    def test_suggestions_applied_after_last_rating_need_another_pass(self):
        self.prepare_evidence()
        response = json.dumps({'rating': 8, 'summary': 'Clear', 'suggestions': [
            {'id': 's1', 'suggestion': 'Increase labels', 'action': 'Increase font size'}]})
        self.assertEqual(self.evaluate(raw=response).returncode, 0)
        path = self.write_session()
        session = json.loads(path.read_text())
        session['passes'][0]['decisions'] = [{'id': 's1', 'status': 'APPLIED', 'reason': 'Changed after review'}]
        path.write_text(json.dumps(session))
        self.assertNotEqual(self.report(path).returncode, 0)

    def test_five_passes_below_seven_do_not_pass(self):
        self.prepare_evidence()
        self.assertEqual(self.evaluate(raw='{"rating":6,"summary":"Needs work","suggestions":[]}').returncode, 0)
        path = self.write_session(rating_done=False)
        session = json.loads(path.read_text())
        for number in range(2, 6):
            shutil.copytree(self.pass_dir, self.root / f'pass-{number}')
            session['passes'].append({key: value.replace('pass-1', f'pass-{number}') if isinstance(value, str) else value
                                      for key, value in session['passes'][0].items()})
        path.write_text(json.dumps(session))
        result = self.report(path)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('NOT PASSED', result.stdout)

    def test_unresolved_failure_invalidates_an_earlier_good_rating(self):
        self.prepare_evidence()
        self.assertEqual(self.evaluate().returncode, 0)
        path = self.write_session()
        session = json.loads(path.read_text())
        session['failures'] = [{'phase': 'query-health', 'reason': 'Newest query failed'}]
        path.write_text(json.dumps(session))
        self.assertNotEqual(self.report(path).returncode, 0)

    def test_no_evaluation_partial_report(self):
        self.prepare_evidence()
        path = self.write_session(rating_done=False)
        session = json.loads(path.read_text())
        session['passes'] = []
        session['failures'] = [{'phase': 'gemini', 'reason': 'Provider unavailable'}]
        session['acceptance'] = {'status': 'PENDING'}
        next(x for x in session['ledger'] if x['phase'] == 'acceptance')['status'] = 'SKIPPED'
        path.write_text(json.dumps(session))
        result = self.report(path)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('INCOMPLETE', result.stdout)
        self.assertIn('Provider unavailable', (self.root / 'iteration-report.html').read_text())


class PackagingTests(unittest.TestCase):
    def test_manifests_agree(self):
        manifest = json.loads((ROOT / '.claude-plugin/plugin.json').read_text())
        market = json.loads((ROOT.parents[1] / '.claude-plugin/marketplace.json').read_text())
        entries = [p for p in market['plugins'] if p['name'] == 'omni-dashboards']
        self.assertEqual(len(entries), 1)
        for key in ('name', 'description', 'version'):
            self.assertEqual(entries[0][key], manifest[key])
        self.assertRegex(manifest['version'], r'^\d{6}\.\d+$')
        self.assertEqual(entries[0]['source'], './plugins/omni-dashboards')

    def test_skill_contract_fixtures(self):
        for name, workflow in [('create-dashboard', 'create'), ('expand-dashboard', 'expand'),
                               ('iterate-dashboard', 'iterate'), ('setup', 'setup'), ('doctor', 'doctor')]:
            text = (ROOT / 'skills' / name / 'SKILL.md').read_text()
            self.assertIn('!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/', text)
            self.assertIn('DONE', text)
            self.assertIn('SKIPPED', text)
            self.assertIn('FAILED', text)
            self.assertNotRegex(text, r'\.dash\.json|DD_API_KEY|DD_APP_KEY|template_variables|dogshell')
            self.assertNotRegex(text, r'(?m)^\s*chart-room prod\b|omni login\b')
        create = (ROOT / 'skills/create-dashboard/SKILL.md').read_text()
        expand = (ROOT / 'skills/expand-dashboard/SKILL.md').read_text()
        self.assertIn('Skill(skill="omni-dashboards:expand-dashboard"', create)
        self.assertIn('Skill(skill="omni-dashboards:iterate-dashboard"', expand)
        self.assertIn('iteration was skipped', create)

    def test_browser_configuration_and_capability_discovery(self):
        mcp = json.loads((ROOT / '.mcp.json').read_text())
        self.assertEqual(set(mcp), {'omni-dashboard-viewer'})
        self.assertIn('--autoConnect', mcp['omni-dashboard-viewer']['args'])
        self.assertIn('--channel=beta', mcp['omni-dashboard-viewer']['args'])
        agent = (ROOT / 'agents/dashboard-browser.md').read_text()
        for capability in ('take_snapshot', 'take_screenshot', 'list_pages', 'evaluate_script'):
            self.assertIn(capability, agent)
        self.assertNotIn('bypassPermissions', agent)

    def test_portable_internal_references(self):
        for path in ROOT.rglob('*.md'):
            text = path.read_text()
            self.assertNotIn('/Users/bradywatkinson/', text)
            for ref in re.findall(r'@\$\{CLAUDE_PLUGIN_ROOT\}/([\w./-]+)', text):
                self.assertTrue((ROOT / ref.rstrip('.')).is_file(), (path, ref))

    def test_omitted_and_skipped_handoff_ledgers(self):
        rows = [{'phase': p, 'status': 'DONE', 'reason': 'fixture'} for p in PHASES['create']]
        with self.assertRaises(Blocked):
            validate_ledger('create', rows[:-1])
        rows[-2]['status'] = 'SKIPPED'
        with self.assertRaises(Blocked):
            validate_ledger('create', rows)
        rows[-1]['status'] = 'SKIPPED'
        validate_ledger('create', rows)
        rows[0]['reason'] = ''
        with self.assertRaises(Blocked):
            validate_ledger('create', rows)

    def test_rating_parser_rejects_false_confidence(self):
        for value in (True, None, '8', 0, 11, float('nan')):
            with self.subTest(value=value), self.assertRaises(Blocked):
                parse_rating(json.dumps({'rating': value, 'summary': 'test', 'suggestions': []}))
        self.assertEqual(parse_rating('{"rating":7.25,"summary":"Good","suggestions":[]}')['rating'], 7.25)

    def test_jsonc_preserves_urls_and_comment_like_strings(self):
        with tempfile.TemporaryDirectory() as folder:
            p = Path(folder) / 'test.omni.jsonc'
            p.write_text('{/* comment */ "url":"https://zip.omniapp.co//a", "note":"a,] /*x*/", "list":[1,],}')
            self.assertEqual(read_jsonc(p), {'url': 'https://zip.omniapp.co//a', 'note': 'a,] /*x*/', 'list': [1]})


if __name__ == '__main__':
    unittest.main()
