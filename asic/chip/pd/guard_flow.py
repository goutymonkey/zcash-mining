#!/usr/bin/env python3
"""Run a physical-design command, stopping its process group before disk fills."""
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time

floor = int(os.environ.get('MIN_FREE_GIB', '5')) * 1024**3
log = Path(os.environ.get('FLOW_LOG', '/work/build/plan-c-flow.log'))
status = Path(os.environ.get('FLOW_STATUS', '/work/build/plan-c-flow.exit'))
if shutil.disk_usage('.').free < floor:
    sys.exit('Insufficient free disk space to start flow')
with log.open('a', buffering=1) as out:
    proc = subprocess.Popen(sys.argv[1:], stdout=out, stderr=subprocess.STDOUT,
                            start_new_session=True)
    def stop(signum, frame):
        if proc.poll() is None:
            os.killpg(proc.pid, signal.SIGTERM)
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    disk_stop = False
    while proc.poll() is None:
        if shutil.disk_usage('.').free < floor:
            out.write('\nDISK GUARD: free space below threshold; stopping flow.\n')
            stop(None, None)
            disk_stop = True
            try:
                proc.wait(timeout=20)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
            break
        time.sleep(15)
    code = proc.wait()
    status.write_text(f'{"disk guard" if disk_stop else "flow"}: {code}\n')
    sys.exit(1 if disk_stop else code)
