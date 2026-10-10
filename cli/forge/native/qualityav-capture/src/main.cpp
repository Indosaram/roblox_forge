// qualityav-capture: first-party native background capture helper.
//
//   qualityav-capture.exe --request <absolute request file>
//
// stdin:  one token per line ("stop", "status", "quit")
// stdout: newline-delimited JSON events (accepted, started, status, finalized,
//         stopped, error)
// The request file is key=value text written by cli/forge/lib/qualityav-capture.mjs.
#include <objbase.h>

#include <cstdio>
#include <string>

#include "json_line.h"
#include "session.h"

namespace {

void EmitLine(const std::string& json) {
  if (json.empty()) return;
  std::fputs(json.c_str(), stdout);
  std::fputc('\n', stdout);
  std::fflush(stdout);
}

void EmitError(const std::string& requestId, const std::string& code,
               const std::string& detail) {
  qualityav::JsonObject event;
  event.Str("type", "error");
  event.Str("requestId", requestId);
  event.Str("code", code);
  if (!detail.empty()) event.Str("detail", detail);
  EmitLine(event.Build());
}

}  // namespace

int wmain(int argc, wchar_t** argv) {
  std::wstring requestPath;
  for (int index = 1; index < argc; index++) {
    const std::wstring arg = argv[index];
    if (arg == L"--request" && index + 1 < argc) {
      requestPath = argv[++index];
    } else if (arg.rfind(L"--request=", 0) == 0) {
      requestPath = arg.substr(10);
    } else if (arg == L"--help" || arg == L"-h") {
      std::fputs(
          "qualityav-capture --request <path>\n"
          "  stdin : stop | status | quit\n"
          "  stdout: newline-delimited JSON events\n",
          stdout);
      return 0;
    } else {
      EmitError("", "ARGUMENT_INVALID", qualityav::WideToUtf8(arg));
      return 64;
    }
  }
  if (requestPath.empty()) {
    EmitError("", "REQUEST_PATH_REQUIRED", "");
    return 64;
  }

  qualityav::CaptureRequest request;
  if (!qualityav::ParseRequestFile(requestPath, &request)) {
    EmitError(request.requestId.empty() ? std::string() : request.requestId, "REQUEST_INVALID",
              request.error);
    return 65;
  }

  const HRESULT apartment = ::CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  const bool apartmentReady = SUCCEEDED(apartment);
  // The result is recorded, not just used for the matching CoUninitialize: a handler that activated
  // from an apartment this call did not establish is a different situation from one that did, and the
  // probe reports which it was.
  qualityav::RecordApartmentInitResult(apartment);

  int code = 0;
  {
    qualityav::Session session;
    HRESULT hr = session.Start(request, &EmitLine);
    if (FAILED(hr)) {
      code = 66;
    } else {
      session.RunInputLoop();
      // "quit" means the caller is walking away without claiming an original:
      // the container is abandoned rather than finalized and reported.
      if (session.lastReason() == "quit-requested") {
        session.Abort("quit-requested");
        code = 0;
      } else if (FAILED(session.Finish(""))) {
        code = session.exitCode() != 0 ? session.exitCode() : 67;
      } else {
        code = session.exitCode();
      }
    }
  }

  if (apartmentReady) ::CoUninitialize();
  return code;
}
