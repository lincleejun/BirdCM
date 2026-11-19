"""Workers and exiftool must not outlive a server that dies without cleaning up (crash, SIGKILL)."""
import os
import signal
import subprocess
import sys
import time

import pytest

CHILD = r"""
import multiprocessing as mp, os, sys
from concurrent.futures import ProcessPoolExecutor
from birdcm import decode
pool = ProcessPoolExecutor(2, mp_context=mp.get_context("spawn"), initializer=decode.worker_init)

futs = [pool.submit(os.getpid) for _ in range(4)]
pids = sorted({f.result() for f in futs})
et = None
if decode.ExifTool.available():
    et = decode.ExifTool(); et._start(); pids.append(et.proc.pid)
print(" ".join(map(str, pids)), flush=True)
import time; time.sleep(600)
"""


def alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


def test_children_leave_when_the_server_is_killed():
    p = subprocess.Popen([sys.executable, "-c", CHILD], stdout=subprocess.PIPE, text=True,
                         cwd=os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    pids = [int(x) for x in p.stdout.readline().split()]
    assert pids and all(alive(x) for x in pids)   # one worker may take all four tiny tasks; exiftool may be absent (CI)
    os.kill(p.pid, signal.SIGKILL)
    p.wait()
    end = time.time() + 10
    while time.time() < end and any(alive(x) for x in pids):
        time.sleep(0.3)
    left = [x for x in pids if alive(x)]
    for x in left:
        os.kill(x, signal.SIGKILL)
    assert not left, f"still running after the server died: {left}"
