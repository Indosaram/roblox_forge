#include "audio_capture.h"

#include <audioclient.h>
#include <audioclientactivationparams.h>
#include <audiopolicy.h>
#include <combaseapi.h>
#include <ksmedia.h>
#include <mmdeviceapi.h>
#include <mmreg.h>
#include <objbase.h>
#include <processthreadsapi.h>

#include <cstring>
#include <mutex>
#include <thread>

#include "json_line.h"
#include "capture_stop.h"
#include "mux_writer.h"

namespace qualityav {
namespace {

HRESULT g_apartmentInitResult = E_PENDING;

constexpr DWORD kActivationTimeoutMs = 15000;
// Bounded only so a worker that will not exit is detected rather than waited on forever. On expiry the
// worker is neither detached nor freed - see capture_stop.h - the caller fail-closes the process.
constexpr DWORD kStopJoinMs = 10000;

std::string HresultHex(HRESULT value) {
  char buffer[16];
  std::snprintf(buffer, sizeof(buffer), "0x%08lX", static_cast<unsigned long>(value));
  return std::string(buffer);
}

template <typename T>
void Release(T*& value) {
  if (value) {
    value->Release();
    value = nullptr;
  }
}

// Completion sink for ActivateAudioInterfaceAsync. The callback arrives on an
// MTA thread; it stores the activated IAudioClient and signals a Win32 event so
// the calling thread never spins or sleeps.
class ActivationHandler final : public IActivateAudioInterfaceCompletionHandler {
 public:
  HRESULT STDMETHODCALLTYPE ActivateCompleted(IActivateAudioInterfaceAsyncOperation* operation) override {
    HRESULT requested = E_FAIL;
    IUnknown* activated = nullptr;
    HRESULT hr = operation ? operation->GetActivateResult(&requested, &activated) : E_POINTER;
    if (SUCCEEDED(hr) && SUCCEEDED(requested) && activated) {
      hr = activated->QueryInterface(IID_PPV_ARGS(&client_));
      activated->Release();
    } else if (FAILED(hr)) {
      requested = hr;
    }
    {
      std::lock_guard<std::mutex> lock(mutex_);
      result_ = SUCCEEDED(hr) ? requested : hr;
      completed_ = true;
    }
    if (ready_) ::SetEvent(ready_);
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** object) override {
    if (!object) return E_POINTER;
    *object = nullptr;
    if (riid == __uuidof(IUnknown) || riid == __uuidof(IActivateAudioInterfaceCompletionHandler)) {
      *object = static_cast<IActivateAudioInterfaceCompletionHandler*>(this);
      AddRef();
      return S_OK;
    }
    // Both mechanisms are required, and they are not alternatives. The interface documentation says the
    // handler "must be agile (aggregating a free-threaded marshaler)", and the activation documentation
    // ties this exact failure to the marker: the completionHandler "needs to implement IAgileObject to
    // ensure that there is no deadlock when the completionHandler is called from the MTA. Otherwise, an
    // E_ILLEGAL_METHOD_CALL will occur." Microsoft's reference implementations (NAudio's
    // ActivateAudioInterfaceCompletionHandler) declare both interfaces. IAgileObject adds no methods
    // beyond IUnknown, so the completion-handler pointer is the same object and layout-compatible.
    if (riid == __uuidof(IAgileObject)) {
      *object = static_cast<IUnknown*>(this);
      AddRef();
      return S_OK;
    }
    if (riid == __uuidof(IMarshal) && marshaler_) return marshaler_->QueryInterface(riid, object);
    return E_NOINTERFACE;
  }
  ULONG STDMETHODCALLTYPE AddRef() override { return ::InterlockedIncrement(&refCount_); }
  ULONG STDMETHODCALLTYPE Release() override {
    const ULONG value = ::InterlockedDecrement(&refCount_);
    if (value == 0) delete this;
    return value;
  }

  bool WaitFor(DWORD timeoutMs) {
    return ready_ && ::WaitForSingleObject(ready_, timeoutMs) == WAIT_OBJECT_0;
  }
  HRESULT result() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return result_;
  }
  bool completed() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return completed_;
  }
  IAudioClient* TakeClient() {
    std::lock_guard<std::mutex> lock(mutex_);
    IAudioClient* client = client_;
    client_ = nullptr;
    return client;
  }

