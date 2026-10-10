#include "mux_writer.h"

#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>

#include <cstring>
#include <mutex>
#include <vector>

namespace qualityav {
namespace {

template <typename T>
void Release(T*& value) {
  if (value) {
    value->Release();
    value = nullptr;
  }
}

HRESULT SetVideoType(IMFMediaType* type, const VideoFormatSpec& video) {
  HRESULT hr = type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  if (SUCCEEDED(hr)) hr = type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264);
  if (SUCCEEDED(hr)) hr = type->SetUINT32(MF_MT_AVG_BITRATE, video.width * video.height * video.fpsNum /
                                                                (video.fpsDen * 4));
  if (SUCCEEDED(hr)) hr = type->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
  if (SUCCEEDED(hr)) hr = MFSetAttributeRatio(type, MF_MT_FRAME_RATE, video.fpsNum, video.fpsDen);
  if (SUCCEEDED(hr)) hr = MFSetAttributeSize(type, MF_MT_FRAME_SIZE, video.width, video.height);
  return hr;
}

HRESULT SetRgbInputType(IMFMediaType* type, const VideoFormatSpec& video) {
  HRESULT hr = type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  if (SUCCEEDED(hr)) hr = type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32);
  if (SUCCEEDED(hr)) hr = type->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
  if (SUCCEEDED(hr)) hr = MFSetAttributeRatio(type, MF_MT_FRAME_RATE, video.fpsNum, video.fpsDen);
  if (SUCCEEDED(hr)) hr = MFSetAttributeSize(type, MF_MT_FRAME_SIZE, video.width, video.height);
  // BGRA is 4 bytes per pixel and the capture copy is tightly packed per row.
  if (SUCCEEDED(hr)) hr = type->SetUINT32(MF_MT_DEFAULT_STRIDE, video.width * 4);
  return hr;
}

HRESULT SetAacTargetType(IMFMediaType* type, const AudioFormatSpec& audio) {
  HRESULT hr = type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
  if (SUCCEEDED(hr)) hr = type->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_AAC);
  if (SUCCEEDED(hr)) hr = type->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, audio.sampleRate);
  if (SUCCEEDED(hr)) hr = type->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, audio.channels);
  if (SUCCEEDED(hr)) hr = type->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
  if (SUCCEEDED(hr)) hr = type->SetUINT32(MF_MT_AVG_BITRATE, 128000);
  if (SUCCEEDED(hr)) hr = type->SetUINT32(MF_MT_AAC_PAYLOAD_TYPE, 0);  // 0 = raw AAC in the container
  return hr;
}

HRESULT SetPcmInputType(IMFMediaType* type, const AudioFormatSpec& audio) {
  HRESULT hr = type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
  if (SUCCEEDED(hr)) hr = type->SetGUID(MF_MT_SUBTYPE, audio.isFloat ? MFAudioFormat_Float : MFAudioFormat_PCM);
  if (SUCCEEDED(hr)) hr = type->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, audio.sampleRate);
  if (SUCCEEDED(hr)) hr = type->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, audio.channels);
  if (SUCCEEDED(hr)) hr = type->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, audio.bitsPerSample);
  if (SUCCEEDED(hr)) hr = type->SetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT, audio.blockAlign);
  if (SUCCEEDED(hr)) hr = type->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, audio.averageBytesPerSecond);
  if (SUCCEEDED(hr)) hr = type->SetUINT32(MF_MT_ALL_SAMPLES_INDEPENDENT, FALSE);
  return hr;
}

}  // namespace

