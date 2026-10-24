"""Run display lock checks on the host; no board access."""
import os
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
build = root / "build-host"
env = dict(os.environ)
if os.name == "nt":
    # MSBuild rejects environment blocks containing both PATH and Path.
    env = {key.upper(): value for key, value in env.items()}

def run(args):
    subprocess.run(args, env=env, check=True)

generator = ["-G", "Visual Studio 17 2022", "-A", "x64"] if os.name == "nt" else []
run(["cmake", "-S", str(root / "tests"), "-B", str(build), *generator])
run(["cmake", "--build", str(build), "--config", "Debug"])
run(["ctest", "--test-dir", str(build), "-C", "Debug", "--output-on-failure"])
