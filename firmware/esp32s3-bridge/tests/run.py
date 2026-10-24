"""Native C checks and production JS protocol roundtrip; no board access."""
import os
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
env = dict(os.environ)
if os.name == "nt":
    # Some IDE shells inherit both PATH and Path; MSBuild rejects that block.
    env = {key.upper(): value for key, value in env.items()}

def run(args):
    subprocess.run(args, cwd=root, env=env, check=True)

build = root / "build-host"
generator = ["-G", "Visual Studio 17 2022", "-A", "x64"] if os.name == "nt" else []
run(["cmake", "-S", str(root / "tests"), "-B", str(build), *generator])
run(["cmake", "--build", str(build), "--config", "Debug"])
run(["ctest", "--test-dir", str(build), "-C", "Debug", "--output-on-failure"])
exe = build / "Debug/bridge_tests.exe" if os.name == "nt" else build / "bridge_tests"
run(["node", str(root / "tests/protocol-roundtrip.mjs"), str(exe)])