  explicit ActivationHandler() {
    ready_ = ::CreateEventW(nullptr, FALSE, FALSE, nullptr);
    // IActivateAudioInterfaceCompletionHandler documents its requirement as "The implementation
    // must be agile (aggregating a free-threaded marshaler)", which is exactly how Microsoft's
    // ApplicationLoopback sample gets it from WRL's FtmBase. The reference returned here is held
    // for this object's whole lifetime, as in ATL's FinalConstruct/FinalRelease pairing: releasing
    // it early would drop the marshal delegate while an in-flight marshaled call can still arrive.
    IUnknown* marshaler = nullptr;
    if (SUCCEEDED(::CoCreateFreeThreadedMarshaler(
            static_cast<IActivateAudioInterfaceCompletionHandler*>(this), &marshaler))) {
      marshaler_ = marshaler;
    }
  }
  // The completion signal, the marshal delegate and any activated client are released only when the
  // last reference is gone. A timed-out activation can still be holding this handler through the
  // audio service, and the callback then signals this event and writes under the mutex; keeping all
  // three alive until then is what makes that late callback safe instead of a closed-handle write.
  ~ActivationHandler() {
    if (client_) client_->Release();
    if (marshaler_) marshaler_->Release();
    if (ready_) ::CloseHandle(ready_);
  }

  // True only when the marshal delegate was aggregated and the completion event exists, i.e. when
  // the handler meets the documented agility requirement. The activation is never attempted
  // without it.
  bool Agile() const { return marshaler_ != nullptr && ready_ != nullptr; }

 private:
  LONG refCount_ = 1;
  HANDLE ready_ = nullptr;
  IUnknown* marshaler_ = nullptr;
  mutable std::mutex mutex_;
  HRESULT result_ = E_PENDING;
  bool completed_ = false;
  IAudioClient* client_ = nullptr;
};

HRESULT ActivateProcessLoopback(DWORD targetPid, bool includeTree, IAudioClient** outClient,
                                std::string* operationName, HRESULT* callResult,
                                HRESULT* completionResult, bool* completionObserved) {
  if (!outClient) return E_POINTER;
  *outClient = nullptr;
  if (callResult) *callResult = E_PENDING;
  if (completionResult) *completionResult = E_PENDING;
  if (completionObserved) *completionObserved = false;

  AUDIOCLIENT_ACTIVATION_PARAMS params{};
  params.ActivationType = AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK;
  params.ProcessLoopbackParams.TargetProcessId = targetPid;
  params.ProcessLoopbackParams.ProcessLoopbackMode =
      includeTree ? PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE
                  : PROCESS_LOOPBACK_MODE_EXCLUDE_TARGET_PROCESS_TREE;

  PROPVARIANT activate{};
  activate.vt = VT_BLOB;
  activate.blob.cbSize = sizeof(params);
  activate.blob.pBlobData = reinterpret_cast<BYTE*>(&params);

  ActivationHandler* handler = new ActivationHandler();
  if (!handler->Agile()) {
    // Fail closed and name the cause rather than attempting an activation whose only symptom would
    // be an unattributable method-call error.
    if (operationName) *operationName = "create-agile-handler";
    handler->Release();
    return E_ILLEGAL_METHOD_CALL;
  }
  if (operationName) *operationName = "activate-audio-interface";
  IActivateAudioInterfaceAsyncOperation* operation = nullptr;
  HRESULT hr = ::ActivateAudioInterfaceAsync(VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK,
                                             __uuidof(IAudioClient), &activate, handler, &operation);
  // The synchronous return and the completion report are different facts: the first says whether the
  // request was accepted, the second says what the audio service decided. Keeping them apart is what
  // stops an acceptance from being read as a refusal, or the reverse.
  if (callResult) *callResult = hr;
  if (FAILED(hr)) {
    if (operation) operation->Release();
    handler->Release();
    return hr;
  }
  const bool observed = handler->WaitFor(kActivationTimeoutMs);
  if (completionResult) *completionResult = handler->result();
  if (completionObserved) *completionObserved = handler->completed();
  HRESULT result = observed ? handler->result() : HRESULT_FROM_WIN32(WAIT_TIMEOUT);
  if (!observed && !handler->completed()) result = HRESULT_FROM_WIN32(WAIT_TIMEOUT);
  if (SUCCEEDED(result)) {
    IAudioClient* client = handler->TakeClient();
    if (!client) result = E_NOINTERFACE;
    *outClient = client;
  }
  // The operation is released once the wait is over; the handler is released after it, and the
  // audio service's own reference keeps both alive for any late completion callback.
  if (operation) operation->Release();
  handler->Release();
  return result;
}

