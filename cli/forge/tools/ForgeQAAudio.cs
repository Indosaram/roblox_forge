using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

namespace ForgeQAAudio {

[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] public class MMDeviceEnumeratorComObject { }

[Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IMMDeviceEnumerator {
  int EnumAudioEndpoints(int dataFlow, int stateMask, out IntPtr devices);
  int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice ppEndpoint);
  int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice dev);
}

[Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IMMDevice {
  int Activate(ref Guid iid, int dwClsCtx, IntPtr pActivationParams, [MarshalAs(UnmanagedType.IUnknown)] out object ppInterface);
  int OpenPropertyStore(int stgmAccess, out IntPtr props);
  int GetId([MarshalAs(UnmanagedType.LPWStr)] out string ppstrId);
  int GetState(out int pdwState);
}

[Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IAudioClient {
  int Initialize(int shareMode, int streamFlags, long hnsBufferDuration, long hnsPeriodicity, IntPtr pFormat, IntPtr audioSessionGuid);
  int GetBufferSize(out uint numBufferFrames);
  int GetStreamLatency(out long latency);
  int GetCurrentPadding(out uint numPaddingFrames);
  int IsFormatSupported(int shareMode, IntPtr pFormat, out IntPtr closestMatch);
  int GetMixFormat(out IntPtr deviceFormat);
  int GetDevicePeriod(out long defaultPeriod, out long minimumPeriod);
  int Start();
  int Stop();
  int Reset();
  int SetEventHandle(IntPtr eventHandle);
  int GetService(ref Guid riid, [MarshalAs(UnmanagedType.IUnknown)] out object ppv);
}

[Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD317"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IAudioCaptureClient {
  int GetBuffer(out IntPtr data, out uint numFramesToRead, out uint flags, out ulong devicePosition, out ulong qpcPosition);
  int ReleaseBuffer(uint numFramesRead);
  int GetNextPacketSize(out uint numFramesInNextPacket);
}

[Guid("F294ACFC-3146-4483-A7BF-ADDCA7C260E2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IAudioRenderClient {
  int GetBuffer(uint numFramesRequested, out IntPtr data);
  int ReleaseBuffer(uint numFramesWritten, uint flags);
}

public static class Loopback {
  const int SHARE = 0;
  const int LOOPBACK = 0x00020000;
  const int EVENTCALLBACK = 0x00040000;

  static void Chk(int hr, string what) { if (hr != 0) throw new Exception(what + " failed hr=0x" + hr.ToString("X8")); }

  // returns a log string; writes a 16-bit PCM wav to outPath
  public static string Capture(string outPath, int captureMs, string readyPath, string cancelEventName) {
    if (captureMs < 1 || captureMs > 600000) throw new ArgumentOutOfRangeException("captureMs");
    bool playTone = false; double toneHz = 0, amp = 0;
    IMMDeviceEnumerator en = null; IMMDevice dev = null;
    IAudioClient capClient = null, renClient = null;
    IAudioCaptureClient cap = null; IAudioRenderClient ren = null;
    IntPtr pFmt = IntPtr.Zero;
    AutoResetEvent evt = null;
    EventWaitHandle cancel = null;
    MemoryStream pcm = null;
    bool capStarted = false, renStarted = false;
    try {
    bool created;
    cancel = new EventWaitHandle(false, EventResetMode.ManualReset, cancelEventName, out created);
    if (!created) throw new InvalidOperationException("Cancellation event already exists");
    var log = new System.Text.StringBuilder();
    en = (IMMDeviceEnumerator)(new MMDeviceEnumeratorComObject());
    Chk(en.GetDefaultAudioEndpoint(0, 0, out dev), "GetDefaultAudioEndpoint");
    string devId; dev.GetId(out devId);
    log.AppendLine("device=" + devId);

    Guid IID_IAudioClient = new Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2");
    object o;
    Chk(dev.Activate(ref IID_IAudioClient, 1, IntPtr.Zero, out o), "Activate capture client");
    capClient = (IAudioClient)o;

    Chk(capClient.GetMixFormat(out pFmt), "GetMixFormat");
    short wFormatTag   = Marshal.ReadInt16(pFmt, 0);
    short nChannels    = Marshal.ReadInt16(pFmt, 2);
    int   nSamplesPerSec = Marshal.ReadInt32(pFmt, 4);
    short nBlockAlign  = Marshal.ReadInt16(pFmt, 12);
    short wBits        = Marshal.ReadInt16(pFmt, 14);
    log.AppendLine("mixformat tag=" + wFormatTag + " ch=" + nChannels + " rate=" + nSamplesPerSec + " bits=" + wBits + " blockAlign=" + nBlockAlign);

    // capture (loopback) client - 500ms buffer
    Chk(capClient.Initialize(SHARE, LOOPBACK, 5000000, 0, pFmt, IntPtr.Zero), "capture Initialize(LOOPBACK)");
    Guid IID_ICap = new Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD317");
    object oc; Chk(capClient.GetService(ref IID_ICap, out oc), "GetService(IAudioCaptureClient)");
    cap = (IAudioCaptureClient)oc;

    // render client with EVENT callback - this event drives the loop (no polling / no sleeps)
    evt = new AutoResetEvent(false);
    uint renBufFrames = 0;
    object or2;
    Chk(dev.Activate(ref IID_IAudioClient, 1, IntPtr.Zero, out or2), "Activate render client");
    renClient = (IAudioClient)or2;
    Chk(renClient.Initialize(SHARE, EVENTCALLBACK, 2000000, 0, pFmt, IntPtr.Zero), "render Initialize(EVENTCALLBACK)");
    Chk(renClient.SetEventHandle(evt.SafeWaitHandle.DangerousGetHandle()), "SetEventHandle");
    Chk(renClient.GetBufferSize(out renBufFrames), "render GetBufferSize");
    Guid IID_IRen = new Guid("F294ACFC-3146-4483-A7BF-ADDCA7C260E2");
    object orc; Chk(renClient.GetService(ref IID_IRen, out orc), "GetService(IAudioRenderClient)");
    ren = (IAudioRenderClient)orc;
    log.AppendLine("renderBufferFrames=" + renBufFrames + " eventDriven=true");

    pcm = new MemoryStream();
    int targetFrames = (int)((long)nSamplesPerSec * captureMs / 1000);
    int capturedFrames = 0;
    double phase = 0.0;
    double phaseInc = 2.0 * Math.PI * toneHz / nSamplesPerSec;
    bool isFloat = (wFormatTag == -2 /*EXTENSIBLE*/ && wBits == 32) || wFormatTag == 3;

    Chk(capClient.Start(), "capture Start"); capStarted = true;
    Chk(renClient.Start(), "render Start"); renStarted = true;
    if (cancel.WaitOne(0)) throw new OperationCanceledException();
    // Atomic publication: observers never see a partially written READY file.
    string pendingReady = readyPath + ".pending";
    using (var stream = new FileStream(pendingReady, FileMode.CreateNew, FileAccess.Write))
    using (var writer = new StreamWriter(stream)) {
      writer.WriteLine("READY");
      writer.WriteLine("device=" + devId);
      writer.WriteLine("utc=" + DateTime.UtcNow.ToString("O"));
      writer.WriteLine("cancelEvent=" + cancelEventName);
    }
    File.Move(pendingReady, readyPath);
    Console.WriteLine("READY " + readyPath);
    Console.Out.Flush();
    int wakes = 0, silentPackets = 0, dataPackets = 0;
    var deadline = DateTime.UtcNow.AddMilliseconds(captureMs + 4000);
    try {
      while (capturedFrames < targetFrames && DateTime.UtcNow < deadline) {
        // BLOCK on the audio engine's own event - not a sleep, not a poll
        int signal = WaitHandle.WaitAny(new WaitHandle[] { cancel, evt }, 2000);
        if (signal == 0) throw new OperationCanceledException();
        if (signal == WaitHandle.WaitTimeout) throw new TimeoutException("WASAPI event wait timeout");
        wakes++;

        // feed the render buffer (tone or silence)
        uint pad; Chk(renClient.GetCurrentPadding(out pad), "GetCurrentPadding");
        uint free = renBufFrames - pad;
        if (free > 0) {
          IntPtr rbuf;
          if (ren.GetBuffer(free, out rbuf) == 0) {
            if (playTone) {
              for (int f = 0; f < free; f++) {
                double s = Math.Sin(phase) * amp; phase += phaseInc;
                for (int c = 0; c < nChannels; c++) {
                  int off = f * nBlockAlign + c * (wBits / 8);
                  if (isFloat) Marshal.WriteInt32(rbuf, off, BitConverter.ToInt32(BitConverter.GetBytes((float)s), 0));
                  else Marshal.WriteInt16(rbuf, off, (short)(s * 32767));
                }
              }
              ren.ReleaseBuffer(free, 0);
            } else {
              ren.ReleaseBuffer(free, 2 /*AUDCLNT_BUFFERFLAGS_SILENT*/);
            }
          }
        }

        // drain all available loopback packets
        uint packet;
        Chk(cap.GetNextPacketSize(out packet), "GetNextPacketSize");
        while (packet > 0) {
          if (cancel.WaitOne(0)) throw new OperationCanceledException();
          if (DateTime.UtcNow >= deadline) throw new TimeoutException("Capture deadline exceeded");
          IntPtr data; uint frames, flags; ulong dp, qp;
          Chk(cap.GetBuffer(out data, out frames, out flags, out dp, out qp), "capture GetBuffer");
          try {
          bool silent = (flags & 0x2) != 0;
          if (silent) silentPackets++; else dataPackets++;
          int bytes = (int)frames * nBlockAlign;
          byte[] raw = new byte[bytes];
          if (!silent && data != IntPtr.Zero) Marshal.Copy(data, raw, 0, bytes);
          // convert to 16-bit mono-interleaved-as-source-channels PCM
          for (int f = 0; f < frames; f++) {
            for (int c = 0; c < nChannels; c++) {
              int off = f * nBlockAlign + c * (wBits / 8);
              short v;
              if (isFloat) { float fv = BitConverter.ToSingle(raw, off); if (fv > 1f) fv = 1f; if (fv < -1f) fv = -1f; v = (short)(fv * 32767); }
              else v = BitConverter.ToInt16(raw, off);
              pcm.WriteByte((byte)(v & 0xFF)); pcm.WriteByte((byte)((v >> 8) & 0xFF));
            }
          }
          capturedFrames += (int)frames;
          } finally {
            cap.ReleaseBuffer(frames);
          }
          Chk(cap.GetNextPacketSize(out packet), "GetNextPacketSize");
        }
      }
    } finally {
      try { renClient.Stop(); } catch {}
      try { capClient.Stop(); } catch {}
    }
    if (capturedFrames < targetFrames) throw new TimeoutException("Incomplete capture");
    log.AppendLine("wakes=" + wakes + " dataPackets=" + dataPackets + " silentPackets=" + silentPackets + " capturedFrames=" + capturedFrames);

    byte[] pcmBytes = pcm.ToArray();
    WriteWav(outPath, pcmBytes, nChannels, nSamplesPerSec);
    log.AppendLine("wrote=" + outPath + " pcmBytes=" + pcmBytes.Length);

    // waveform stats
    long nonZero = 0; int peak = 0; double sumSq = 0; int samples = pcmBytes.Length / 2;
    for (int i = 0; i < samples; i++) {
      short v = BitConverter.ToInt16(pcmBytes, i * 2);
      if (v != 0) nonZero++;
      int a = Math.Abs((int)v); if (a > peak) peak = a;
      sumSq += (double)v * v;
    }
    double rms = samples > 0 ? Math.Sqrt(sumSq / samples) : 0;
    log.AppendLine("samples=" + samples + " nonZero=" + nonZero + " peak=" + peak + " rms=" + rms.ToString("F2")
      + " peakDbFS=" + (peak > 0 ? (20 * Math.Log10(peak / 32767.0)).ToString("F2") : "-inf")
      + " rmsDbFS=" + (rms > 0 ? (20 * Math.Log10(rms / 32767.0)).ToString("F2") : "-inf"));
    return log.ToString();
    } finally {
      if (renStarted) { try { renClient.Stop(); } catch {} }
      if (capStarted) { try { capClient.Stop(); } catch {} }
      foreach (object resource in new object[] { ren, cap, renClient, capClient, dev, en }) {
        if (resource != null && Marshal.IsComObject(resource)) Marshal.ReleaseComObject(resource);
      }
      if (pFmt != IntPtr.Zero) Marshal.FreeCoTaskMem(pFmt);
      if (evt != null) evt.Dispose();
      if (cancel != null) cancel.Dispose();
      if (pcm != null) pcm.Dispose();
    }
  }

  static void WriteWav(string path, byte[] pcm, int ch, int rate) {
    using (var fs = new FileStream(path, FileMode.CreateNew))
    using (var bw = new BinaryWriter(fs)) {
      int byteRate = rate * ch * 2;
      bw.Write(new char[]{'R','I','F','F'}); bw.Write(36 + pcm.Length);
      bw.Write(new char[]{'W','A','V','E'});
      bw.Write(new char[]{'f','m','t',' '}); bw.Write(16); bw.Write((short)1);
      bw.Write((short)ch); bw.Write(rate); bw.Write(byteRate); bw.Write((short)(ch*2)); bw.Write((short)16);
      bw.Write(new char[]{'d','a','t','a'}); bw.Write(pcm.Length); bw.Write(pcm);
    }
  }
}
}