struct MuxWriter::Impl {
  // The sink writer is called from two independent threads: the Windows.Graphics.Capture frame-pool
  // callback (WriteVideo) and the audio capture loop (WriteAudio). Media Foundation documents that
  // WriteSample blocks the calling thread by default to limit the data rate, and it documents no
  // concurrency guarantee for IMFSinkWriter, so the two writers are serialized explicitly rather than
  // relying on an unstated one. This mutex is held only by the writers.
  //
  // Finish() and Abandon() deliberately do NOT take it. Both are reached only after video_.Stop() and
  // audio_.Stop() have returned, i.e. when no writer can still be running; taking the lock there would
  // add nothing and would deadlock against a writer blocked inside WriteSample.
  std::mutex mutex;
  IMFSinkWriter* writer = nullptr;
  bool startupDone = false;
  bool writing = false;
  bool finished = false;
  std::wstring path;
  VideoFormatSpec video{};
  AudioFormatSpec audio{};
  DWORD videoIndex = 0;
  DWORD audioIndex = 0;
  long long firstVideoPts = -1, lastVideoPts = -1;
  long long firstAudioPts = -1, lastAudioPts = -1;
  unsigned long long videoSamples = 0, audioSamples = 0;
  // The first step that failed, with the formats that were offered to it.
  MuxFailure failure{};
};

MuxWriter::MuxWriter() : impl_(new Impl()) {}

MuxWriter::~MuxWriter() {
  if (impl_) {
    Release(impl_->writer);
    if (impl_->startupDone) ::MFShutdown();
    delete impl_;
    impl_ = nullptr;
  }
}

HRESULT MuxWriter::Open(const std::wstring& path, const VideoFormatSpec& video,
                        const AudioFormatSpec& audio) {
  if (!impl_ || path.empty()) return E_INVALIDARG;
  if (::GetFileAttributesW(path.c_str()) != INVALID_FILE_ATTRIBUTES)
    return HRESULT_FROM_WIN32(ERROR_FILE_EXISTS);
  if (impl_->writer) return E_UNEXPECTED;
  if (video.width == 0 || video.height == 0 || audio.sampleRate == 0 || audio.channels == 0 ||
      audio.blockAlign == 0) {
    return E_INVALIDARG;
  }

  impl_->video = video;
  impl_->audio = audio;

  // Every negotiation step is recorded on failure together with the formats that were offered, so an
  // MF_E_INVALIDMEDIATYPE names the stream and the step instead of being a bare HRESULT.
  auto step = [this](const char* operation, HRESULT result) {
    if (FAILED(result) && impl_->failure.operation.empty()) {
      impl_->failure.operation = operation;
      impl_->failure.hresult = static_cast<long>(result);
      impl_->failure.videoWidth = impl_->video.width;
      impl_->failure.videoHeight = impl_->video.height;
      impl_->failure.videoFpsNum = impl_->video.fpsNum;
      impl_->failure.videoFpsDen = impl_->video.fpsDen;
      impl_->failure.audioSampleRate = impl_->audio.sampleRate;
      impl_->failure.audioChannels = impl_->audio.channels;
      impl_->failure.audioBitsPerSample = impl_->audio.bitsPerSample;
      impl_->failure.audioBlockAlign = impl_->audio.blockAlign;
    }
    return result;
  };

  HRESULT hr = step("mf-startup", ::MFStartup(MF_VERSION, MFSTARTUP_FULL));
  if (FAILED(hr)) return hr;
  impl_->startupDone = true;

  hr = step("create-sink-writer",
            ::MFCreateSinkWriterFromURL(path.c_str(), nullptr, nullptr, &impl_->writer));
  if (FAILED(hr)) return hr;
  impl_->path = path;

  IMFMediaType* videoTarget = nullptr;
  IMFMediaType* videoInput = nullptr;
  IMFMediaType* audioTarget = nullptr;
  IMFMediaType* audioInput = nullptr;

  if (SUCCEEDED(hr)) hr = step("create-video-target", ::MFCreateMediaType(&videoTarget));
  if (SUCCEEDED(hr)) hr = step("set-video-target", SetVideoType(videoTarget, video));
  if (SUCCEEDED(hr)) hr = step("add-video-stream", impl_->writer->AddStream(videoTarget, &impl_->videoIndex));
  if (SUCCEEDED(hr)) hr = step("create-video-input", ::MFCreateMediaType(&videoInput));
  if (SUCCEEDED(hr)) hr = step("set-video-input", SetRgbInputType(videoInput, video));
  if (SUCCEEDED(hr))
    hr = step("set-video-input-type",
              impl_->writer->SetInputMediaType(impl_->videoIndex, videoInput, nullptr));

  if (SUCCEEDED(hr)) hr = step("create-audio-target", ::MFCreateMediaType(&audioTarget));
  if (SUCCEEDED(hr)) hr = step("set-audio-target", SetAacTargetType(audioTarget, audio));
  if (SUCCEEDED(hr)) hr = step("add-audio-stream", impl_->writer->AddStream(audioTarget, &impl_->audioIndex));
  if (SUCCEEDED(hr)) hr = step("create-audio-input", ::MFCreateMediaType(&audioInput));
  if (SUCCEEDED(hr)) hr = step("set-audio-input", SetPcmInputType(audioInput, audio));
  if (SUCCEEDED(hr))
    hr = step("set-audio-input-type",
              impl_->writer->SetInputMediaType(impl_->audioIndex, audioInput, nullptr));

  Release(videoTarget);
  Release(videoInput);
  Release(audioTarget);
  Release(audioInput);
  if (FAILED(hr)) return hr;

  hr = step("begin-writing", impl_->writer->BeginWriting());
  if (SUCCEEDED(hr)) impl_->writing = true;
  return hr;
}