HRESULT OpenEndpoint(const std::wstring& endpointId, IMMDeviceEnumerator** outEnumerator,
                     IMMDevice** outDevice, std::wstring* outDeviceId) {
  if (!outEnumerator || !outDevice) return E_POINTER;
  *outEnumerator = nullptr;
  *outDevice = nullptr;

  IMMDeviceEnumerator* enumerator = nullptr;
  HRESULT hr = ::CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                                  __uuidof(IMMDeviceEnumerator),
                                  reinterpret_cast<void**>(&enumerator));
  if (FAILED(hr)) return hr;

  IMMDevice* device = nullptr;
  hr = endpointId.empty()
           ? enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device)
           : enumerator->GetDevice(endpointId.c_str(), &device);
  if (FAILED(hr)) {
    enumerator->Release();
    return hr;
  }

  LPWSTR id = nullptr;
  std::wstring identity = endpointId;
  if (SUCCEEDED(device->GetId(&id)) && id) {
    identity = id;
    ::CoTaskMemFree(id);
  }
  if (outDeviceId) *outDeviceId = identity;
  *outEnumerator = enumerator;
  *outDevice = device;
  return S_OK;
}

// Records the audio sessions actually attached to the endpoint so the caller
// can prove that the mix contains only owned producers.
std::vector<AudioSessionProbe> ProbeEndpointSessions(IMMDevice* device) {
  std::vector<AudioSessionProbe> probes;
  IAudioSessionManager2* manager = nullptr;
  if (FAILED(device->Activate(__uuidof(IAudioSessionManager2), CLSCTX_ALL, nullptr,
                              reinterpret_cast<void**>(&manager))) ||
      !manager) {
    return probes;
  }
  IAudioSessionEnumerator* sessions = nullptr;
  const HRESULT hr = manager->GetSessionEnumerator(&sessions);
  manager->Release();
  if (FAILED(hr) || !sessions) return probes;

  int sessionCount = 0;
  if (FAILED(sessions->GetCount(&sessionCount))) {
    sessions->Release();
    return probes;
  }
  const int count = sessionCount;
  for (int index = 0; index < count; index++) {
    IAudioSessionControl* control = nullptr;
    if (FAILED(sessions->GetSession(index, &control)) || !control) continue;
    IAudioSessionControl2* control2 = nullptr;
    AudioSessionProbe probe;
    AudioSessionState state = AudioSessionStateInactive;
    control->GetState(&state);
    probe.active = (state == AudioSessionStateActive);
    if (SUCCEEDED(control->QueryInterface(IID_PPV_ARGS(&control2))) && control2) {
      DWORD pid = 0;
      if (SUCCEEDED(control2->GetProcessId(&pid)) && pid != 0) {
        probe.identityObserved = ReadProcessIdentity(pid, &probe.identity);
      }
      probe.systemSounds = control2->IsSystemSoundsSession() == S_OK;
      control2->Release();
    }
    probes.push_back(probe);
    control->Release();
  }
  sessions->Release();
  return probes;
}

bool IsFloatFormat(const WAVEFORMATEXTENSIBLE& format) {
  return format.Format.wFormatTag == WAVE_FORMAT_EXTENSIBLE &&
         IsEqualGUID(format.SubFormat, KSDATAFORMAT_SUBTYPE_IEEE_FLOAT);
}

