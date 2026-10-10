// A capture source that will not stop cannot be torn down in-process. The Windows.Graphics.Capture
// frame pool invokes its FrameArrived handler with a raw pointer to the capture's Impl, and the audio
// loop runs on a std::thread whose object IS the Impl, so freeing either Impl - or the D3D and WASAPI
// objects it owns - while that worker is still inside it is a use-after-free. Detaching the worker is
// no better: it abandons a live thread that keeps dereferencing the destroyed owner.
//
// Both Stop paths therefore report this distinct HRESULT instead of forcing a teardown, and the
// session answers it by fail-closing the isolated helper process (Session::ExitUnstoppable), which is
// the one action that cannot leave a live worker pointing at freed memory.
#pragma once

#include <cstdio>
#include <windows.h>

namespace qualityav {

constexpr HRESULT kCaptureStopTimedOut = HRESULT_FROM_WIN32(ERROR_TIMEOUT);

// The one safe action when a capture worker will not stop. A destructor that reached this point has a
// live worker still inside the objects it owns, so it must not free them; the helper is an isolated
// child process whose exit the supervisor already observes, so ending the process is contained. Used by
// the capture destructors, which can be reached from start-failure paths that never call Finish.
[[noreturn]] inline void FailClosedProcess(const char* stage) {
  std::fprintf(stderr, "capture-stop-unresolved:%s\n", stage);
  std::fflush(stderr);
  ::ExitProcess(3);
}

}  // namespace qualityav
