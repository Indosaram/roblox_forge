#include "session.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <sstream>

#include "json_line.h"
#include "capture_stop.h"

namespace qualityav {
namespace {

std::string Trim(const std::string& value) {
  size_t begin = 0;
  size_t end = value.size();
  while (begin < end && (value[begin] == ' ' || value[begin] == '\t' || value[begin] == '\r')) begin++;
  while (end > begin && (value[end - 1] == ' ' || value[end - 1] == '\t' || value[end - 1] == '\r')) end--;
  return value.substr(begin, end - begin);
}

bool ParseU64(const std::string& textValue, unsigned long long* out) {
  if (!out || textValue.empty()) return false;
  char* end = nullptr;
  const unsigned long long value = std::strtoull(textValue.c_str(), &end, 10);
  if (!end || *end != '\0') return false;
  *out = value;
  return true;
}

bool ParseHwnd(const std::string& textValue, HWND* out) {
  if (!out || textValue.empty()) return false;
  char* end = nullptr;
  const unsigned long long value = std::strtoull(textValue.c_str(), &end, 16);
  if (!end || *end != '\0') return false;
  *out = reinterpret_cast<HWND>(static_cast<ULONG_PTR>(value));
  return *out != nullptr;
}

std::string HresultHex(HRESULT value) {
  char buffer[16];
  std::snprintf(buffer, sizeof(buffer), "0x%08lX", static_cast<unsigned long>(value));
  return std::string(buffer);
}

std::string WstringFromWide(const std::wstring& value) { return WideToUtf8(value); }

}  // namespace

bool ParseRequestFile(const std::wstring& path, CaptureRequest* out) {
  if (!out) return false;
  *out = CaptureRequest{};
  HANDLE file = ::CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING,
                              FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    out->error = "request-open-failed";
    return false;
  }
  LARGE_INTEGER size{};
  if (!::GetFileSizeEx(file, &size) || size.QuadPart > 1024 * 1024) {
    ::CloseHandle(file);
    out->error = "request-size-invalid";
    return false;
  }
  std::string content(static_cast<size_t>(size.QuadPart), '\0');
  DWORD read = 0;
  const BOOL ok = size.QuadPart == 0 ||
                  ::ReadFile(file, content.data(), static_cast<DWORD>(content.size()), &read, nullptr);
  ::CloseHandle(file);
  if (!ok) {
    out->error = "request-read-failed";
    return false;
  }
  content.resize(read);

  std::vector<std::string> owned;
  std::istringstream stream(content);
  std::string lineValue;
  while (std::getline(stream, lineValue)) {
    const std::string line = Trim(lineValue);
    if (line.empty() || line[0] == '#') continue;
    const size_t split = line.find('=');
    if (split == std::string::npos) {
      out->error = "request-line-malformed";
      return false;
    }
    const std::string key = Trim(line.substr(0, split));
    const std::string value = line.substr(split + 1);
    if (key == "schemaVersion") {
      unsigned long long parsed = 0;
      if (!ParseU64(value, &parsed) || parsed != 1) {
        out->error = "schema-version-unsupported";
        return false;
      }
      out->schemaVersion = static_cast<int>(parsed);
    } else if (key == "requestId" || key == "ownershipToken") {
      if (value.empty()) {
        out->error = "request-id-empty";
        return false;
      }
      if (key == "requestId") out->requestId = value;
      if (key == "ownershipToken") out->ownershipToken = value;
    } else if (key == "mode") {
      out->mode = value;
    } else if (key == "outputPath") {
      out->outputPath.assign(value.begin(), value.end());
    } else if (key == "statePath") {
      out->statePath.assign(value.begin(), value.end());
    } else if (key == "hwnd") {
      if (!ParseHwnd(value, &out->window)) {
        out->error = "hwnd-invalid";
        return false;
      }
    } else if (key == "targetPid") {
      unsigned long long parsed = 0;
      if (!ParseU64(value, &parsed)) {
        out->error = "target-pid-invalid";
        return false;
      }
      out->targetPid = static_cast<DWORD>(parsed);
    } else if (key == "includeTree") {
      out->includeTree = value == "true";
    } else if (key == "endpointId") {
      out->endpointId.assign(value.begin(), value.end());
    } else if (key == "owned") {
      owned.push_back(value);
    } else if (key == "fps") {
      unsigned long long parsed = 0;
      if (!ParseU64(value, &parsed) || parsed == 0 || parsed > 120) {
        out->error = "fps-invalid";
        return false;
      }
      out->fpsNum = static_cast<unsigned int>(parsed);
      out->fpsDen = 1;
    } else if (key == "maxFrames") {
      unsigned long long parsed = 0;
      if (!ParseU64(value, &parsed)) {
        out->error = "max-frames-invalid";
        return false;
      }
      out->maxFrames = parsed;
    } else if (key == "maxDurationMs") {
      unsigned long long parsed = 0;
      if (!ParseU64(value, &parsed)) {
        out->error = "max-duration-invalid";
        return false;
      }
      out->maxDurationMs = parsed;
    }
    // Unknown keys are ignored so a newer wrapper stays forward compatible.
  }
  out->ownedProcessKeys = owned;

