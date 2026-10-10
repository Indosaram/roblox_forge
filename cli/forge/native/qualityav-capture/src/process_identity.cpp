#include "process_identity.h"

#include <tlhelp32.h>

#include <algorithm>
#include <unordered_set>

namespace qualityav {
namespace {

std::wstring QueryImagePath(HANDLE process) {
  std::vector<wchar_t> buffer(32768);
  DWORD size = static_cast<DWORD>(buffer.size());
  if (!::QueryFullProcessImageNameW(process, 0, buffer.data(), &size)) return {};
  return std::wstring(buffer.data(), size);
}

}  // namespace

bool ReadProcessIdentity(DWORD pid, ProcessIdentity* out) {
  if (!out || pid == 0) return false;
  *out = ProcessIdentity{};
  HANDLE process = ::OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (!process) return false;
  FILETIME creation{}, exitTime{}, kernel{}, user{};
  const BOOL timesOk = ::GetProcessTimes(process, &creation, &exitTime, &kernel, &user);
  if (timesOk) {
    ULARGE_INTEGER value{};
    value.LowPart = creation.dwLowDateTime;
    value.HighPart = creation.dwHighDateTime;
    out->pid = pid;
    out->creationFileTime100ns = value.QuadPart;
    out->image = QueryImagePath(process);
    out->valid = true;
  }
  ::CloseHandle(process);
  return timesOk && out->valid;
}

bool IdentityStillCurrent(const ProcessIdentity& identity) {
  if (!identity.valid) return false;
  ProcessIdentity current;
  if (!ReadProcessIdentity(identity.pid, &current)) return false;
  return current.creationFileTime100ns == identity.creationFileTime100ns;
}

std::vector<ProcessIdentity> EnumerateProcessTree(DWORD rootPid) {
  std::vector<ProcessIdentity> out;
  if (rootPid == 0) return out;
  HANDLE snapshot = ::CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if (snapshot == INVALID_HANDLE_VALUE) return out;

  struct Entry {
    DWORD pid;
    DWORD parent;
  };
  std::vector<Entry> entries;
  PROCESSENTRY32W row{};
  row.dwSize = sizeof(row);
  if (::Process32FirstW(snapshot, &row)) {
    do {
      entries.push_back({row.th32ProcessID, row.th32ParentProcessID});
    } while (::Process32NextW(snapshot, &row));
  }
  ::CloseHandle(snapshot);

  // Breadth-first over the parent map: the reported tree is the live process
  // set the OS was asked to include in the loopback activation.
  std::unordered_set<DWORD> visited;
  std::vector<DWORD> pending{rootPid};
  std::vector<DWORD> tree;
  while (!pending.empty()) {
    const DWORD pid = pending.front();
    pending.erase(pending.begin());
    if (!visited.insert(pid).second) continue;
    tree.push_back(pid);
    for (const Entry& entry : entries) {
      if (entry.parent == pid && entry.pid != 0) pending.push_back(entry.pid);
    }
  }
  std::sort(tree.begin(), tree.end());
  for (const DWORD pid : tree) {
    ProcessIdentity identity;
    // A process that exited between snapshot and query is not reported, so the
    // receipt never claims a creation identity that was not observed.
    if (ReadProcessIdentity(pid, &identity)) out.push_back(identity);
  }
  return out;
}

bool IdentifyWindowOwner(HWND window, ProcessIdentity* out) {
  if (!window || !out) return false;
  DWORD pid = 0;
  ::GetWindowThreadProcessId(window, &pid);
  return pid != 0 && ReadProcessIdentity(pid, out);
}

std::string HwndKey(HWND window) {
  char buffer[32];
  std::snprintf(buffer, sizeof(buffer), "0x%016llx",
                static_cast<unsigned long long>(reinterpret_cast<ULONG_PTR>(window)));
  return std::string(buffer);
}

}  // namespace qualityav
