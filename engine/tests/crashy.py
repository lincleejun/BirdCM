"""Decode stand-ins for spawned workers (must be importable by module name)."""
import os
import time

import numpy as np


def decode(job):
    if "bad" in job["path"]:
        os._exit(1)                                   # a native crash, as LibRaw would
    time.sleep(0.05)
    return {"frame": np.zeros((60, 90, 3), np.uint8), "width": 900, "height": 600, "orientation": 1,
            "source": "fake", "t_decode": 0.0, "t_save": 0.0, "pid": os.getpid()}