  if (out->schemaVersion != 1) {
    out->error = "schema-version-missing";
    return false;
  }
  if (out->requestId.empty() || out->requestId != out->ownershipToken) {
    out->error = "request-token-mismatch";
    return false;
  }
  const bool probe = out->mode == "owned-process-loopback-probe";
  if (!probe && out->mode != "owned-process-loopback" && out->mode != "isolated-owned-session-loopback") {
    out->error = "mode-invalid";
    return false;
  }
  // The no-capture probe opens no route and writes no state, so it needs only the process it asks
  // about: no window, no output path and no state file are meaningful for it.
  if (probe) {
    if (out->targetPid == 0) {
      out->error = "target-pid-missing";
      return false;
    }
    out->valid = true;
    return true;
  }
  if (out->outputPath.empty() || out->statePath.empty()) {
    out->error = "paths-missing";
    return false;
  }
  if (!out->window) {
    out->error = "hwnd-missing";
    return false;
  }
  if (out->mode == "owned-process-loopback" && out->targetPid == 0) {
    out->error = "target-pid-missing";
    return false;
  }
  out->valid = true;
  return true;
}

Session::Session() = default;

Session::~Session() {
  stopRequested_.store(true);
  if (progressThread_.joinable()) progressThread_.join();
}

void Session::EmitEvent(const std::string& json) {
  if (json.empty()) return;
  std::string line = json;
  line.push_back('\n');
  std::fwrite(line.data(), 1, line.size(), stdout);
  std::fflush(stdout);
}

void Session::ExitUnstoppable(const char* stage, HRESULT hr) {
  JsonObject event;
  event.Str("type", "error");
  event.Str("requestId", request_.requestId);
  event.Str("code", "CAPTURE_STOP_UNRESOLVED");
  event.Str("operation", stage);
  event.Str("detail", HresultHex(hr));
  EmitEvent(event.Build());
  WriteState("failed", std::string("\"error\":\"capture-stop-unresolved:") + stage + ":" +
                            HresultHex(hr) + "\"");
  std::fflush(stdout);
  std::fflush(stderr);
  // No destructor may run: the worker that would not stop is still inside objects this process owns,
  // so freeing them - or letting std::thread's destructor see a joinable thread - would be a
  // use-after-free or a terminate. The helper is an isolated child process and the supervisor already
  // handles its exit, so ending it here cannot affect anything outside this process.
  ::ExitProcess(3);
}

std::string Session::SourceJson() const {
  JsonObject source;
  source.Str("recorderId", recorder_.Key());
  source.Str("hwnd", HwndKey(request_.window));
  JsonObject owner;
  owner.Str("identity", windowOwner_.Key());
  owner.Uint("pid", windowOwner_.pid);
  owner.Str("image", WideToUtf8(windowOwner_.image));
  source.Raw("windowOwner", owner.Build());
  source.Str("activationKind", audioReport_.activationKind);
  source.Str("audioEndpoint", audioReport_.endpointIdentity);
  source.Str("endpointId", audioReport_.endpointDeviceId);
  source.Int("targetPid", static_cast<long long>(request_.targetPid));
  source.Str("targetProcessIdentity", targetIdentity_);
  source.Str("videoSource",
             "windows-graphics-capture:hwnd=" + HwndKey(request_.window) + ":size=" +
                 std::to_string(videoReport_.width) + "x" + std::to_string(videoReport_.height));

  std::vector<std::string> tree;
  tree.reserve(audioReport_.processTree.size());
  for (const ProcessIdentity& identity : audioReport_.processTree) tree.push_back(identity.Key());
  source.Raw("processTree", JsonStringArray(tree));

  std::string sessions = "[";
  for (size_t index = 0; index < audioReport_.endpointSessions.size(); index++) {
    const AudioSessionProbe& probe = audioReport_.endpointSessions[index];
    if (index != 0) sessions += ',';
    JsonObject entry;
    entry.Str("identity", probe.identity.Key());
    entry.Bool("identityObserved", probe.identityObserved);
    entry.Bool("active", probe.active);
    entry.Bool("systemSounds", probe.systemSounds);
    sessions += entry.Build();
  }
  sessions += ']';
  source.Raw("endpointSessions", sessions);
  return source.Build();
}

