// Session orchestration for the native capture helper: request parsing,
// start/stop protocol on stdout (newline-delimited JSON), a durable state
// sidecar for reconciliation, and the single QPC clock shared by both tracks.
//
// Command surface (stdin, one token per line):
//   stop     - request a clean stop and finalize the original container
//   status   - emit the current phase and counters
//   quit     - stop without finalizing (used only on failure paths)
// Request file (key=value lines) is written by the wrapper; see
// buildCaptureRequest() in cli/forge/lib/qualityav-capture.mjs.
#pragma once

#include <windows.h>

#include <atomic>
#include <functional>
#include <string>
#include <thread>
#include <vector>

#include "audio_capture.h"
#include "mux_writer.h"
#include "qpc_clock.h"
#include "video_capture.h"

namespace qualityav {

struct CaptureRequest {
  int schemaVersion = 0;
  std::string requestId;
  std::string mode;
  std::wstring outputPath;
  std::wstring statePath;
  HWND window = nullptr;
  DWORD targetPid = 0;
  bool includeTree = true;
  std::wstring endpointId;
  std::vector<std::string> ownedProcessKeys;
  unsigned int fpsNum = 30;
  unsigned int fpsDen = 1;
  unsigned long long maxFrames = 0;
  unsigned long long maxDurationMs = 0;
  std::string ownershipToken;
  bool valid = false;
  std::string error;
};

// Parses the key=value request file. Returns false and fills out->error on any
// malformed or missing required field; nothing is partially accepted.
bool ParseRequestFile(const std::wstring& path, CaptureRequest* out);

class Session {
 public:
  using Emit = std::function<void(const std::string&)>;

  Session();
  ~Session();

  Session(const Session&) = delete;
  Session& operator=(const Session&) = delete;

  // Prepares both sources, opens the mux with the negotiated formats, starts
  // capture, emits "started" and writes the running state sidecar.
  HRESULT Start(const CaptureRequest& request, Emit emit);

  // Reads stdin commands until stop/quit, emitting "progress"/"status".
  HRESULT RunInputLoop();

  // Stops both sources, finalizes the container, emits "finalized" and
  // "stopped", and rewrites the sidecar with the durable result.
  HRESULT Finish(const std::string& reason);

  // Stops both sources and abandons the container WITHOUT finalizing it, so a
  // partial file is never reported as an original.
  HRESULT Abort(const std::string& reason);

  const std::string& lastReason() const { return lastReason_; }

  int exitCode() const { return exitCode_; }

 private:
  // Ends the process when a capture worker would not stop. Nothing owned by this process may be freed
  // while that worker is still inside it, so the fail-closed action is to exit the isolated helper
  // process - which the supervisor already observes - after recording why. Never returns.
  [[noreturn]] void ExitUnstoppable(const char* stage, HRESULT hr);

  void EmitEvent(const std::string& json);
  void WriteState(const char* phase, const std::string& extraJson);
  std::string SourceJson() const;
  std::string ClockJson() const;
  std::string TracksJson() const;
  std::string PtsJson() const;

  CaptureRequest request_;
  Emit emit_;
  QpcClock clock_{};
  std::atomic<bool> stopRequested_{false};

  MuxWriter mux_;
  AudioCapture audio_;
  VideoCapture video_;
  AudioReport audioReport_{};
  VideoReport videoReport_{};
  ProcessIdentity recorder_{};
  ProcessIdentity windowOwner_{};
  std::string targetIdentity_;

  bool started_ = false;
  bool finalized_ = false;
  std::string lastReason_ = "unspecified";
  int exitCode_ = 0;
  std::thread progressThread_;
};

}  // namespace qualityav
