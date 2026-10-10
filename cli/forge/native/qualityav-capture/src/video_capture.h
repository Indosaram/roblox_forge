// HWND-scoped Windows.Graphics.Capture video capture. The capture item is
// created from a concrete window handle through IGraphicsCaptureItemInterop
// (no picker, no foreground requirement in this code path), frames arrive on a
// free-threaded frame pool, and every written frame carries both the frame's
// SystemRelativeTime (WGC QPC-based timeline) and this session's QPC value so
// the parent can audit the mapping instead of trusting a filename.
#pragma once

#include <windows.h>

#include <atomic>
#include <string>

#include "process_identity.h"
#include "qpc_clock.h"

namespace qualityav {

class MuxWriter;

struct VideoConfig {
  HWND window = nullptr;
  unsigned int fpsNum = 30;
  unsigned int fpsDen = 1;
  unsigned long long maxFrames = 0;  // 0 = stop-driven only
  bool hideBorder = true;            // attempted; unsupported builds record it, never fail the capture
  bool includeCursor = true;
};

struct VideoReport {
  std::string sourceKind = "windows-graphics-capture";
  std::string hwnd;
  ProcessIdentity windowOwner;
  bool windowOwnerObserved = false;
  bool sessionStarted = false;
  bool itemClosedByOwner = false;
  bool borderControlApplied = false;
  bool cursorControlApplied = false;
  unsigned int width = 0;
  unsigned int height = 0;
  unsigned long long frames = 0;    // frames delivered by the capture item
  unsigned long long written = 0;   // frames handed to the mux writer
  unsigned long long skippedForCadence = 0;
  // WGC SystemRelativeTime is 100ns on its own QPC-based timeline; both the
  // raw values and the measured offset against this session clock are kept.
  long long firstSystemRelative100ns = 0;
  long long lastSystemRelative100ns = 0;
  long long firstArrivalQpc = 0;
  long long lastArrivalQpc = 0;
  long long firstPts100ns = 0;
  long long lastPts100ns = 0;
  long long systemRelativeMinusSession100ns = 0;
  std::string failure;
};

class VideoCapture {
 public:
  VideoCapture();
  ~VideoCapture();

  VideoCapture(const VideoCapture&) = delete;
  VideoCapture& operator=(const VideoCapture&) = delete;

  // Builds the D3D11 device, creates the HWND capture item, frame pool and
  // session object, and reports the captured size, WITHOUT starting capture so
  // the mux can be opened first with the real frame dimensions.
  HRESULT Prepare(const VideoConfig& config, const QpcClock* clock, VideoReport* outReport);

  // Starts the capture session. Requires a successful Prepare and an opened mux.
  HRESULT Start(MuxWriter* mux, std::atomic<bool>* stopRequested, VideoReport* outReport);

  // Stops the session, waits (bounded) for in-flight frame handlers, then
  // releases the pool and reports what was actually written.
  HRESULT Stop(VideoReport* outReport);

 private:
  struct Impl;
  Impl* impl_;
};

}  // namespace qualityav
