"""Launch the signed macOS executable and require a rasterized first frame."""

import argparse
import os
from pathlib import Path
import select
import subprocess
import sys
import time


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("executable", type=Path)
    args = parser.parse_args()
    try:
        process = subprocess.Popen(
            [str(args.executable.resolve())],
            env={**os.environ, "EASYCALENDAR_SMOKE_TEST": "1"},
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
    except OSError as error:
        print(f"Unable to launch macOS smoke test: {error}", file=sys.stderr)
        return 1

    output = bytearray()
    deadline = time.monotonic() + 30
    next_activation = 0.0
    try:
        while time.monotonic() < deadline:
            if process.poll() is not None:
                output.extend(process.stdout.read())
                print(
                    f"Application exited before its first frame (code {process.returncode}).",
                    file=sys.stderr,
                )
                break
            if time.monotonic() >= next_activation:
                # An occluded macOS window may never rasterize its first frame.
                # Retry while launching, always targeting only our child PID.
                try:
                    activation = subprocess.run(
                        [
                            "/usr/bin/osascript",
                            "-l",
                            "JavaScript",
                            "-e",
                            'ObjC.import("AppKit"); '
                            'const app = $.NSRunningApplication.'
                            f'runningApplicationWithProcessIdentifier({process.pid}); '
                            'if (!app.isNil()) app.activateWithOptions('
                            '$.NSApplicationActivateAllWindows | '
                            '$.NSApplicationActivateIgnoringOtherApps);',
                        ],
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.PIPE,
                        timeout=max(0.001, min(2, deadline - time.monotonic())),
                    )
                    output.extend(activation.stderr)
                except (OSError, subprocess.TimeoutExpired) as error:
                    output.extend(f"Window activation failed: {error}\n".encode())
                next_activation = time.monotonic() + 1
            ready, _, _ = select.select(
                [process.stdout], [], [], min(0.2, max(0, deadline - time.monotonic()))
            )
            if ready:
                chunk = os.read(process.stdout.fileno(), 65536)
                if not chunk:
                    print(
                        "Application closed its output before its first frame.",
                        file=sys.stderr,
                    )
                    break
                output.extend(chunk)
                if b"EASYCALENDAR_FIRST_FRAME_READY" in output.splitlines():
                    print("macOS smoke test passed: the first frame was rasterized.")
                    return 0
        else:
            print(
                "Application did not render its first frame within 30 seconds.",
                file=sys.stderr,
            )
        print(output.decode("utf-8", errors="replace"), file=sys.stderr, end="")
        return 1
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        process.stdout.close()


if __name__ == "__main__":
    raise SystemExit(main())
