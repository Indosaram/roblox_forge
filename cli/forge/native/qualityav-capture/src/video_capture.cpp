#include "video_capture.h"

#include <d3d11.h>
#include <dxgi.h>
#include <windows.graphics.capture.interop.h>
#include <windows.graphics.directx.direct3d11.interop.h>

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Graphics.Capture.h>
#include <winrt/Windows.Graphics.DirectX.h>
#include <winrt/Windows.Graphics.DirectX.Direct3D11.h>

#include <chrono>
#include <condition_variable>
#include <mutex>

#include "json_line.h"
#include "capture_stop.h"
#include "mux_writer.h"

namespace qualityav {
namespace {

namespace winrt_capture = winrt::Windows::Graphics::Capture;
namespace winrt_directx = winrt::Windows::Graphics::DirectX;
namespace winrt_d3d = winrt::Windows::Graphics::DirectX::Direct3D11;

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

}  // namespace

struct VideoCapture::Impl {
  VideoConfig config;
  MuxWriter* mux = nullptr;
  const QpcClock* clock = nullptr;
  std::atomic<bool>* stopRequested = nullptr;
  VideoReport report;

  ID3D11Device* device = nullptr;
  ID3D11DeviceContext* context = nullptr;
  ID3D11Texture2D* staging = nullptr;
  winrt_d3d::IDirect3DDevice d3dDevice{nullptr};
  winrt_capture::GraphicsCaptureItem item{nullptr};
  winrt_capture::Direct3D11CaptureFramePool pool{nullptr};
  winrt_capture::GraphicsCaptureSession session{nullptr};

  winrt::event_token frameToken{};
  winrt::event_token closedToken{};

  std::mutex mutex;
  std::condition_variable drained;
  bool stopping = false;
  // Set only after a real drain. A timeout must not look like a completed stop, or a repeat call would
  // return S_OK over a teardown that never happened.
  bool stopCompleted = false;
  HRESULT stopHr = S_OK;
  long inFlight = 0;

  long long qpcPerFrame = 0;
  long long lastWrittenQpc = 0;
  HRESULT hr = S_OK;

