"""Check that native smoke retries cannot hide configuration failures."""
import importlib.util
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location('smoke_presets', Path(__file__).with_name('smoke-presets.py'))
smoke = importlib.util.module_from_spec(spec)
spec.loader.exec_module(smoke)
DLL_INIT_FAILED = 0xC0000142


def result(code, stdout='', stderr=''):
    return subprocess.CompletedProcess([], code, stdout, stderr)


class NativeSmokeRetryTests(unittest.TestCase):
    def test_transient_signed_and_unsigned_status_share_timeout(self):
        for code in (DLL_INIT_FAILED, DLL_INIT_FAILED - 2**32):
            with self.subTest(code=code), \
                    patch.object(smoke.subprocess, 'run', side_effect=[result(code), result(0, 'verified')]) as run, \
                    patch.object(smoke.time, 'monotonic', side_effect=[100, 100, 100, 100.2]), \
                    patch.object(smoke.time, 'sleep') as sleep:
                self.assertEqual(smoke.run(['winws2.exe', '@config.txt']), 'verified')
                self.assertEqual(run.call_count, 2)
                self.assertEqual(run.call_args_list[0].kwargs['timeout'], 60)
                self.assertLess(run.call_args_list[1].kwargs['timeout'], 60)
                self.assertEqual(run.call_args.kwargs['env']['__COMPAT_LAYER'], 'RunAsInvoker')
                sleep.assert_called_once_with(0.2)

    def test_two_transient_failures_then_success(self):
        with patch.object(smoke.subprocess, 'run', side_effect=[result(DLL_INIT_FAILED), result(DLL_INIT_FAILED), result(0)]) as run, \
                patch.object(smoke.time, 'sleep'):
            self.assertEqual(smoke.run(['winws2.exe']), '')
            self.assertEqual(run.call_count, 3)

    def test_persistent_initialization_failure_is_an_error(self):
        with patch.object(smoke.subprocess, 'run', return_value=result(DLL_INIT_FAILED)) as run, \
                patch.object(smoke.time, 'sleep') as sleep:
            with self.assertRaisesRegex(RuntimeError, str(DLL_INIT_FAILED)):
                smoke.run(['winws2.exe'])
            self.assertEqual(run.call_count, 3)
            self.assertEqual(sleep.call_count, 2)

    def test_config_error_and_other_native_failures_are_not_retried(self):
        for code in (1, 0xC0000005):
            with self.subTest(code=code), \
                    patch.object(smoke.subprocess, 'run', return_value=result(code, stderr='invalid configuration')) as run, \
                    patch.object(smoke.time, 'sleep') as sleep:
                with self.assertRaisesRegex(RuntimeError, 'invalid configuration'):
                    smoke.run(['winws2.exe'])
                self.assertEqual(run.call_count, 1)
                sleep.assert_not_called()

    def test_other_program_is_not_retried(self):
        with patch.object(smoke.subprocess, 'run', return_value=result(DLL_INIT_FAILED)) as run:
            with self.assertRaises(RuntimeError):
                smoke.run(['powershell.exe'])
            self.assertEqual(run.call_count, 1)

    def test_timeout_is_not_retried(self):
        with patch.object(smoke.subprocess, 'run', side_effect=subprocess.TimeoutExpired('winws2.exe', 60)) as run:
            with self.assertRaises(subprocess.TimeoutExpired):
                smoke.run(['winws2.exe'])
            self.assertEqual(run.call_count, 1)

    def test_retry_is_not_started_after_deadline(self):
        with patch.object(smoke.subprocess, 'run', return_value=result(DLL_INIT_FAILED)) as run, \
                patch.object(smoke.time, 'monotonic', side_effect=[100, 100, 159.9]), \
                patch.object(smoke.time, 'sleep') as sleep:
            with self.assertRaises(RuntimeError):
                smoke.run(['winws2.exe'])
            self.assertEqual(run.call_count, 1)
            sleep.assert_not_called()


if __name__ == '__main__':
    unittest.main()