std::string Session::ClockJson() const {
  JsonObject clock;
  clock.Uint("qpcFrequency", static_cast<unsigned long long>(clock_.frequency.QuadPart));
  clock.Uint("qpcStart", static_cast<unsigned long long>(clock_.start.QuadPart));
  clock.Int("qpcEnd", clock_.Now());
  clock.Int("firstVideoPts100ns", mux_.firstVideoPts100ns());
  clock.Int("lastVideoPts100ns", mux_.lastVideoPts100ns());
  clock.Int("firstAudioPts100ns", mux_.firstAudioPts100ns());
  clock.Int("lastAudioPts100ns", mux_.lastAudioPts100ns());
  clock.Int("firstSystemRelative100ns", videoReport_.firstSystemRelative100ns);
  clock.Int("lastSystemRelative100ns", videoReport_.lastSystemRelative100ns);
  clock.Int("systemRelativeMinusSession100ns", videoReport_.systemRelativeMinusSession100ns);
  return clock.Build();
}

std::string Session::TracksJson() const {
  JsonObject tracks;
  tracks.Uint("video", mux_.videoStreamIndex());
  tracks.Uint("audio", mux_.audioStreamIndex());
  return tracks.Build();
}

std::string Session::PtsJson() const {
  JsonObject video;
  video.Int("first100ns", mux_.firstVideoPts100ns());
  video.Int("last100ns", mux_.lastVideoPts100ns());
  video.Uint("samples", mux_.videoSamples());
  JsonObject audio;
  audio.Int("first100ns", mux_.firstAudioPts100ns());
  audio.Int("last100ns", mux_.lastAudioPts100ns());
  audio.Uint("samples", mux_.audioSamples());
  JsonObject pts;
  pts.Raw("video", video.Build());
  pts.Raw("audio", audio.Build());
  return pts.Build();
}