  void OnFrameArrived(winrt_capture::Direct3D11CaptureFramePool const& sender,
                      winrt::Windows::Foundation::IInspectable const&);
  void OnItemClosed(winrt_capture::GraphicsCaptureItem const&, winrt::Windows::Foundation::IInspectable const&);
  HRESULT EnsureStaging(ID3D11Texture2D* source);
  void ReleaseAll();
};

HRESULT VideoCapture::Impl::EnsureStaging(ID3D11Texture2D* source) {
  D3D11_TEXTURE2D_DESC desc{};
  source->GetDesc(&desc);
  if (staging) {
    D3D11_TEXTURE2D_DESC current{};
    staging->GetDesc(&current);
    if (current.Width == desc.Width && current.Height == desc.Height) return S_OK;
    Release(staging);
  }
  D3D11_TEXTURE2D_DESC stagingDesc = desc;
  stagingDesc.Usage = D3D11_USAGE_STAGING;
  stagingDesc.BindFlags = 0;
  stagingDesc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
  stagingDesc.MiscFlags = 0;
  stagingDesc.MipLevels = 1;
  stagingDesc.ArraySize = 1;
  return device->CreateTexture2D(&stagingDesc, nullptr, &staging);
}

void VideoCapture::Impl::OnFrameArrived(winrt_capture::Direct3D11CaptureFramePool const& sender,
                                        winrt::Windows::Foundation::IInspectable const&) {
  {
    std::lock_guard<std::mutex> lock(mutex);
    if (stopping) return;
    inFlight++;
  }
  auto finish = [this]() {
    bool notify = false;
    {
      std::lock_guard<std::mutex> lock(mutex);
      inFlight--;
      notify = stopping && inFlight == 0;
    }
    if (notify) drained.notify_all();
  };

  try {
    auto frame = sender.TryGetNextFrame();
    if (!frame) {
      finish();
      return;
    }
    const long long systemRelative = frame.SystemRelativeTime().count();
    const long long arrival = clock->Now();
    report.frames++;
    if (report.frames == 1) {
      report.firstSystemRelative100ns = systemRelative;
      report.firstArrivalQpc = arrival;
      report.firstPts100ns = clock->TicksTo100ns(arrival - clock->start.QuadPart);
      report.systemRelativeMinusSession100ns =
          systemRelative - report.firstPts100ns;
    }
    report.lastSystemRelative100ns = systemRelative;
    report.lastArrivalQpc = arrival;

    const bool stoppingNow = (stopRequested && stopRequested->load()) ||
                             (config.maxFrames > 0 && report.written >= config.maxFrames);
    if (stoppingNow) {
      frame.Close();
      finish();
      return;
    }
    if (lastWrittenQpc != 0 && qpcPerFrame > 0 &&
        arrival - lastWrittenQpc < qpcPerFrame) {
      report.skippedForCadence++;
      frame.Close();
      finish();
      return;
    }

    // Every path that drops a delivered frame records why. Without this the report showed
    // frames > 0 with written == 0 and no failure, which is the state that cannot be attributed.
    auto noteFailure = [this](const std::string& code) {
      if (report.failure.empty()) report.failure = code;
    };
    // The mux is assigned by Start(), which is also the only place the session is started, so a frame
    // can never legitimately arrive before the mux exists. Fail closed on a broken invariant instead of
    // dereferencing a null mux inside this pool callback, which would take the whole helper down.
    if (!mux) {
      noteFailure("frame-before-mux");
      frame.Close();
      finish();
      return;
    }
    auto surface = frame.Surface();
    // A Direct3D11CaptureFrame::Surface is a WinRT IDirect3DSurface, not an ID3D11Texture2D. The
    // documented bridge is IDirect3DDxgiInterfaceAccess, which the API reference states "must be
    // implemented by anything that implements IDirect3DDevice or IDirect3DSurface", and whose
    // GetInterface "[r]etrieves the DXGI interface that is wrapped by the IDirect3DDxgiInterfaceAccess
    // object". Querying the WinRT surface for ID3D11Texture2D directly never reaches the texture, so
    // every delivered frame was dropped here before it could be encoded. The type is declared by
    // windows.graphics.directx.direct3d11.interop.h in the global namespace, not in winrt::.
    winrt::com_ptr<ID3D11Texture2D> texture;
    HRESULT bridgeHr = E_NOINTERFACE;
    try {
      // as<> yields a com_ptr for this interop interface, so it is held as one and GetInterface is
      // called through it; it throws hresult_error when the surface does not answer the interface.
      auto access = surface.as<::Windows::Graphics::DirectX::Direct3D11::IDirect3DDxgiInterfaceAccess>();
      bridgeHr = access->GetInterface(IID_PPV_ARGS(texture.put()));
    } catch (winrt::hresult_error const& error) {
      bridgeHr = error.code();
    }
    if (FAILED(bridgeHr) || !texture) {
      noteFailure("frame-surface-bridge-failed:" + HresultHex(bridgeHr));
      frame.Close();
      finish();
      return;
    }
    if (FAILED(EnsureStaging(texture.get()))) {
      noteFailure("frame-staging-failed");
      frame.Close();
      finish();
      return;
    }
    // EnsureStaging builds the staging texture from this frame's own description, so its dimensions
    // and format match the source exactly and CopyResource is a valid whole-resource copy. The staging
    // texture therefore stays the window's real (possibly odd) size; only the muxed region is read out
    // of it, so the rounding in the report never disagrees with what was allocated or copied.
    context->CopyResource(staging, texture.get());
    D3D11_MAPPED_SUBRESOURCE mapped{};
    if (FAILED(context->Map(staging, 0, D3D11_MAP_READ, 0, &mapped))) {
      noteFailure("frame-map-failed");
      frame.Close();
      finish();
      return;
    }
    const long long pts100ns = clock->TicksTo100ns(arrival - clock->start.QuadPart);
    const HRESULT writeHr = mux->WriteVideo(static_cast<const BYTE*>(mapped.pData), mapped.RowPitch,
                                            pts100ns, arrival);
    context->Unmap(staging, 0);
    if (SUCCEEDED(writeHr)) {
      report.written++;
      lastWrittenQpc = arrival;
      report.lastPts100ns = pts100ns;
    } else {
      hr = writeHr;
      noteFailure("frame-write-failed:" + HresultHex(writeHr));
    }
    frame.Close();
  } catch (winrt::hresult_error const& error) {
    hr = error.code();
  } catch (...) {
    hr = E_UNEXPECTED;
  }
  finish();
}

void VideoCapture::Impl::OnItemClosed(winrt_capture::GraphicsCaptureItem const&,
                                      winrt::Windows::Foundation::IInspectable const&) {
  report.itemClosedByOwner = true;
}

HRESULT VideoCapture::Prepare(const VideoConfig& config, const QpcClock* clock,
                              VideoReport* outReport) {
  if (!impl_ || !clock || !outReport) return E_POINTER;
  impl_->config = config;
  impl_->clock = clock;
  impl_->report.hwnd = HwndKey(config.window);
  if (!config.window || !::IsWindow(config.window)) {
    impl_->report.failure = "window-not-found";
    *outReport = impl_->report;
    return E_HANDLE;
  }
  impl_->report.windowOwnerObserved = IdentifyWindowOwner(config.window, &impl_->report.windowOwner);

  HRESULT hr = ::D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
                                   D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0, D3D11_SDK_VERSION,
                                   &impl_->device, nullptr, &impl_->context);
  if (FAILED(hr)) {
    hr = ::D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_WARP, nullptr,
                             D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0, D3D11_SDK_VERSION,
                             &impl_->device, nullptr, &impl_->context);
  }
  if (FAILED(hr)) {
    impl_->report.failure = "d3d11-device-failed";
    *outReport = impl_->report;
    return hr;
  }

  IDXGIDevice* dxgiDevice = nullptr;
  hr = impl_->device->QueryInterface(IID_PPV_ARGS(&dxgiDevice));
  if (SUCCEEDED(hr)) {
    IInspectable* inspectable = nullptr;
    hr = ::CreateDirect3D11DeviceFromDXGIDevice(dxgiDevice, &inspectable);
    if (SUCCEEDED(hr)) {
      winrt::copy_from_abi(impl_->d3dDevice, inspectable);
      inspectable->Release();
    }
    dxgiDevice->Release();
  }
  if (FAILED(hr)) {
    impl_->report.failure = "direct3d-device-wrap-failed";
    *outReport = impl_->report;
    impl_->ReleaseAll();
    return hr;
  }

  try {
    // Direct HWND route: IGraphicsCaptureItemInterop::CreateForWindow, no
    // picker and no activation of a foreground window in this code path.
    auto interop = winrt::get_activation_factory<winrt_capture::GraphicsCaptureItem,
                                                 IGraphicsCaptureItemInterop>();
    hr = interop->CreateForWindow(config.window, winrt::guid_of<winrt_capture::GraphicsCaptureItem>(),
                                  reinterpret_cast<void**>(winrt::put_abi(impl_->item)));
    if (FAILED(hr)) {
      impl_->report.failure = "capture-item-create-failed";
      *outReport = impl_->report;
      impl_->ReleaseAll();
      return hr;
    }
    const winrt::Windows::Graphics::SizeInt32 size = impl_->item.Size();
    impl_->report.width = size.Width > 0 ? static_cast<unsigned int>(size.Width) : 0;
    impl_->report.height = size.Height > 0 ? static_cast<unsigned int>(size.Height) : 0;
    if (impl_->report.width == 0 || impl_->report.height == 0) {
      impl_->report.failure = "capture-item-size-zero";
      *outReport = impl_->report;
      impl_->ReleaseAll();
      return E_INVALIDARG;
    }
    // The capture item is the window's own size, which is arbitrary and can be odd: an earlier run's
    // window inventory measured the Studio client windows at 1602x1153. H.264 needs even dimensions, so
    // an odd item size is a plausible established source of a MF_E_INVALIDMEDIATYPE at container open -
    // but the artifact alone does not prove which stream was refused, and the window size is not the
    // item size until Prepare reads it. The mux records the failing step and the offered formats at
    // runtime, and that is the evidence that attributes it. The reported size is therefore rounded down
    // to the even size that is actually muxed, and the frame copy is clipped to it, so the extra row and
    // column are cropped rather than the stream being padded or the format guessed.
    const unsigned int muxedWidth = impl_->report.width & ~1u;
    const unsigned int muxedHeight = impl_->report.height & ~1u;
    if (muxedWidth == 0 || muxedHeight == 0) {
      impl_->report.failure = "capture-item-size-too-small";
      *outReport = impl_->report;
      impl_->ReleaseAll();
      return E_INVALIDARG;
    }
    impl_->report.width = muxedWidth;
    impl_->report.height = muxedHeight;

    impl_->pool = winrt_capture::Direct3D11CaptureFramePool::CreateFreeThreaded(
        impl_->d3dDevice, winrt_directx::DirectXPixelFormat::B8G8R8A8UIntNormalized, 2, size);
    impl_->frameToken = impl_->pool.FrameArrived(
        {impl_, &VideoCapture::Impl::OnFrameArrived});
    impl_->closedToken = impl_->item.Closed({impl_, &VideoCapture::Impl::OnItemClosed});
    impl_->session = impl_->pool.CreateCaptureSession(impl_->item);

    // Border and cursor policy are attempted but never assumed: an unsupported
    // build records the fact instead of failing or silently claiming privacy.
    if (config.hideBorder) {
      try {
        impl_->session.IsBorderRequired(false);
        impl_->report.borderControlApplied = true;
      } catch (winrt::hresult_error const&) {
        impl_->report.borderControlApplied = false;
      }
    }
    try {
      impl_->session.IsCursorCaptureEnabled(config.includeCursor);
      impl_->report.cursorControlApplied = true;
    } catch (winrt::hresult_error const&) {
      impl_->report.cursorControlApplied = false;
    }

    // Prepare deliberately does NOT start the session. Starting it here began delivering frames before
    // the mux existed, and the (now working) surface bridge let those frames reach mux->WriteVideo with
    // a null mux, killing the helper inside this call. The session is started by Start(), which is the
    // first point at which the mux and the stop flag are both assigned.
  } catch (winrt::hresult_error const& error) {
    impl_->report.failure = "capture-prepare-failed:" + HresultHex(error.code());
    *outReport = impl_->report;
    impl_->ReleaseAll();
    return error.code();
  }

  if (config.fpsDen > 0 && config.fpsNum > 0 && clock->frequency.QuadPart > 0) {
    impl_->qpcPerFrame = (static_cast<long long>(clock->frequency.QuadPart) * config.fpsDen) /
                         config.fpsNum;
  }
  *outReport = impl_->report;
  return S_OK;
}

