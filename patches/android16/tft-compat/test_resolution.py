#!/usr/bin/env python3
"""Exercise resolution transitions without touching a live Android session."""
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name('tft-resolution.sh')
PACKAGE = 'com.riotgames.league.teamfighttacticsvn'


class ResolutionTest(unittest.TestCase):
    def test_2k_and_stock_are_scoped_to_tft(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            files = root / 'data' / PACKAGE / 'files'
            files.mkdir(parents=True)
            prop = root / 'waydroid.prop'
            prop.write_text(f'waydroid.host_data_path={root}\n')
            log = root / 'calls'
            fake = root / 'waydroid'
            fake.write_text('#!/bin/bash\nprintf "%s\\n" "$*" >> "$TEST_LOG"\n'
                            'if [[ "$*" == "shell -- wm size" ]]; then printf "%b\\n" "${TEST_SIZE:-Physical size: 3840x2160}"; fi\n')
            fake.chmod(0o755)
            script = SCRIPT.read_text().replace('(( EUID != 0 )) || ', '').replace(
                'prop_file=/var/lib/waydroid/waydroid.prop', f'prop_file={prop}')
            env = {**os.environ, 'PATH': f'{root}:' + os.environ['PATH'], 'TEST_LOG': str(log)}
            def run(mode):
                return subprocess.run(['bash', '-c', script, 'script', mode], env=env,
                                      capture_output=True, text=True)
            result = run('2k')
            self.assertEqual(result.returncode, 0, result.stderr)
            target = files / 'UnrealGame/TFT/UECommandLine.txt'
            self.assertIn('-mobileresx=2496 -mobileresy=1404', target.read_text())
            self.assertIn(f'am compat enable DOWNSCALE_65 {PACKAGE}', log.read_text())
            self.assertNotIn('wm size reset', log.read_text())
            result = run('2k-smooth')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('-mobileresx=2304 -mobileresy=1296', target.read_text())
            self.assertIn(f'am compat enable DOWNSCALE_60 {PACKAGE}', log.read_text())
            result = run('2k')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(f'am compat reset DOWNSCALE_60 {PACKAGE}', log.read_text())
            result = run('stock')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(target.exists())
            self.assertIn(f'am compat reset DOWNSCALE_65 {PACKAGE}', log.read_text())
            env['TEST_SIZE'] = 'Physical size: 3840x2160\\nOverride size: 2560x1440'
            result = run('2k')
            self.assertNotEqual(result.returncode, 0, 'must reject an existing global display override')
            self.assertFalse(target.exists())


if __name__ == '__main__':
    unittest.main()
