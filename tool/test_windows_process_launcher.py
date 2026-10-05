"""Run against the built launcher, without requiring a Flutter test runner.

python tool/test_windows_process_launcher.py path/to/kelivo_process_launcher.exe
"""
import base64
import ctypes
from ctypes import wintypes
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

LAUNCHER = str(Path(sys.argv.pop(1)).resolve())
POWERSHELL = r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'


def encoded(script):
    return base64.b64encode(script.encode('utf-16-le')).decode('ascii')


def alive(pid):
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    kernel.OpenProcess.restype = wintypes.HANDLE
    kernel.GetExitCodeProcess.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)]
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    handle = kernel.OpenProcess(0x1000, False, pid)
    if not handle:
        return False
    try:
        code = wintypes.DWORD()
        return bool(kernel.GetExitCodeProcess(handle, ctypes.byref(code))) and code.value == 259
    finally:
        kernel.CloseHandle(handle)


class LauncherTest(unittest.TestCase):
    def launch(self, script):
        return subprocess.Popen(
            [LAUNCHER, POWERSHELL, '-NoProfile', '-NonInteractive', '-EncodedCommand', encoded(script)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            creationflags=subprocess.CREATE_NO_WINDOW,
        )

    def assert_stopped(self, pid):
        deadline = time.monotonic() + 3
        while alive(pid) and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertFalse(alive(pid), f'Child {pid} survived its job')

    def test_gate_blocks_all_user_code(self):
        with tempfile.TemporaryDirectory(prefix='kelivo-launcher-') as folder:
            marker = Path(folder) / 'gate.txt'
            script = "Set-Content -LiteralPath '{}' -Value bad".format(str(marker).replace("'", "''"))
            process = self.launch(script)
            try:
                out, err = process.communicate(b'', timeout=5)
                self.assertEqual(process.returncode, 125, err)
                self.assertFalse(marker.exists())
                self.assertEqual(out, b'')
            finally:
                if process.poll() is None:
                    process.kill()
                    process.communicate()

    def test_streams_unicode_and_preserves_exit_code(self):
        process = self.launch("[Console]::OutputEncoding=[Text.Encoding]::UTF8; Write-Output '한글 quotes \"ok\"'; [Console]::Error.Write('stderr'); exit 7")
        out, err = process.communicate(b'\n', timeout=10)
        self.assertEqual(process.returncode, 7)
        self.assertIn('한글 quotes "ok"', out.decode('utf-8-sig'))
        # Windows PowerShell can add CLIXML progress records for EncodedCommand.
        self.assertIn(b'stderr', err)
        self.assertNotIn(b'stderr', out)

    def child_script(self, wait_for_parent):
        child = encoded('Start-Sleep -Seconds 30')
        return (
            "$p=Start-Process -FilePath '{}' -ArgumentList @('-NoProfile','-NonInteractive','-EncodedCommand','{}') -WindowStyle Hidden -PassThru; "
            "[Console]::Out.WriteLine($p.Id); [Console]::Out.Flush(); {}"
        ).format(POWERSHELL, child, 'Start-Sleep -Seconds 30' if wait_for_parent else 'exit 0')

    def test_background_child_dies_when_shell_exits(self):
        process = self.launch(self.child_script(False))
        out, err = process.communicate(b'\n', timeout=10)
        self.assertEqual(process.returncode, 0, err)
        self.assert_stopped(int(out.strip()))

    def test_cancellation_kills_child_tree(self):
        process = self.launch(self.child_script(True))
        try:
            process.stdin.write(b'\n')
            process.stdin.flush()
            pid = int(process.stdout.readline().strip())
            self.assertTrue(alive(pid))
            process.kill()
            process.communicate(timeout=5)
            self.assert_stopped(pid)
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()


if __name__ == '__main__':
    unittest.main()
