#!/usr/bin/env python3
"""Remove every Docker resource owned by one harness directory, then the directory."""
import argparse
from pathlib import Path
import shutil
import subprocess

from harness import load


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, required=True)
    directory, state, _ = load(parser.parse_args().directory)
    name = state["name"]
    containers = subprocess.run(["docker", "ps", "-aq", "--filter", "name=^" + name + "-"],
                                text=True, capture_output=True, check=True).stdout.split()
    if containers:
        subprocess.run(["docker", "rm", "-f", "-v", *containers], check=True)
    subprocess.run(["docker", "network", "rm", name], stderr=subprocess.DEVNULL)
    shutil.rmtree(directory)
    print("Removed", name, "and", directory)


if __name__ == "__main__":
    main()
