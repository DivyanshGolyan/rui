"""CI's steps for the live engine servers (tests/integration/live_engines.py).

    live_engine_step.py export ENGINE VALUE...
        Appends ENGINE to RUI_TEST_REQUIRE_ENGINES and each of ENGINE's
        variables, in ENGINES order, to $GITHUB_ENV.
    live_engine_step.py verify mysql
        Fails unless the record RUI_TEST_MYSQL_RECORD names exists and
        counts at least one PREPARE; prints the record either way.
"""

import os
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "integration"))
import live_engines


def main(argv, environ):
    if argv[:1] == ["export"] and len(argv) >= 2 and argv[1] in live_engines.ENGINES:
        with open(environ["GITHUB_ENV"], "a", encoding="utf-8") as out:
            out.writelines(line + "\n" for line in live_engines.export_lines(argv[1], argv[2:], environ))
        return 0
    if argv == ["verify", "mysql"]:
        failure = live_engines.verify_mysql(environ)
        return failure and f"error: {failure}"
    return __doc__


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:], os.environ))
