#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <algorithm>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // One instance only: a second one would find TDLib's database locked. It brings the open window forward
  // instead. The mutex lives until the process exits.
  ::CreateMutexW(nullptr, TRUE, L"Local\\uz.uzaro.app.single-instance");
  if (::GetLastError() == ERROR_ALREADY_EXISTS) {
    if (HWND existing = ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"UZARO")) {
      if (::IsIconic(existing)) ::ShowWindow(existing, SW_RESTORE);
      ::SetForegroundWindow(existing);
    }
    return EXIT_SUCCESS;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  // Centered on the primary screen's work area; Create() takes logical (96 dpi) units.
  RECT work;
  ::SystemParametersInfo(SPI_GETWORKAREA, 0, &work, 0);
  const double scale = ::GetDpiForSystem() / 96.0;
  const int work_width = static_cast<int>((work.right - work.left) / scale);
  const int work_height = static_cast<int>((work.bottom - work.top) / scale);
  const int width = std::min(1200, work_width * 9 / 10);
  const int height = std::min(800, work_height * 9 / 10);
  Win32Window::Point origin(static_cast<int>(work.left / scale) + (work_width - width) / 2,
                            static_cast<int>(work.top / scale) + (work_height - height) / 2);
  Win32Window::Size size(width, height);
  if (!window.Create(L"UZARO", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
