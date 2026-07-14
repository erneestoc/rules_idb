# Entry point wrapper for the vendored fb-idb client.
import sys

from idb.cli.main import main

if __name__ == "__main__":
    sys.exit(main())
