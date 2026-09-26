"""Launch an arbitrary command DETACHED and report its exit code as JSON.

WHY
---
The E2E runs that matter here (Godot headless, the Python E2E drivers) take
minutes and make NETWORK calls part-way through. Polling them from the shell
that owns the process sends an interrupt, and a half-finished run looks
identical to a failing one - an HTTP request that simply never completed
reports `status: 0`, not an error.

So the child is detached into its own process group, and it writes its own
output and a JSON result file. Polling only ever reads those files.

Usage:
    python _run_cmd.py <outfile> <program> [args...]

Result file: <outfile>.result.json  -> {"code": n, "seconds": f}
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
    command = sys.argv[2:]

    started = time.time()
    # The output file is opened INSIDE the child and handed to it as its own
    # stdout; relying on the parent's handle surviving DETACHED_PROCESS leaves
    # the file empty, which is indistinguishable from "never ran".
    wrapper = (
        "import json,subprocess,sys,time\n"
        "t=time.time()\n"
        "f=open(%r,'w',encoding='utf-8',errors='replace')\n"
        "c=subprocess.call(%r,stdout=f,stderr=subprocess.STDOUT)\n"
        "f.flush();f.close()\n"
        "json.dump({'code':c,'seconds':round(time.time()-t,1),'cmd':%r},"
        "open(%r,'w'))\n" % (out_path, command, command, result_path)
    )
    devnull = open(os.devnull, "w")
    subprocess.Popen(
        [sys.executable, "-c", wrapper],
        cwd=os.path.dirname(HERE), stdout=devnull, stderr=subprocess.STDOUT,
        creationflags=DETACHED, close_fds=True,
    )
    print("launched: %s" % " ".join(command))
    print("output:   %s" % out_path)
    print("result:   %s" % result_path)
    print("elapsed at launch: %.1fs" % (time.time() - started))
    return 0


if __name__ == "__main__":
    sys.exit(main())