HRESULT VideoCapture::Start(MuxWriter* mux, std::atomic<bool>* stopRequested,
                            VideoReport* outReport) {
  if (!impl_ || !mux || !stopRequested || !outReport) return E_POINTER;
  if (!impl_->session || !impl_->pool) return HRESULT_FROM_WIN32(ERROR_INVALID_STATE);
  impl_->mux = mux;
  impl_->stopRequested = stopRequested;
  try {
    impl_->session.StartCapture();
    impl_->report.sessionStarted = true;
  } catch (winrt::hresult_error const& error) {
    impl_->report.failure = "capture-start-failed:" + HresultHex(error.code());
    *outReport = impl_->report;
    return error.code();
  }
  *outReport = impl_->report;
  return S_OK;
}

HRESULT VideoCapture::Stop(VideoReport* outReport) {
  if (!impl_) return E_POINTER;
  if (impl_->stopCompleted) {
    if (outReport) *outReport = impl_->report;
    return impl_->stopHr;
  }
  {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    impl_->stopping = true;
  }

  // Close the WinRT objects before waiting so no new frames are dispatched.
  try {
    if (impl_->session) impl_->session.Close();
  } catch (winrt::hresult_error const&) {
  }
  impl_->session = nullptr;
  try {
    if (impl_->pool) impl_->pool.Close();
  } catch (winrt::hresult_error const&) {
  }
  impl_->pool = nullptr;

  bool drained = false;
  {
    std::unique_lock<std::mutex> lock(impl_->mutex);
    drained = impl_->drained.wait_for(lock, std::chrono::seconds(5),
                                      [&] { return impl_->inFlight == 0; });
  }

  if (!drained) {
    // The pool is closed, so no new callback can start, but one that already started is still inside
    // the D3D device, context and staging texture - and inside this Impl through the handler target.
    // Detaching it or freeing those objects would leave a live callback dereferencing destroyed
    // memory, so nothing is released, this stop is NOT marked complete, and a repeat call re-waits and
    // reports the same timeout rather than returning S_OK over a teardown that never happened.
    if (impl_->report.failure.empty()) impl_->report.failure = "video-stop-drain-timeout";
    impl_->stopHr = kCaptureStopTimedOut;
    if (outReport) *outReport = impl_->report;
    return kCaptureStopTimedOut;
  }

  try {
    if (impl_->item && impl_->frameToken) {
      // frameToken belongs to the pool which is already closed; revoking the
      // item token is still required so no handler outlives this session.
    }
    if (impl_->item && impl_->closedToken) impl_->item.Closed(impl_->closedToken);
  } catch (winrt::hresult_error const&) {
  }
  impl_->closedToken = {};
  impl_->frameToken = {};
  impl_->item = nullptr;
  impl_->d3dDevice = nullptr;
  // Drained: no handler can be inside these objects any more, so freeing them is safe.
  impl_->ReleaseAll();

  const HRESULT hr = impl_->hr;
  if (FAILED(hr) && impl_->report.failure.empty()) {
    impl_->report.failure = "frame-write-failed";
  }
  // Only now, with the handlers drained and the resources released, is the stop complete.
  impl_->stopHr = hr;
  impl_->stopCompleted = true;
  if (outReport) *outReport = impl_->report;
  return hr;
}

void VideoCapture::Impl::ReleaseAll() {
  Release(staging);
  Release(context);
  Release(device);
}

VideoCapture::VideoCapture() : impl_(new Impl()) {}

VideoCapture::~VideoCapture() {
  if (impl_) {
    // Stop() returns the timeout sentinel exactly when a frame handler is still inside this Impl and
    // its D3D objects, so deleting impl_ here would be a use-after-free. The helper is an isolated
    // child process, so the fail-closed action is to end that process instead of freeing.
    if (Stop(nullptr) == kCaptureStopTimedOut) FailClosedProcess("video-stop");
    delete impl_;
    impl_ = nullptr;
  }
}

}  // namespace qualityav