void LoadFormat(const WAVEFORMATEX* source, WAVEFORMATEXTENSIBLE* out) {
  std::memset(out, 0, sizeof(*out));
  if (source->wFormatTag == WAVE_FORMAT_EXTENSIBLE &&
      source->cbSize >= sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX)) {
    std::memcpy(out, source, sizeof(WAVEFORMATEXTENSIBLE));
    return;
  }
  out->Format = *source;
  out->Format.cbSize = 0;
}

void BuildFallbackFormat(const AudioConfig& config, WAVEFORMATEXTENSIBLE* out) {
  std::memset(out, 0, sizeof(*out));
  out->Format.wFormatTag = WAVE_FORMAT_PCM;
  out->Format.nChannels = config.fallbackChannels;
  out->Format.nSamplesPerSec = config.fallbackSampleRate;
  out->Format.wBitsPerSample = config.fallbackBits;
  out->Format.nBlockAlign = static_cast<WORD>(out->Format.nChannels * out->Format.wBitsPerSample / 8);
  out->Format.nAvgBytesPerSec = out->Format.nSamplesPerSec * out->Format.nBlockAlign;
  out->Format.cbSize = 0;
}

// The process-loopback virtual device activates an AudioSes CMixerClient, and
// Microsoft documents that this class does not implement GetMixFormat or
// IsFormatSupported (both fail on COM calls). The capture format therefore has to
// be supplied by the caller; this is the format the ApplicationLoopback sample
// hardcodes for that route - CD-quality 16-bit PCM, two channels, 44100 Hz - and
// AUTOCONVERTPCM lets the audio engine convert it to whatever the mixer runs.
void BuildProcessLoopbackFormat(WAVEFORMATEXTENSIBLE* out) {
  std::memset(out, 0, sizeof(*out));
  out->Format.wFormatTag = WAVE_FORMAT_PCM;
  out->Format.nChannels = 2;
  out->Format.nSamplesPerSec = 44100;
  out->Format.wBitsPerSample = 16;
  out->Format.nBlockAlign = static_cast<WORD>(out->Format.nChannels * out->Format.wBitsPerSample / 8);
  out->Format.nAvgBytesPerSec = out->Format.nSamplesPerSec * out->Format.nBlockAlign;
  out->Format.cbSize = 0;
}

}  // namespace

struct AudioCapture::Impl {
  AudioConfig config;
  MuxWriter* mux = nullptr;
  const QpcClock* clock = nullptr;
  std::atomic<bool>* stopRequested = nullptr;

  HANDLE stopEvent = nullptr;
  HANDLE sampleEvent = nullptr;
  std::thread thread;
  HRESULT threadHr = S_OK;

  IMMDeviceEnumerator* enumerator = nullptr;
  IMMDevice* device = nullptr;
  IAudioClient* client = nullptr;
  IAudioCaptureClient* capture = nullptr;
  IAudioClock* audioClock = nullptr;

  WAVEFORMATEXTENSIBLE format{};
  bool eventDriven = false;
  UINT32 blockAlign = 0;
  DWORD pollSliceMs = 10;
  AudioReport report;

  HRESULT OpenClient();
  HRESULT ConfigureClient();
  void CaptureLoop();
  void Drain();
  // Returns false when the capture thread did not exit within the bound, in which case nothing owned
  // by this Impl was released and the thread was deliberately left joinable.
  bool Close();

  // Records the exact native operation and HRESULT of the failure that is returned,
  // so the caller never has to infer which WASAPI step failed.
  HRESULT Fail(const char* operation, HRESULT hr) {
    if (FAILED(hr)) {
      report.failureOperation = operation;
      report.failureHresult = static_cast<long>(hr);
      report.failure = std::string(operation) + ":" + HresultHex(hr);
    }
    return hr;
  }
};

