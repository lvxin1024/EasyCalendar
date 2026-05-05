"""Initialize git repository if not exists."""

import subprocess
import sys


def init_git():
    """Initialize git repository."""
    try:
        subprocess.run(["git", "init"], check=True, capture_output=True)
        print("Git repository initialized")
        return True
    except subprocess.CalledProcessError:
        print("Git already initialized or not available")
        return False
    except FileNotFoundError:
        print("Git not found")
        return False


if __name__ == "__main__":
    init_git()
