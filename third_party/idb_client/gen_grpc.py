"""Generates the idb client's gRPC modules from proto/idb.proto.

What facebook/idb's setup.py does when the client is pip-installed: protoc
with grpclib's plugin, then the import fix-up that lets idb_grpc.py find
idb_pb2.py inside the idb.grpc package.

Usage: gen_grpc.py <path/to/idb.proto> <output dir>
"""

import os
import stat
import sys
import tempfile

from grpc_tools import protoc


def main() -> int:
    proto, out_dir = sys.argv[1], sys.argv[2]
    os.makedirs(out_dir, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        # protoc runs --python_grpc_out through an executable named
        # protoc-gen-python_grpc; make one that runs grpclib's plugin with this
        # interpreter and this binary's import path. grpclib.plugin.main has no
        # __main__ guard (it is a console-script entry point), so call main().
        plugin = os.path.join(tmp, "protoc-gen-python_grpc")
        with open(plugin, "w") as f:
            f.write(
                "#!/bin/sh\n"
                f"PYTHONPATH={os.pathsep.join(sys.path)!r} "
                f"exec {sys.executable!r} -c "
                "'from grpclib.plugin.main import main; main()'\n"
            )
        os.chmod(plugin, os.stat(plugin).st_mode | stat.S_IEXEC)
        status = protoc.main(
            [
                "grpc_tools.protoc",
                f"--proto_path={os.path.dirname(proto)}",
                f"--python_out={out_dir}",
                f"--python_grpc_out={out_dir}",
                f"--plugin=protoc-gen-python_grpc={plugin}",
                proto,
            ]
        )
    if status != 0:
        return status
    grpc_module = os.path.join(out_dir, "idb_grpc.py")
    with open(grpc_module) as f:
        source = f.read()
    with open(grpc_module, "w") as f:
        f.write(source.replace("import idb_pb2", "import idb.grpc.idb_pb2 as idb_pb2"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