HRESULT MuxWriter::WriteVideo(const BYTE* bgra, unsigned int rowPitch, long long pts100ns,
                              long long qpcTicks) {
  (void)qpcTicks;
  if (!impl_ || !impl_->writing || !bgra || rowPitch == 0) return E_INVALIDARG;
  std::lock_guard<std::mutex> lock(impl_->mutex);
  const UINT32 size = impl_->video.width * impl_->video.height * 4;
  IMFMediaBuffer* buffer = nullptr;
  HRESULT hr = ::MFCreateMemoryBuffer(size, &buffer);
  if (FAILED(hr)) return hr;
  BYTE* target = nullptr;
  DWORD maxLength = 0;
  hr = buffer->Lock(&target, &maxLength, nullptr);
  if (SUCCEEDED(hr)) {
    if (maxLength < size) {
      hr = E_UNEXPECTED;
    } else {
      const UINT32 rowBytes = impl_->video.width * 4;
      for (UINT32 row = 0; row < impl_->video.height; row++) {
        std::memcpy(target + row * rowBytes, bgra + static_cast<size_t>(row) * rowPitch, rowBytes);
      }
      hr = buffer->SetCurrentLength(size);
    }
    buffer->Unlock();
  }
  if (FAILED(hr)) {
    buffer->Release();
    return hr;
  }
  IMFSample* sample = nullptr;
  hr = ::MFCreateSample(&sample);
  if (SUCCEEDED(hr)) {
    hr = sample->AddBuffer(buffer);
    if (SUCCEEDED(hr)) hr = sample->SetSampleTime(pts100ns);
    if (SUCCEEDED(hr)) hr = impl_->writer->WriteSample(impl_->videoIndex, sample);
    if (SUCCEEDED(hr)) {
      if (impl_->firstVideoPts < 0) impl_->firstVideoPts = pts100ns;
      impl_->lastVideoPts = pts100ns;
      impl_->videoSamples++;
    }
    sample->Release();
  }
  buffer->Release();
  return hr;
}

