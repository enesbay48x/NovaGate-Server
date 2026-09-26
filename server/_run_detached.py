"""Run a pytest selection FULLY DETACHED and report the outcome as JSON.

WHY THIS EXISTS
---------------
bcrypt makes this suite slow (2 hashes per registered account, ~0.3s each), so
a full run takes minutes. Polling it from the shell that owns the process sends
an interrupt and truncates the output, which is indistinguishable from a test
hang - a mistake worth not repeating.

`subprocess.Popen` with DETACHED_PROCESS + a new process group detaches the
child from the controlling terminal, so the parent can exit immediately and the
run keeps going. The result is written to a JSON file for later inspection.

Usage:  python _run_detached.py <output.txt> <pytest args...>
"""
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))

DETACHED = 0x00000008 | 0x00000200  # DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    out_path = os.path.join(HERE, sys.argv[1])
    result_path = out_path + ".result.json"
    target = sys.argv[2]
    extra = sys.argv[3:]

    # A file ending in .py that is NOT a test module is run as a plain script
    # (e.g. the E2E drivers). Everything else goes through pytest, because
    # pytest needs to own collection and fixtures for tests.
    is_script = target.endswith(".py") and not os.path.basename(
        target).startswith("test_")
    if is_script:
        command = [sys.executable, os.path.join(HERE, target)] + extra
    else:
        command = [sys.executable, "-m", "pytest", target] + extra

    started = time.time()
    # The output file is opened INSIDE the child and handed to the child as its
    # own stdout. Relying on the parent's handle being inherited (with
    # DETACHED_PROCESS + close_fds) left the file empty, which made a real
    # result indistinguishable from no run at all.
    wrapper = (
        "import json,subprocess,sys,time\n"
        "t=time.time()\n"
        "f=open(%r,'w',encoding='utf-8',errors='replace')\n"
        "c=subprocess.call(%r,stdout=f,stderr=subprocess.STDOUT)\n"
        "f.flush();f.close()\n"
        "json.dump({'code':c,'seconds':round(time.time()-t,1),'args':%r},"
        "open(%r,'w'))\n" % (out_path, command, [target] + extra, result_path)
    )
    devnull = open(os.devnull, "w")
    subprocess.Popen(
        [sys.executable, "-c", wrapper],
        cwd=HERE, stdout=devnull, stderr=subprocess.STDOUT,
        creationflags=DETACHED, close_fds=True,
    )
    print("launched: %s" % " ".join(command))
    print("output:   %s" % out_path)
    print("result:   %s" % result_path)
    print("elapsed at launch: %.1fs" % (time.time() - started))
    return 0


if __name__ == "__main__":
    sys.exit(main())
