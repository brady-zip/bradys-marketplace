"""Offline control-scope checks against the authoring reference."""
import copy
import json
from pathlib import Path
import runpy
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
from common import Blocked, read_jsonc

HELPER = ROOT / 'scripts/explain-controls.py'
explain = runpy.run_path(str(HELPER))['explain']


class ControlDocumentationTests(unittest.TestCase):
    def setUp(self):
        self.value = read_jsonc(ROOT / 'examples/reference.omni.jsonc')

    def test_reference_scopes_and_excluded_blank_tile(self):
        team, priority = explain(self.value)
        self.assertEqual([t['id'] for t in team['mapped']], ['1', '2'])
        self.assertEqual([t['id'] for t in team['excluded']], ['3', '4', '5'])
        self.assertEqual([t['id'] for t in priority['mapped']], ['1', '2', '3', '4'])
        self.assertEqual([t['id'] for t in priority['excluded']], ['5'])
        self.assertEqual(team['implicit'], [])
        self.assertEqual(team['mapped'][0]['field'], 'example_events.team')

    def test_absent_map_entries_never_become_exclusions(self):
        del self.value['document']['controls']['data']['1']['map']['3']
        del self.value['document']['controls']['data']['2']['map']
        team, priority = explain(self.value)
        self.assertEqual([t['id'] for t in team['implicit']], ['3'])
        self.assertNotIn('3', [t['id'] for t in team['excluded']])
        self.assertEqual(len(priority['implicit']), 5)
        self.assertEqual(priority['excluded'], [])

    def test_unknown_tile_and_invalid_override_fail(self):
        for key, field in [('999', False), ('1', True), ('1', ''), ('1', None)]:
            with self.subTest(key=key, field=field):
                value = copy.deepcopy(self.value)
                value['document']['controls']['data']['1']['map'][key] = field
                with self.assertRaises(Blocked):
                    explain(value)

    def test_cli_reads_reference_and_follows_changed_tile_names(self):
        result = subprocess.run([sys.executable, str(HELPER),
            str(ROOT / 'examples/reference.omni.jsonc'), '--format', 'json'],
            text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), explain(self.value))
        self.value['document']['queryPresentations']['data']['1']['name'] = 'New headline'
        self.assertEqual(explain(self.value)[0]['mapped'][0]['name'], 'New headline')


if __name__ == '__main__':
    unittest.main()
