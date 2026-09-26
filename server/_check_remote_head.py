"""Report the commit GitHub has at the tip of `main`.

Confirms the push actually landed on the remote before concluding anything
about the deployment: a commit that never reached GitHub cannot possibly have
reached Render, and it is worth telling those two situations apart.

Usage:  python _check_remote_head.py [owner/repo] [branch]
"""
import json
import os
import sys
import urllib.request

DEFAULT_REPO = "enesbay48x/NovaGate-Server"


def main() -> int:
    repo = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_REPO
    branch = sys.argv[2] if len(sys.argv) > 2 else "main"
    url = "https://api.github.com/repos/%s/commits/%s" % (repo, branch)
    request = urllib.request.Request(
        url, headers={"User-Agent": "NovaGate-Deploy-Check"})
    with urllib.request.urlopen(request, timeout=45) as response:
        document = json.loads(response.read().decode("utf-8", "replace"))
    sha = document["sha"]
    message = document["commit"]["message"].splitlines()[0]
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       "_remote_head.txt")
    with open(out, "w", encoding="utf-8", errors="replace") as fh:
        fh.write("repo=%s\nbranch=%s\nsha=%s\nmessage=%s\n"
                 % (repo, branch, sha, message))
    print("remote %s/%s = %s  %s" % (repo, branch, sha[:12], message))
    return 0


if __name__ == "__main__":
    sys.exit(main())
