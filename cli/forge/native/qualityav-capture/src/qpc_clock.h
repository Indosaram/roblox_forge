// One monotonic QueryPerformanceCounter clock for the whole capture session.
// Video PTS, audio PTS, event timestamps and the parent-side clock anchors are
// all expressed against this single frequency so the mapping is auditable.
#pragma once

#include <windows.h>

#include <string>

namespace qualityav {

struct QpcClock {
  LARGE_INTEGER frequency{};
  LARGE_INTEGER start{};

  static bool Read(QpcClock* out) {
    if (!out) return false;
    if (!::QueryPerformanceFrequency(&out->frequency) || out->frequency.QuadPart <= 0) return false;
    if (!::QueryPerformanceCounter(&out->start)) return false;
    return true;
  }

  long long Now() const {
    LARGE_INTEGER value{};
    ::QueryPerformanceCounter(&value);
    return value.QuadPart;
  }

  long long TicksSinceStart() const { return Now() - start.QuadPart; }

  // Converts QPC ticks to 100-nanosecond units on the session timeline.
  long long TicksTo100ns(long long ticks) const {
    if (frequency.QuadPart <= 0) return 0;
    return (ticks * 10000000LL) / frequency.QuadPart;
  }

  long long SinceStart100ns() const { return TicksTo100ns(TicksSinceStart()); }

  std::string FrequencyKey() const { return std::to_string(frequency.QuadPart); }
  std::string StartKey() const { return std::to_string(start.QuadPart); }
};

}  // namespace qualityav
