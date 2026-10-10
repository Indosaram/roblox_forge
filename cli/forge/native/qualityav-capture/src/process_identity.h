// Process creation identity: OS pid plus the process creation FILETIME.
// A bare pid is not an identity (pids are recycled), so every process this
// helper reports is keyed as "pid:<pid>:created:<100ns FILETIME>" and, where
// available, carries the resolved image path.
#pragma once

#include <windows.h>

#include <string>
#include <vector>

namespace qualityav {

struct ProcessIdentity {
  DWORD pid = 0;
  unsigned long long creationFileTime100ns = 0;
  std::wstring image;
  bool valid = false;

  std::string Key() const {
    if (!valid) return {};
    return "pid:" + std::to_string(pid) + ":created:" + std::to_string(creationFileTime100ns);
  }
};

// Opens the process with query-only rights; never terminates or modifies it.
bool ReadProcessIdentity(DWORD pid, ProcessIdentity* out);

// True when the process still exists with the same creation time; used to keep
// a captured source bound to the process that was admitted, not a recycled pid.
bool IdentityStillCurrent(const ProcessIdentity& identity);

// Enumerates rootPid and all of its descendants via a Toolhelp process snapshot.
// The result is sorted by pid and is the parent-side evidence for which process
// tree the OS process-loopback activation was asked to include.
std::vector<ProcessIdentity> EnumerateProcessTree(DWORD rootPid);

// Window handle helpers used for the video source association.
bool IdentifyWindowOwner(HWND window, ProcessIdentity* out);
std::string HwndKey(HWND window);

}  // namespace qualityav