void Session::WriteState(const char* phase, const std::string& extraJson) {
  if (request_.statePath.empty()) return;
  std::string body = "{\"schemaVersion\":1,\"requestId\":\"" + JsonEscape(request_.requestId) +
                     "\",\"ownershipToken\":\"" + JsonEscape(request_.ownershipToken) +
                     "\",\"phase\":\"" + JsonEscape(phase) + "\",\"pid\":" +
                     std::to_string(static_cast<unsigned long long>(::GetCurrentProcessId())) +
                     ",\"recorder\":\"" + JsonEscape(recorder_.Key()) + "\"";
  if (!extraJson.empty()) body += "," + extraJson;
  body += "}";

  const std::wstring tempPath = request_.statePath + L".tmp";
  HANDLE file = ::CreateFileW(tempPath.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                              FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return;
  DWORD written = 0;
  ::WriteFile(file, body.data(), static_cast<DWORD>(body.size()), &written, nullptr);
  ::FlushFileBuffers(file);
  ::CloseHandle(file);
  ::MoveFileExW(tempPath.c_str(), request_.statePath.c_str(), MOVEFILE_REPLACE_EXISTING);
}

HRESULT Session::Start(const CaptureRequest& request, Emit emit) {
  request_ = request;
  emit_ = std::move(emit);
  if (!request_.valid) {
    EmitEvent(JsonObject().Str("type", "error").Str("requestId", request_.requestId)
                  .Str("code", "REQUEST_INVALID").Str("detail", request_.error).Build());
    return E_INVALIDARG;
  }

  // The no-capture activation probe reports what the runtime actually is at the moment of activation:
  // the apartment this thread is really in, the helper's and the target's process/session/thread,
  // whether the completion handler answers IID_IMarshal, and the activation result. It opens no video
  // and no audio, so a refusal can be attributed from measurement instead of inferred from a code.
  if (request_.mode == "owned-process-loopback-probe") {
    AudioActivationProbe probe;
    const HRESULT probed =
        ProbeProcessLoopbackActivation(request_.targetPid, request_.includeTree, &probe);
    EmitEvent(JsonObject().Str("type", "probe").Str("requestId", request_.requestId)
                  .Str("apartmentHresult", HresultHex(probe.apartmentHresult))
                  .Int("apartmentType", probe.apartmentType)
                  .Int("apartmentQualifier", probe.apartmentQualifier)
                  .Str("apartmentInitHresult", HresultHex(probe.apartmentInitHresult))
                  .Str("windowStation", probe.windowStation)
                  .Str("desktop", probe.desktop)
                  .Uint("osBuild", probe.osBuild)
                  .Uint("processId", probe.processId)
                  .Uint("threadId", probe.threadId)
                  .Uint("sessionId", probe.sessionId)
                  .Uint("targetPid", probe.targetPid)
                  .Uint("targetSessionId", probe.targetSessionId)
                  .Bool("targetAlive", probe.targetAlive)
                  .Bool("marshalerAggregated", probe.marshalerAggregated)
                  .Bool("marshalAnswered", probe.marshalAnswered)
                  .Bool("agileObjectAnswered", probe.agileObjectAnswered)
                  .Str("operation", probe.operation)
                  .Str("callHresult", HresultHex(probe.callHresult))
                  .Str("completionHresult", HresultHex(probe.completionHresult))
                  .Bool("completionObserved", probe.completionObserved)
                  .Str("activationHresult", HresultHex(probe.activationHresult))
                  .Build());
    return probed;
  }

  if (!ReadProcessIdentity(::GetCurrentProcessId(), &recorder_) || !recorder_.valid) {
    EmitEvent(JsonObject().Str("type", "error").Str("requestId", request_.requestId)
                  .Str("code", "RECORDER_IDENTITY_UNAVAILABLE").Build());
    return E_ACCESSDENIED;
  }
  IdentifyWindowOwner(request_.window, &windowOwner_);
  ProcessIdentity targetIdentity;
  if (request_.targetPid != 0 && ReadProcessIdentity(request_.targetPid, &targetIdentity)) {
    targetIdentity_ = targetIdentity.Key();
  } else {
    EmitEvent(JsonObject().Str("type", "error").Str("requestId", request_.requestId)
                  .Str("code", "TARGET_PROCESS_UNPROVEN").Build());
    return E_FAIL;
  }
  if (!QpcClock::Read(&clock_)) {
    EmitEvent(JsonObject().Str("type", "error").Str("requestId", request_.requestId)
                  .Str("code", "QPC_UNAVAILABLE").Build());
    return E_FAIL;
  }
  EmitEvent(JsonObject().Str("type", "accepted").Str("requestId", request_.requestId)
                .Str("recorder", recorder_.Key()).Uint("pid", ::GetCurrentProcessId()).Build());
  WriteState("starting", "");

  // 1. Prepare video (gets real frame size, no frames flow yet).
  VideoConfig videoConfig;
  videoConfig.window = request_.window;
  videoConfig.fpsNum = request_.fpsNum;
  videoConfig.fpsDen = request_.fpsDen;
  videoConfig.maxFrames = request_.maxFrames;
  HRESULT hr = video_.Prepare(videoConfig, &clock_, &videoReport_);
  if (FAILED(hr)) {
    EmitEvent(JsonObject().Str("type", "error").Str("requestId", request_.requestId)
                  .Str("code", "VIDEO_PREPARE_FAILED").Str("detail", HresultHex(hr)).Build());
    WriteState("failed", std::string("\"error\":\"video-prepare-failed:" + HresultHex(hr) + "\""));
    return hr;
  }

  // 2. Prepare audio (discovers the negotiated PCM format, no samples flow yet).
  AudioConfig audioConfig;
  audioConfig.targetPid = request_.targetPid;
  audioConfig.includeTargetProcessTree = request_.includeTree;
  audioConfig.endpointId = request_.endpointId;
  audioConfig.route = request_.mode == "owned-process-loopback" ? AudioRoute::ProcessLoopback
                                                               : AudioRoute::IsolatedEndpoint;
  hr = audio_.Prepare(audioConfig, &clock_, &audioReport_);
  if (FAILED(hr)) {
    EmitEvent(JsonObject().Str("type", "error").Str("requestId", request_.requestId)
                  .Str("code", "AUDIO_PREPARE_FAILED")
                  .Str("operation", audioReport_.failureOperation)
                  .Str("detail", HresultHex(hr)).Build());
    WriteState("failed", std::string("\"error\":\"audio-prepare-failed:") +
                             (audioReport_.failureOperation.empty()
                                  ? std::string()
                                  : audioReport_.failureOperation + ":") +
                             HresultHex(hr) + "\"");
    return hr;
  }

  // 3. Open the container with the negotiated sizes and formats.
  VideoFormatSpec videoFormat;
  videoFormat.width = videoReport_.width;
  videoFormat.height = videoReport_.height;
  videoFormat.fpsNum = request_.fpsNum;
  videoFormat.fpsDen = request_.fpsDen;
  AudioFormatSpec audioFormat;
  audioFormat.sampleRate = audioReport_.sampleRate;
  audioFormat.channels = audioReport_.channels;
  audioFormat.bitsPerSample = audioReport_.bitsPerSample;
  audioFormat.isFloat = audioReport_.floatFormat;
  audioFormat.blockAlign = audioReport_.channels * audioReport_.bitsPerSample / 8;
  audioFormat.averageBytesPerSecond = audioFormat.sampleRate * audioFormat.blockAlign;
  hr = mux_.Open(request_.outputPath, videoFormat, audioFormat);
  if (FAILED(hr)) {
    // The mux names the exact negotiation step that failed and the formats it was offered, so the
    // blocker distinguishes an unsupported stream from an unsupported attribute instead of reporting a
    // bare media-type error.
    const MuxFailure& failure = mux_.failure();
    const std::string detail =
        (failure.operation.empty() ? std::string("unknown") : failure.operation) + ":" + HresultHex(hr) +
        ":video=" + std::to_string(failure.videoWidth) + "x" + std::to_string(failure.videoHeight) +
        "@" + std::to_string(failure.videoFpsNum) + "/" + std::to_string(failure.videoFpsDen) +
        ":audio=" + std::to_string(failure.audioSampleRate) + "Hz/" +
        std::to_string(failure.audioChannels) + "ch/" + std::to_string(failure.audioBitsPerSample) +
        "bit/align" + std::to_string(failure.audioBlockAlign);
    EmitEvent(JsonObject().Str("type", "error").Str("requestId", request_.requestId)
                  .Str("code", "MUX_OPEN_FAILED")
                  .Str("operation", failure.operation)
                  .Str("detail", detail)
                  .Build());
    WriteState("failed", std::string("\"error\":\"mux-open-failed:") + detail + "\"");
    return hr;
  }

  // 4. Start both tracks against the already-opened mux.
  hr = audio_.Start(&mux_, &stopRequested_, &audioReport_);
  if (SUCCEEDED(hr)) hr = video_.Start(&mux_, &stopRequested_, &videoReport_);
  if (FAILED(hr)) {
    stopRequested_.store(true);
    EmitEvent(JsonObject().Str("type", "error").Str("requestId", request_.requestId)
                  .Str("code", "CAPTURE_START_FAILED").Str("detail", HresultHex(hr)).Build());
    WriteState("failed", std::string("\"error\":\"capture-start-failed:" + HresultHex(hr) + "\""));
    return hr;
  }

  started_ = true;
  const long long startedMs = static_cast<long long>(::GetTickCount64());
  JsonObject event;
  event.Str("type", "started");
  event.Str("requestId", request_.requestId);
  event.Str("ack", "start");
  event.Str("recorder", recorder_.Key());
  event.Raw("source", SourceJson());
  event.Raw("clock", ClockJson());
  event.Int("hostStartMs", startedMs);
  EmitEvent(event.Build());
  WriteState("running", "\"source\":" + SourceJson() + ",\"clock\":" + ClockJson() +
                            ",\"tracks\":" + TracksJson());
  return S_OK;
}

HRESULT Session::RunInputLoop() {
  if (!started_) return HRESULT_FROM_WIN32(ERROR_INVALID_STATE);
  const ULONGLONG deadline =
      request_.maxDurationMs > 0 ? ::GetTickCount64() + request_.maxDurationMs : 0;
  std::string lineValue;
  while (!stopRequested_.load()) {
    if (deadline != 0 && ::GetTickCount64() >= deadline) {
      lastReason_ = "max-duration";
      stopRequested_.store(true);
      break;
    }
    if (!std::getline(std::cin, lineValue)) break;
    const std::string token = Trim(lineValue);
    if (token == "stop") {
      lastReason_ = "stop-requested";
      stopRequested_.store(true);
      break;
    }
    if (token == "quit") {
      lastReason_ = "quit-requested";
      stopRequested_.store(true);
      break;
    }
    if (token == "status") {
      JsonObject status;
      status.Str("type", "status");
      status.Str("requestId", request_.requestId);
      status.Str("phase", finalized_ ? "finalized" : "running");
      status.Uint("videoFrames", videoReport_.frames);
      status.Uint("videoWritten", mux_.videoSamples());
      status.Uint("audioPackets", audioReport_.packets);
      status.Uint("audioSamples", mux_.audioSamples());
      status.Int("qpcNow", clock_.Now());
      EmitEvent(status.Build());
    }
  }
  return S_OK;
}

HRESULT Session::Finish(const std::string& reason) {
  if (!started_) return HRESULT_FROM_WIN32(ERROR_INVALID_STATE);
  stopRequested_.store(true);
  lastReason_ = reason.empty() ? lastReason_ : reason;

  VideoReport videoFinal{};
  AudioReport audioFinal{};
  // Finalization is three sequential waits and each of them can block. Every stage is published
  // before it is entered, so a caller that has to kill this process still has the name of the stage
  // that never returned instead of an unattributable silence.
  auto stage = [this](const char* name) {
    JsonObject event;
    event.Str("type", "finalizing");
    event.Str("requestId", request_.requestId);
    event.Str("stage", name);
    EmitEvent(event.Build());
    WriteState("finalizing", std::string("\"stage\":\"") + name + "\"");
  };
  stage("video-stop");
  const HRESULT videoHr = video_.Stop(&videoFinal);
  videoReport_ = videoFinal;
  if (videoHr == kCaptureStopTimedOut) ExitUnstoppable("video-stop", videoHr);
  stage("audio-stop");
  const HRESULT audioHr = audio_.Stop(&audioFinal);
  audioReport_ = audioFinal;
  if (audioHr == kCaptureStopTimedOut) ExitUnstoppable("audio-stop", audioHr);

  OriginalFile original;
  stage("mux-finish");
  const HRESULT muxHr = mux_.Finish(&original);

  // The primary failure is the first stage that actually failed, reported with its own HRESULT. The
  // previous form reported MUX_FINALIZE_FAILED with HresultHex(muxHr) - i.e. 0x00000000 - whenever a
  // video or audio stage failed, which named the wrong operation and a bogus success code.
  const char* primaryOperation = nullptr;
  const char* primaryCode = nullptr;
  HRESULT primaryHr = S_OK;
  std::string primaryNative;
  if (FAILED(videoHr)) {
    primaryOperation = "video-stop";
    primaryCode = "VIDEO_STOP_FAILED";
    primaryHr = videoHr;
    primaryNative = videoReport_.failure;
  } else if (!videoReport_.failure.empty()) {
    // The stop itself succeeded; the video track recorded the precise failure (for example a frame
    // that could not be bridged or written), so that string is the primary evidence.
    primaryOperation = "video-stop";
    primaryCode = "VIDEO_CAPTURE_FAILED";
    primaryNative = videoReport_.failure;
  } else if (FAILED(audioHr)) {
    primaryOperation = "audio-stop";
    primaryCode = "AUDIO_STOP_FAILED";
    primaryHr = audioHr;
    primaryNative = audioReport_.failure;
  } else if (!audioReport_.failure.empty()) {
    primaryOperation = "audio-stop";
    primaryCode = "AUDIO_CAPTURE_FAILED";
    primaryNative = audioReport_.failure;
  } else if (FAILED(muxHr)) {
    primaryOperation = "mux-finish";
    primaryCode = "MUX_FINALIZE_FAILED";
    primaryHr = muxHr;
  }

  const bool ok = primaryOperation == nullptr;
  JsonObject event;
  event.Str("type", ok ? "finalized" : "error");
  event.Str("requestId", request_.requestId);
  if (ok) {
    event.Str("ack", "final");
    JsonObject file;
    file.Str("path", WstringFromWide(original.path));
    file.Uint("byteLength", original.byteLength);
    event.Raw("original", file.Build());
    event.Raw("tracks", TracksJson());
    event.Raw("pts", PtsJson());
    event.Raw("source", SourceJson());
    event.Raw("clock", ClockJson());
    event.Str("recorder", recorder_.Key());
    JsonObject native;
    native.Uint("videoFrames", videoReport_.frames);
    native.Uint("videoWritten", videoReport_.written);
    native.Uint("videoSkippedForCadence", videoReport_.skippedForCadence);
    native.Uint("audioPackets", audioReport_.packets);
    native.Uint("audioSamples", audioReport_.samples);
    native.Uint("audioSilentPackets", audioReport_.silentPackets);
    native.Bool("audioEventDriven", audioReport_.eventDriven);
    native.Bool("itemClosedByOwner", videoReport_.itemClosedByOwner);
    native.Bool("borderControlApplied", videoReport_.borderControlApplied);
    native.Bool("cursorControlApplied", videoReport_.cursorControlApplied);
    native.Str("audioFailure", audioReport_.failure);
    native.Str("videoFailure", videoReport_.failure);
    event.Raw("native", native.Build());
    finalized_ = true;
    WriteState("finalized",
               "\"original\":{\"path\":\"" + JsonEscape(WstringFromWide(original.path)) +
                   "\",\"byteLength\":" + std::to_string(original.byteLength) + "},\"tracks\":" +
                   TracksJson() + ",\"clock\":" + ClockJson() + ",\"source\":" + SourceJson() +
                   ",\"pts\":" + PtsJson());
  } else {
    const std::string native = primaryNative.empty() ? std::string("none") : primaryNative;
    event.Str("code", primaryCode);
    event.Str("operation", primaryOperation);
    // The precise HRESULT of the failing stage. It is S_OK only when that stage's own stop succeeded
    // and the failure is the recorded native string, which travels in nativeFailure.
    event.Str("hresult", HresultHex(primaryHr));
    if (!primaryNative.empty()) event.Str("nativeFailure", primaryNative);
    event.Str("detail", native + ":" + HresultHex(primaryHr));
    WriteState("failed", std::string("\"error\":\"") + primaryOperation + ":" + native + ":" +
                             HresultHex(primaryHr) + "\"");
  }
  EmitEvent(event.Build());
  if (!ok) {
    exitCode_ = 2;
    return FAILED(primaryHr) ? primaryHr : E_FAIL;
  }

  JsonObject stopped;
  stopped.Str("type", "stopped");
  stopped.Str("requestId", request_.requestId);
  stopped.Str("reason", lastReason_);
  stopped.Int("qpcEnd", clock_.Now());
  EmitEvent(stopped.Build());
  WriteState("stopped", "\"reason\":\"" + JsonEscape(lastReason_) + "\"");
  if (FAILED(videoHr) || FAILED(audioHr)) exitCode_ = 1;
  return S_OK;
}

HRESULT Session::Abort(const std::string& reason) {
  if (!started_) return HRESULT_FROM_WIN32(ERROR_INVALID_STATE);
  stopRequested_.store(true);
  lastReason_ = reason.empty() ? "abandoned" : reason;

  VideoReport videoFinal{};
  AudioReport audioFinal{};
  // The HRESULT each Stop returned is the sentinel: a string comparison could be overwritten by a later
  // Stop, and it cannot distinguish a stop that timed out from one that recorded a failure string.
  const HRESULT abortVideoHr = video_.Stop(&videoFinal);
  videoReport_ = videoFinal;
  if (abortVideoHr == kCaptureStopTimedOut) ExitUnstoppable("video-stop", abortVideoHr);
  const HRESULT abortAudioHr = audio_.Stop(&audioFinal);
  audioReport_ = audioFinal;
  if (abortAudioHr == kCaptureStopTimedOut) ExitUnstoppable("audio-stop", abortAudioHr);
  mux_.Abandon();  // partial container is deliberately NOT reported as original
  finalized_ = false;
  exitCode_ = 1;

  JsonObject stopped;
  stopped.Str("type", "stopped");
  stopped.Str("requestId", request_.requestId);
  stopped.Str("reason", lastReason_);
  stopped.Bool("finalized", false);
  EmitEvent(stopped.Build());
  WriteState("stopped", "\"reason\":\"" + JsonEscape(lastReason_) + "\",\"finalized\":false");
  return S_OK;
}

}  // namespace qualityav
