// Media Foundation sink writer that muxes the original captured video and
// audio into one MP4 container. Track indices returned by
// IMFSinkWriter::AddStream are reported verbatim so the caller never guesses
// which stream is which; sample times are QPC-derived 100ns values shared with
// the audio capture timeline.
#pragma once

#include <windows.h>

#include <string>

namespace qualityav {

struct VideoFormatSpec {
  unsigned int width = 0;
  unsigned int height = 0;
  unsigned int fpsNum = 30;
  unsigned int fpsDen = 1;
};

struct AudioFormatSpec {
  unsigned int sampleRate = 0;
  unsigned int channels = 0;
  unsigned int bitsPerSample = 0;
  bool isFloat = false;
  unsigned int blockAlign = 0;
  unsigned int averageBytesPerSecond = 0;
};

struct OriginalFile {
  std::wstring path;
  unsigned long long byteLength = 0;
};

// Bounded record of the first mux step that failed. A bare MF_E_INVALIDMEDIATYPE cannot say which
// stream or which negotiation step produced it, so the failing operation, its HRESULT and the exact
// formats that were offered are kept together for the caller's blocker text.
struct MuxFailure {
  std::string operation;  // startup, create-writer, add-video-stream, set-video-input-type, ...
  long hresult = 0;
  unsigned int videoWidth = 0;
  unsigned int videoHeight = 0;
  unsigned int videoFpsNum = 0;
  unsigned int videoFpsDen = 0;
  unsigned int audioSampleRate = 0;
  unsigned int audioChannels = 0;
  unsigned int audioBitsPerSample = 0;
  unsigned int audioBlockAlign = 0;
};

class MuxWriter {
 public:
  MuxWriter();
  ~MuxWriter();

  MuxWriter(const MuxWriter&) = delete;
  MuxWriter& operator=(const MuxWriter&) = delete;

  // Opens the container for writing. Video stream is added first, then audio,
  // so the reported indices are the container's own stream indices.
  HRESULT Open(const std::wstring& path, const VideoFormatSpec& video, const AudioFormatSpec& audio);

  // bgra rows of rowPitch bytes; pts100ns is on the session QPC timeline.
  HRESULT WriteVideo(const BYTE* bgra, unsigned int rowPitch, long long pts100ns, long long qpcTicks);
  HRESULT WriteAudio(const BYTE* pcm, unsigned int bytes, long long pts100ns, long long qpcTicks);

  // Finalizes the container and measures the original file that was written.
  HRESULT Finish(OriginalFile* out);

  // Releases everything WITHOUT finalizing: a partial container must never be
  // reported to the caller as an original.
  void Abandon();

  bool opened() const;
  unsigned int videoStreamIndex() const;
  unsigned int audioStreamIndex() const;

  // The first failed mux step and the formats offered to it; operation is empty
  // when nothing has failed.
  const MuxFailure& failure() const;

  // PTS provenance retained for the source receipt; -1 until the first sample.
  long long firstVideoPts100ns() const;
  long long lastVideoPts100ns() const;
  long long firstAudioPts100ns() const;
  long long lastAudioPts100ns() const;
  unsigned long long videoSamples() const;
  unsigned long long audioSamples() const;

 private:
  struct Impl;
  Impl* impl_;
};

}  // namespace qualityav