HRESULT AudioCapture::Impl::OpenClient() {
  if (config.route == AudioRoute::ProcessLoopback) {
    if (config.targetPid == 0) return Fail("target-pid", E_INVALIDARG);
    // The operation name distinguishes a handler that could not be made agile from an activation
    // the audio service refused, so neither cause has to be inferred from a bare HRESULT.
    std::string operationName = "activate-process-loopback";
    const HRESULT activated = ActivateProcessLoopback(
        config.targetPid, config.includeTargetProcessTree, &client, &operationName, nullptr, nullptr,
        nullptr);
    return Fail(operationName.c_str(), activated);
  }
  std::wstring deviceId;
  const HRESULT hr = OpenEndpoint(config.endpointId, &enumerator, &device, &deviceId);
  if (FAILED(hr)) return Fail("open-endpoint", hr);
  report.endpointIdentity = "endpoint:" + WideToUtf8(deviceId);
  report.endpointDeviceId = WideToUtf8(deviceId);
  report.activationKind = "endpoint-loopback";
  report.endpointSessions = ProbeEndpointSessions(device);
  return Fail("activate-endpoint", device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                                                   reinterpret_cast<void**>(&client)));
}

HRESULT AudioCapture::Impl::ConfigureClient() {
  if (!client) return E_POINTER;
  DWORD flags = AUDCLNT_STREAMFLAGS_LOOPBACK;
  if (config.route == AudioRoute::ProcessLoopback) {
    // Never query this client: the process-loopback class has no GetMixFormat or
    // IsFormatSupported, so the documented fixed PCM format is supplied instead.
    BuildProcessLoopbackFormat(&format);
    flags |= AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY;
  } else {
    WAVEFORMATEX* mix = nullptr;
    const HRESULT mixHr = client->GetMixFormat(&mix);
    if (SUCCEEDED(mixHr) && mix && mix->nSamplesPerSec > 0 && mix->nBlockAlign > 0) {
      LoadFormat(mix, &format);
      ::CoTaskMemFree(mix);
    } else {
      if (mix) ::CoTaskMemFree(mix);
      BuildFallbackFormat(config, &format);
      // A shared-mode endpoint can reject the queried format; AUTOCONVERTPCM lets a
      // defined PCM format be requested and converted by the audio engine instead.
      flags |= AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY;
    }
  }

  HRESULT hr = client->Initialize(AUDCLNT_SHAREMODE_SHARED,
                                  flags | AUDCLNT_STREAMFLAGS_EVENTCALLBACK, 0, 0, &format.Format,
                                  nullptr);
  if (SUCCEEDED(hr)) {
    eventDriven = true;
  } else {
    // A failed Initialize leaves this client unusable, so acquire a fresh one
    // and fall back to a stop-event bounded poll instead of failing the session.
    // The event-driven HRESULT is retained so the fallback cannot hide it.
    const HRESULT eventDrivenHr = hr;
    Release(client);
    const HRESULT reopen = OpenClient();
    if (FAILED(reopen)) return reopen;
    hr = client->Initialize(AUDCLNT_SHAREMODE_SHARED, flags, 0, 0, &format.Format, nullptr);
    eventDriven = false;
    if (FAILED(hr)) {
      report.failureOperation = "initialize";
      report.failureHresult = static_cast<long>(hr);
      report.failure = "initialize:" + HresultHex(hr) + ":event-driven:" + HresultHex(eventDrivenHr);
      return hr;
    }
  }

  blockAlign = format.Format.nBlockAlign;
  report.sampleRate = format.Format.nSamplesPerSec;
  report.channels = format.Format.nChannels;
  report.bitsPerSample = format.Format.wBitsPerSample;
  report.floatFormat = IsFloatFormat(format);
  report.eventDriven = eventDriven;

  REFERENCE_TIME defaultPeriod = 0;
  if (SUCCEEDED(client->GetDevicePeriod(&defaultPeriod, nullptr)) && defaultPeriod > 0) {
    const DWORD slice = static_cast<DWORD>(defaultPeriod / 10000);
    pollSliceMs = slice < 5 ? 5 : (slice > 100 ? 100 : slice);
  }
  return S_OK;
}

