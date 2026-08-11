#include "flutter_window.h"

#include <algorithm>
#include <cmath>
#include <optional>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  window_channel_ = std::make_unique<WindowChannel>(
      flutter_controller_->engine()->messenger(), "io.easycalendar/window",
      &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        const auto* arguments = std::get_if<flutter::EncodableMap>(
            call.arguments());
        auto read_bool = [&](const char* key) -> std::optional<bool> {
          if (arguments == nullptr) return std::nullopt;
          const auto found = arguments->find(flutter::EncodableValue(key));
          if (found == arguments->end()) return std::nullopt;
          const auto* value = std::get_if<bool>(&found->second);
          return value == nullptr ? std::nullopt : std::optional<bool>(*value);
        };
        auto read_double = [&](const char* key) -> std::optional<double> {
          if (arguments == nullptr) return std::nullopt;
          const auto found = arguments->find(flutter::EncodableValue(key));
          if (found == arguments->end()) return std::nullopt;
          if (const auto* value = std::get_if<double>(&found->second)) {
            return *value;
          }
          if (const auto* value = std::get_if<int32_t>(&found->second)) {
            return static_cast<double>(*value);
          }
          if (const auto* value = std::get_if<int64_t>(&found->second)) {
            return static_cast<double>(*value);
          }
          return std::nullopt;
        };

        if (call.method_name() == "setOpacity") {
          const auto value = read_double("opacity");
          if (!value.has_value()) {
            result->Error("invalid_opacity", "opacity must be a number");
            return;
          }
          SetOpacity(*value);
          result->Success();
          return;
        }
        if (call.method_name() == "setAlwaysOnTop") {
          const auto value = read_bool("value");
          if (!value.has_value()) {
            result->Error("invalid_topmost", "value must be a boolean");
            return;
          }
          SetAlwaysOnTop(*value);
          result->Success();
          return;
        }
        if (call.method_name() == "setInteractionLocked") {
          const auto value = read_bool("value");
          if (!value.has_value()) {
            result->Error("invalid_click_through", "value must be a boolean");
            return;
          }
          SetInteractionLocked(*value, false);
          result->Success();
          return;
        }
        result->NotImplemented();
      });
  RegisterHotKey(GetHandle(), kUnlockHotKeyId, MOD_CONTROL | MOD_ALT, 'L');
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  UnregisterHotKey(GetHandle(), kUnlockHotKeyId);
  if (window_channel_) {
    window_channel_->SetMethodCallHandler(nullptr);
  }
  window_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (interaction_locked_ && message == WM_NCHITTEST) {
    return HTTRANSPARENT;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_HOTKEY:
      if (wparam == kUnlockHotKeyId) {
        SetInteractionLocked(false, true);
        return 0;
      }
      break;
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

void FlutterWindow::SetOpacity(double value) {
  const auto clamped = std::clamp(value, 0.2, 1.0);
  const auto extended_style = GetWindowLong(GetHandle(), GWL_EXSTYLE);
  SetWindowLong(GetHandle(), GWL_EXSTYLE, extended_style | WS_EX_LAYERED);
  SetLayeredWindowAttributes(
      GetHandle(), 0, static_cast<BYTE>(std::lround(clamped * 255)), LWA_ALPHA);
}

void FlutterWindow::SetAlwaysOnTop(bool value) {
  SetWindowPos(GetHandle(), value ? HWND_TOPMOST : HWND_NOTOPMOST, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
}

void FlutterWindow::SetInteractionLocked(bool value, bool notify_flutter) {
  interaction_locked_ = value;
  auto extended_style = GetWindowLong(GetHandle(), GWL_EXSTYLE);
  if (value) {
    extended_style |= WS_EX_LAYERED | WS_EX_TRANSPARENT;
  } else {
    extended_style &= ~WS_EX_TRANSPARENT;
  }
  SetWindowLong(GetHandle(), GWL_EXSTYLE, extended_style);
  SetWindowPos(GetHandle(), nullptr, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_FRAMECHANGED);
  if (notify_flutter && window_channel_) {
    window_channel_->InvokeMethod(
        "windowInteractionUnlocked",
        std::make_unique<flutter::EncodableValue>());
  }
}
