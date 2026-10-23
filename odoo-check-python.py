"""Check tracked Python sources without writing bytecode or importing addons."""

import os
from pathlib import Path
import subprocess
import sys
import traceback


def main():
    repo = Path(sys.argv[1]).resolve()
    result = subprocess.run(
        ["git", "-C", str(repo), "ls-files", "--cached", "--recurse-submodules", "-z"],
        check=True, stdout=subprocess.PIPE,
    )
    failed = False
    for raw_path in result.stdout.split(b"\0"):
        if not raw_path.endswith(b".py"):
            continue
        path = repo / os.fsdecode(raw_path)
        try:
            compile(path.read_bytes(), str(path), "exec", dont_inherit=True)
        except (SyntaxError, ValueError, OSError):
            traceback.print_exc()
            failed = True
    return int(failed)


if __name__ == "__main__":
    sys.exit(main())
