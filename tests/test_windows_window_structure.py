"""Static checks for the Windows desktop window adapter."""

from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
WINDOW_CPP = ROOT / "client" / "windows" / "runner" / "flutter_window.cpp"
WINDOW_H = ROOT / "client" / "windows" / "runner" / "flutter_window.h"


def test_windows_window_channel_and_native_controls_are_present():
    source = WINDOW_CPP.read_text(encoding="utf-8")
    header = WINDOW_H.read_text(encoding="utf-8")

    assert "io.easycalendar/window" in source
    assert "SetLayeredWindowAttributes" in source
    assert "HWND_TOPMOST" in source
    assert "WM_NCHITTEST" in source
    assert "RegisterHotKey" in source
    assert "WM_HOTKEY" in source
    assert "SetInteractionLocked" in header