void AudioCapture::Impl::Drain() {
  UINT32 packetFrames = 0;
  std::vector<BYTE> silent;
  while (capture && SUCCEEDED(capture->GetNextPacketSize(&packetFrames)) && packetFrames > 0) {
    BYTE* data = nullptr;
    UINT32 frames = 0;
    DWORD flags = 0;
    UINT64 devicePosition = 0;
    UINT64 packetQpc = 0;
    const HRESULT hr = capture->GetBuffer(&data, &frames, &flags, &devicePosition, &packetQpc);
    if (FAILED(hr)) {
      threadHr = hr;
      return;
    }
    const UINT32 bytes = frames * blockAlign;
    const long long arrival = clock->Now();
    long long ticks = packetQpc != 0 ? static_cast<long long>(packetQpc) : arrival;
    if (ticks < clock->start.QuadPart) ticks = arrival;
    // PTS is taken from the engine's QPC position for the packet when supplied,
    // otherwise from this session clock at arrival; both raw values are kept.
    const long long pts100ns = clock->TicksTo100ns(ticks - clock->start.QuadPart);

    if ((flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0 || data == nullptr) {
      silent.assign(bytes, 0);
      mux->WriteAudio(silent.data(), bytes, pts100ns, ticks);
      report.silentPackets++;
    } else {
      mux->WriteAudio(data, bytes, pts100ns, ticks);
    }

    if (report.packets == 0) {
      report.firstDevicePosition = static_cast<long long>(devicePosition);
      report.firstPacketQpc = ticks;
      report.firstPacketPts100ns = pts100ns;
    }
    report.lastDevicePosition = static_cast<long long>(devicePosition);
    report.lastPacketQpc = ticks;
    report.lastPacketPts100ns = pts100ns;
    report.packets++;
    report.samples += frames;
    capture->ReleaseBuffer(frames);
  }
}

void AudioCapture::Impl::CaptureLoop() {
  if (eventDriven && client) client->SetEventHandle(sampleEvent);
  const HRESULT startHr = client ? client->Start() : E_POINTER;
  if (FAILED(startHr)) {
    threadHr = startHr;
    return;
  }
  while (!(stopRequested && stopRequested->load())) {
    if (eventDriven) {
      HANDLE handles[2] = {stopEvent, sampleEvent};
      const DWORD wait = ::WaitForMultipleObjects(2, handles, FALSE, INFINITE);
      if (wait != WAIT_OBJECT_0 + 1) break;
    } else {
      if (::WaitForSingleObject(stopEvent, pollSliceMs) == WAIT_OBJECT_0) break;
    }
    Drain();
  }
  Drain();  // final drain after the stop request so the tail is not dropped
  if (client) client->Stop();
}

bool AudioCapture::Impl::Close() {
  if (thread.joinable()) {
    // Stop() has already signalled stopEvent, so the loop only has to finish the packet it is holding.
    // That can still be inside WriteSample, which Media Foundation documents as blocking the calling
    // thread by default, so the wait is bounded.
    const HANDLE handle = static_cast<HANDLE>(thread.native_handle());
    if (::WaitForSingleObject(handle, kStopJoinMs) != WAIT_OBJECT_0) {
      if (report.failure.empty()) report.failure = "audio-stop-join-timeout";
      return false;
    }
    thread.join();
  }
  Release(capture);
  Release(audioClock);
  Release(client);
  Release(device);
  Release(enumerator);
  if (sampleEvent) {
    ::CloseHandle(sampleEvent);
    sampleEvent = nullptr;
  }
  if (stopEvent) {
    ::CloseHandle(stopEvent);
    stopEvent = nullptr;
  }
  return true;
}

AudioCapture::AudioCapture() : impl_(new Impl()) {}

AudioCapture::~AudioCapture() {
  if (impl_) {
    // Close() returns false only when the capture thread is still inside this Impl and its WASAPI
    // objects, so deleting impl_ here would be a use-after-free. The stop gate is signalled first, and
    // the fail-closed action is to end the isolated helper process rather than free what the worker is
    // still using. This destructor is reachable from start-failure paths that never call Finish.
    if (impl_->stopEvent) ::SetEvent(impl_->stopEvent);
    if (!impl_->Close()) FailClosedProcess("audio-stop");
    delete impl_;
    impl_ = nullptr;
  }
}

HRESULT AudioCapture::Prepare(const AudioConfig& config, const QpcClock* clock,
                              AudioReport* outReport) {
  if (!impl_ || !clock || !outReport) return E_POINTER;
  impl_->config = config;
  impl_->clock = clock;
  impl_->stopEvent = ::CreateEventW(nullptr, TRUE, FALSE, nullptr);    // manual-reset stop gate
  impl_->sampleEvent = ::CreateEventW(nullptr, FALSE, FALSE, nullptr);  // auto-reset WASAPI signal
  if (!impl_->stopEvent || !impl_->sampleEvent) return HRESULT_FROM_WIN32(::GetLastError());

  HRESULT hr = impl_->OpenClient();
  if (SUCCEEDED(hr)) hr = impl_->ConfigureClient();
  if (SUCCEEDED(hr) && config.route == AudioRoute::ProcessLoopback) {
    impl_->report.activationKind = "process-loopback";
    impl_->report.endpointIdentity =
        "process-loopback:" + WideToUtf8(VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK) +
        ":target=" + std::to_string(config.targetPid) +
        ":mode=" + (config.includeTargetProcessTree ? "include-tree" : "exclude-tree");
    impl_->report.processTree = EnumerateProcessTree(config.targetPid);
  }
  if (SUCCEEDED(hr)) {
    UINT32 bufferFrames = 0;
    hr = impl_->Fail("get-buffer-size", impl_->client->GetBufferSize(&bufferFrames));
  }
  if (SUCCEEDED(hr)) {
    hr = impl_->Fail("get-capture-service",
                     impl_->client->GetService(IID_PPV_ARGS(&impl_->capture)));
  }
  if (SUCCEEDED(hr)) {
    // Optional: engine packet positions are used when present, so a missing
    // IAudioClock is recorded as such rather than treated as a failure.
    impl_->client->GetService(IID_PPV_ARGS(&impl_->audioClock));
  }
  if (FAILED(hr)) {
    impl_->Close();
    if (impl_->report.failure.empty()) {
      impl_->report.failure = "audio-open-failed:" + HresultHex(hr);
    }
    *outReport = impl_->report;
    return hr;
  }
  *outReport = impl_->report;
  return S_OK;
}

HRESULT AudioCapture::Start(MuxWriter* mux, std::atomic<bool>* stopRequested,
                            AudioReport* outReport) {
  if (!impl_ || !mux || !stopRequested || !outReport) return E_POINTER;
  if (!impl_->client || !impl_->capture) return HRESULT_FROM_WIN32(ERROR_INVALID_STATE);
  impl_->mux = mux;
  impl_->stopRequested = stopRequested;
  impl_->thread = std::thread(&AudioCapture::Impl::CaptureLoop, impl_);
  *outReport = impl_->report;
  return S_OK;
}

HRESULT AudioCapture::Stop(AudioReport* outReport) {
  if (!impl_) return E_POINTER;
  // The stop gate is signalled before the worker is awaited, so the loop stops producing rather than
  // being torn down while it is mid-packet.
  if (impl_->stopEvent) ::SetEvent(impl_->stopEvent);
  const bool joined = impl_->Close();
  if (FAILED(impl_->threadHr)) {
    impl_->report.failure = "audio-thread-failed:" + HresultHex(impl_->threadHr);
  }
  if (outReport) *outReport = impl_->report;
  // A thread that did not exit is reported as a stop timeout, never as a normal stop: the caller must
  // not go on to free the objects it is still using.
  if (!joined) return kCaptureStopTimedOut;
  return impl_->threadHr;
}

// Records what the runtime actually is at the moment of activation, so an activation refusal can be
// attributed instead of guessed: the apartment this thread is really in (not the one it asked for), the
// window station and desktop it is attached to, the OS build, the helper's and the target's
// process/session/thread, which interfaces the completion handler answers, and the activation result
// split into the synchronous call and the completion report. No capture route is opened.
HRESULT ProbeProcessLoopbackActivation(DWORD targetPid, bool includeTree, AudioActivationProbe* out) {
  if (!out) return E_POINTER;
  APTTYPE type = APTTYPE_CURRENT;
  APTTYPEQUALIFIER qualifier = APTTYPEQUALIFIER_NONE;
  const HRESULT apartment = ::CoGetApartmentType(&type, &qualifier);
  out->apartmentHresult = static_cast<long>(apartment);
  out->apartmentType = static_cast<int>(type);
  out->apartmentQualifier = static_cast<int>(qualifier);
  out->apartmentInitHresult = static_cast<long>(ApartmentInitResult());
  out->processId = static_cast<unsigned long>(::GetCurrentProcessId());
  out->threadId = static_cast<unsigned long>(::GetCurrentThreadId());
  DWORD session = 0;
  if (::ProcessIdToSessionId(static_cast<DWORD>(out->processId), &session)) {
    out->sessionId = static_cast<unsigned long>(session);
  }
  // The window station and desktop decide whether this thread can reach the interactive session's
  // audio stack at all, which no process-level measurement shows.
  auto objectName = [](HANDLE handle) -> std::string {
    if (!handle) return {};
    wchar_t buffer[256] = {};
    DWORD needed = 0;
    if (!::GetUserObjectInformationW(handle, UOI_NAME, buffer, sizeof(buffer), &needed)) return {};
    return WideToUtf8(buffer);
  };
  out->windowStation = objectName(::GetProcessWindowStation());
  out->desktop = objectName(::GetThreadDesktop(::GetCurrentThreadId()));
  struct OsVersionInfo {
    unsigned long size, major, minor, build, platform;
    wchar_t servicePack[128];
  };
  using RtlGetVersionFn = long(WINAPI*)(OsVersionInfo*);
  HMODULE ntdll = ::GetModuleHandleW(L"ntdll.dll");
  auto rtlGetVersion =
      ntdll ? reinterpret_cast<RtlGetVersionFn>(::GetProcAddress(ntdll, "RtlGetVersion")) : nullptr;
  if (rtlGetVersion) {
    OsVersionInfo info{};
    info.size = sizeof(info);
    if (rtlGetVersion(&info) == 0) out->osBuild = info.build;
  }
  out->targetPid = static_cast<unsigned long>(targetPid);
  if (targetPid != 0) {
    DWORD targetSession = 0;
    if (::ProcessIdToSessionId(targetPid, &targetSession)) {
      out->targetSessionId = static_cast<unsigned long>(targetSession);
    }
    HANDLE process = ::OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, targetPid);
    out->targetAlive = process != nullptr;
    if (process) ::CloseHandle(process);
  }

  // The handler that would be handed to the activation, checked for the interfaces that decide whether
  // it can cross an apartment boundary: the free-threaded marshaler's IMarshal and the IAgileObject
  // marker the activation documentation requires.
  {
    ActivationHandler* handler = new ActivationHandler();
    out->marshalerAggregated = handler->Agile();
    IUnknown* answered = nullptr;
    out->marshalAnswered =
        SUCCEEDED(handler->QueryInterface(__uuidof(IMarshal), reinterpret_cast<void**>(&answered))) &&
        answered != nullptr;
    if (answered) answered->Release();
    answered = nullptr;
    out->agileObjectAnswered =
        SUCCEEDED(handler->QueryInterface(__uuidof(IAgileObject), reinterpret_cast<void**>(&answered))) &&
        answered != nullptr;
    if (answered) answered->Release();
    handler->Release();
  }

  std::string operation = "activate-process-loopback";
  IAudioClient* client = nullptr;
  HRESULT call = E_PENDING, completion = E_PENDING;
  bool observed = false;
  const HRESULT activated = ActivateProcessLoopback(targetPid, includeTree, &client, &operation, &call,
                                                    &completion, &observed);
  out->operation = operation;
  out->callHresult = static_cast<long>(call);
  out->completionHresult = static_cast<long>(completion);
  out->completionObserved = observed;
  out->activationHresult = static_cast<long>(activated);
  if (client) client->Release();
  return activated;
}

void RecordApartmentInitResult(HRESULT hr) { g_apartmentInitResult = hr; }

HRESULT ApartmentInitResult() { return g_apartmentInitResult; }

}  // namespace qualityav