HRESULT MuxWriter::WriteAudio(const BYTE* pcm, unsigned int bytes, long long pts100ns,
                              long long qpcTicks) {
  (void)qpcTicks;
  if (!impl_ || !impl_->writing || !pcm || bytes == 0) return E_INVALIDARG;
  std::lock_guard<std::mutex> lock(impl_->mutex);
  IMFMediaBuffer* buffer = nullptr;
  HRESULT hr = ::MFCreateMemoryBuffer(bytes, &buffer);
  if (FAILED(hr)) return hr;
  BYTE* target = nullptr;
  DWORD maxLength = 0;
  hr = buffer->Lock(&target, &maxLength, nullptr);
  if (SUCCEEDED(hr)) {
    if (maxLength < bytes) {
      hr = E_UNEXPECTED;
    } else {
      std::memcpy(target, pcm, bytes);
      hr = buffer->SetCurrentLength(bytes);
    }
    buffer->Unlock();
  }
  if (FAILED(hr)) {
    buffer->Release();
    return hr;
  }
  IMFSample* sample = nullptr;
  hr = ::MFCreateSample(&sample);
  if (SUCCEEDED(hr)) {
    hr = sample->AddBuffer(buffer);
    if (SUCCEEDED(hr)) hr = sample->SetSampleTime(pts100ns);
    if (SUCCEEDED(hr)) hr = impl_->writer->WriteSample(impl_->audioIndex, sample);
    if (SUCCEEDED(hr)) {
      if (impl_->firstAudioPts < 0) impl_->firstAudioPts = pts100ns;
      impl_->lastAudioPts = pts100ns;
      impl_->audioSamples++;
    }
    sample->Release();
  }
  buffer->Release();
  return hr;
}

HRESULT MuxWriter::Finish(OriginalFile* out) {
  if (!impl_) return E_POINTER;
  if (!impl_ || !impl_->writing) return HRESULT_FROM_WIN32(ERROR_INVALID_STATE);
  // No lock: the callers guarantee both writers have stopped before finalization (see the Impl note).
  HRESULT hr = S_OK;
  if (impl_->writing) {
    hr = impl_->writer->Finalize();
    impl_->writing = false;
  }
  impl_->finished = true;
  Release(impl_->writer);
  if (impl_->startupDone) {
    ::MFShutdown();
    impl_->startupDone = false;
  }
  if (FAILED(hr)) return hr;

  HANDLE file = ::CreateFileW(impl_->path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr,
                              OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return HRESULT_FROM_WIN32(::GetLastError());
  LARGE_INTEGER size{};
  const BOOL ok = ::GetFileSizeEx(file, &size);
  ::CloseHandle(file);
  if (!ok) return HRESULT_FROM_WIN32(::GetLastError());
  if (out) {
    out->path = impl_->path;
    out->byteLength = static_cast<unsigned long long>(size.QuadPart);
  }
  return S_OK;
}

void MuxWriter::Abandon() {
  if (!impl_) return;
  // No lock, for the same reason as Finish: the writers have already stopped when this is called.
  impl_->writing = false;
  Release(impl_->writer);
  if (impl_->startupDone) {
    ::MFShutdown();
    impl_->startupDone = false;
  }
}

bool MuxWriter::opened() const { return impl_ && impl_->writer != nullptr; }

const MuxFailure& MuxWriter::failure() const {
  static const MuxFailure kNone{};
  return impl_ ? impl_->failure : kNone;
}
unsigned int MuxWriter::videoStreamIndex() const { return impl_ ? impl_->videoIndex : 0; }
unsigned int MuxWriter::audioStreamIndex() const { return impl_ ? impl_->audioIndex : 0; }
long long MuxWriter::firstVideoPts100ns() const { return impl_ ? impl_->firstVideoPts : -1; }
long long MuxWriter::lastVideoPts100ns() const { return impl_ ? impl_->lastVideoPts : -1; }
long long MuxWriter::firstAudioPts100ns() const { return impl_ ? impl_->firstAudioPts : -1; }
long long MuxWriter::lastAudioPts100ns() const { return impl_ ? impl_->lastAudioPts : -1; }
unsigned long long MuxWriter::videoSamples() const { return impl_ ? impl_->videoSamples : 0; }
unsigned long long MuxWriter::audioSamples() const { return impl_ ? impl_->audioSamples : 0; }

}  // namespace qualityav
