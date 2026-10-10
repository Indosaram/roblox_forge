// WASAPI loopback audio capture with two admissible source routes:
//   1. owned-process-loopback - ActivateAudioInterfaceAsync on the process
//      loopback virtual device for one owned process tree (Windows build
//      20348+ / NTDDI_WIN10_FE), independent of any physical endpoint;
//   2. isolated-owned-session-loopback - shared-mode AUDCLNT_STREAMFLAGS_LOOPBACK
//      on one explicitly named rendering endpoint, together with the observed
//      audio-session producers so the caller can prove isolation.
// Both routes timestamp packets on the session QPC clock and hand interleavable
// PCM to the mux writer. Nothing here claims listening or approval.
#pragma once

#include <windows.h>

#include <atomic>
#include <string>
#include <vector>

#include "process_identity.h"
#include "qpc_clock.h"

namespace qualityav {

class MuxWriter;

enum class AudioRoute {
  ProcessLoopback,
  IsolatedEndpoint,
};

struct AudioConfig {
  AudioRoute route = AudioRoute::ProcessLoopback;
  DWORD targetPid = 0;                   // ProcessLoopback: root of the owned tree.
  bool includeTargetProcessTree = true;  // PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE.
  std::wstring endpointId;               // IsolatedEndpoint: IMMDevice id; empty selects the default render endpoint.
  UINT32 fallbackSampleRate = 48000;     // Used only when GetMixFormat is unavailable.
  UINT16 fallbackChannels = 2;
  UINT16 fallbackBits = 16;
};

// One observed audio session attached to the isolated endpoint. The caller
// cross-checks these process identities against the owned producer set; the
// helper never asserts ownership itself.
struct AudioSessionProbe {
  ProcessIdentity identity;
  bool active = false;
  bool systemSounds = false;
  bool identityObserved = false;
};

struct AudioReport {
  std::string activationKind;   // "process-loopback" | "endpoint-loopback"
  std::string endpointIdentity; // stable text identity of the capture source
  std::string endpointDeviceId; // resolved IMMDevice id (isolated endpoint route only)
  std::vector<ProcessIdentity> processTree;    // process route: live tree queried from the snapshot
  std::vector<AudioSessionProbe> endpointSessions;  // isolated route: observed producers
  unsigned int sampleRate = 0;
  unsigned int channels = 0;
  unsigned int bitsPerSample = 0;
  bool floatFormat = false;
  bool eventDriven = false;
  unsigned long long packets = 0;
  unsigned long long samples = 0;
  unsigned long long silentPackets = 0;
  // Raw engine values retained for provenance; PTS itself comes from QPC.
  long long firstDevicePosition = 0;
  long long lastDevicePosition = 0;
  long long firstPacketQpc = 0;
  long long lastPacketQpc = 0;
  long long firstPacketPts100ns = 0;
  long long lastPacketPts100ns = 0;
  std::string failure;  // empty when the route started and drained cleanly
  // The exact native operation that produced a prepare failure and its HRESULT, so a
  // caller can report which WASAPI step failed instead of a bare "audio prepare".
  std::string failureOperation;
  long failureHresult = 0;
};

// Records the CoInitializeEx result from the process entry point, so the probe can report whether the
// apartment this thread is in was requested successfully or was already established by something else.
void RecordApartmentInitResult(HRESULT hr);

// The recorded result above, for the probe's own report.
HRESULT ApartmentInitResult();

// Controlled, no-capture diagnostic for the process-loopback activation. It reports the apartment the
// calling thread is actually in, the window station and desktop it is attached to, the OS build, the
// process and session of both this helper and the target, which interfaces the completion handler
// answers, and the activation result split into the synchronous call and the completion report: the
// measurements that separate a session, apartment, agility or audio-service refusal. No video, no audio,
// no window, no capture.
struct AudioActivationProbe {
  long apartmentHresult = 0;    // CoGetApartmentType
  int apartmentType = -1;       // APTTYPE
  int apartmentQualifier = -1;  // APTTYPEQUALIFIER
  long apartmentInitHresult = 0;  // CoInitializeEx from the entry point
  std::string windowStation;      // interactive WinSta0 or a service station
  std::string desktop;
  unsigned long osBuild = 0;
  unsigned long processId = 0;
  unsigned long threadId = 0;
  unsigned long sessionId = 0;
  unsigned long targetPid = 0;
  unsigned long targetSessionId = 0;
  bool targetAlive = false;
  bool marshalerAggregated = false;
  bool marshalAnswered = false;
  bool agileObjectAnswered = false;
  std::string operation;
  long callHresult = 0;         // ActivateAudioInterfaceAsync return value
  long completionHresult = 0;   // GetActivateResult result, when the callback ran
  bool completionObserved = false;
  long activationHresult = 0;   // effective result
};

// Runs the probe above. Never opens a capture route and never starts a thread.
HRESULT ProbeProcessLoopbackActivation(DWORD targetPid, bool includeTree, AudioActivationProbe* out);

class AudioCapture {
 public:
  AudioCapture();
  ~AudioCapture();

  AudioCapture(const AudioCapture&) = delete;
  AudioCapture& operator=(const AudioCapture&) = delete;

  // Opens the route and negotiates the capture format without emitting a
  // single sample, so the mux can be opened with the real negotiated format.
  // On failure no thread is running and *outReport carries the failure code.
  HRESULT Prepare(const AudioConfig& config, const QpcClock* clock, AudioReport* outReport);

  // Starts the capture thread. Requires a successful Prepare and an opened mux.
  HRESULT Start(MuxWriter* mux, std::atomic<bool>* stopRequested, AudioReport* outReport);

  // Signals the capture thread to finish, joins it and releases the client.
  HRESULT Stop(AudioReport* outReport);

 private:
  struct Impl;
  Impl* impl_;
};

}  // namespace qualityav
