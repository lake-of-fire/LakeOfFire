import io
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest
from run import command, verify

class RunnerContractTests(unittest.TestCase):
    names = ['testFirst', 'testSecond']
    def log(self, outcomes=('passed', 'passed')):
        return io.StringIO('\n'.join(
            f"Test Case 'ReaderContentLoadingOwnershipTests.{name}' {outcome} (0.001 seconds)."
            for name, outcome in zip(self.names, outcomes)))
    def testCompletePass(self):
        self.assertEqual(verify(self.log(), 0, self.names)['passed'], 2)
    def testRuntimeFailure(self):
        self.assertEqual(verify(self.log(('failed','passed')), 1, self.names)['failed'], 1)
    def testMissingAndZeroReceipts(self):
        for rows in [[], ["Test Case 'ReaderContentLoadingOwnershipTests.testFirst' passed"]]:
            with self.assertRaises(ValueError): verify(rows, 0, self.names)
    def testDuplicateAndUnexpectedReceipts(self):
        for name in ['testFirst', 'testOther']:
            with self.assertRaises(ValueError):
                verify(list(self.log())+[f"Test Case 'ReaderContentLoadingOwnershipTests.{name}' passed"],0,self.names)
    def testSkippedReceipt(self):
        with self.assertRaises(ValueError): verify(self.log(('passed','skipped')),0,self.names)
    def testContradictoryStatus(self):
        for status in [1,-9,77]:
            with self.assertRaises(ValueError): verify(self.log(),status,self.names)
        with self.assertRaises(ValueError): verify(self.log(('failed','passed')),0,self.names)
    def testInvalidRoster(self):
        for names in [[],['testFirst','testFirst']]:
            with self.assertRaises(ValueError): verify(self.log(),0,names)
    def testRetainsCommandLogsAndExit(self):
        with tempfile.TemporaryDirectory() as path:
            root=Path(path)
            status=command([sys.executable,'-c',"import sys;print('out');print('err',file=sys.stderr);sys.exit(7)"],root,root,'check',5)
            self.assertEqual(status,7)
            self.assertEqual((root/'check.out').read_text(),'out\n')
            self.assertEqual((root/'check.err').read_text(),'err\n')
    def testTimeoutRetainsPartialLogAndKillsSeparateGroupChild(self):
        with tempfile.TemporaryDirectory() as path:
            root=Path(path);pid=None
            code="import subprocess,sys,time;from pathlib import Path;p=subprocess.Popen([sys.executable,'-c','import time;time.sleep(30)'],start_new_session=True);Path('child.pid').write_text(str(p.pid));print('started',flush=True);time.sleep(30)"
            try:
                with self.assertRaises(subprocess.TimeoutExpired):
                    command([sys.executable,'-c',code],root,root,'check',1)
                self.assertEqual((root/'check.out').read_text(),'started\n')
                pid=int((root/'child.pid').read_text())
                status=subprocess.run(['ps','-o','stat=','-p',str(pid)],capture_output=True,text=True,timeout=3).stdout.strip()
                self.assertTrue(not status or status.startswith('Z'), status)
            finally:
                if pid is None and (root/'child.pid').exists(): pid=int((root/'child.pid').read_text())
                if pid is not None:
                    try: os.kill(pid,signal.SIGKILL)
                    except ProcessLookupError: pass

if __name__=='__main__': unittest.main()
