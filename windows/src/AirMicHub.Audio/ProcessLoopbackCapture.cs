using System.Runtime.InteropServices;
using AirMicHub.Core;

namespace AirMicHub.Audio;

/// <summary>
/// WASAPI process-loopback capture (Windows 10 2004+). Uses
/// ActivateAudioInterfaceAsync with AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK and
/// EXCLUDE_TARGET_PROCESS_TREE so audio rendered by AirMic Hub itself (the vocal monitor)
/// is never captured and never echoed back through the 8787 speaker stream.
///
/// This is an interop-heavy path, so every failure is thrown as a readable exception and
/// the caller falls back to normal device loopback.
/// </summary>
internal sealed class ProcessLoopbackCapture : IDisposable
{
    private const int SampleRate = 48_000;
    private const int Channels = 2;
    private const int BitsPerSample = 32;
    private const string VirtualAudioDeviceProcessLoopback = @"VAD\Process_Loopback";

    private const int AudclntStreamFlagsLoopback = 0x00020000;
    private const int AudclntBufferflagsSilent = 0x00000002;
    private const int WaveFormatExtensibleSize = 40;

    private Thread? _thread;
    private volatile bool _running;
    private TaskCompletionSource<bool>? _started;

    public event Action<float[]>? AudioAvailable;
    public event Action<Exception>? Failed;

    public bool IsCapturing => _running;

    public void Start(uint excludeProcessId)
    {
        if (_running) return;
        _running = true;
        _started = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        _thread = new Thread(() => CaptureThread(excludeProcessId))
        {
            IsBackground = true,
            Name = "AirMicProcessLoopback",
        };
        _thread.SetApartmentState(ApartmentState.MTA);
        _thread.Start();

        if (!_started.Task.Wait(TimeSpan.FromSeconds(8)))
        {
            Stop();
            throw new TimeoutException("进程回环捕获启动超时。");
        }

        if (!_started.Task.Result)
        {
            Stop();
            throw new InvalidOperationException("进程回环捕获初始化失败。");
        }
    }

    private void CaptureThread(uint excludeProcessId)
    {
        IntPtr formatPtr = IntPtr.Zero;
        IntPtr blobPtr = IntPtr.Zero;
        IntPtr propVariantPtr = IntPtr.Zero;
        object? deviceObject = null;
        IAudioClient? audioClient = null;
        IAudioCaptureClient? captureClient = null;
        var comInitialized = false;

        try
        {
            var hrInit = CoInitializeEx(IntPtr.Zero, 0 /* COINIT_MULTITHREADED */);
            comInitialized = hrInit >= 0;

            formatPtr = CreateFloatFormat();
            var activation = new AudioClientActivationParams
            {
                ActivationType = 1, // AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK
                TargetProcessId = excludeProcessId,
                ProcessLoopbackMode = 1, // PROCESS_LOOPBACK_MODE_EXCLUDE_TARGET_PROCESS_TREE
            };

            var activationSize = Marshal.SizeOf<AudioClientActivationParams>();
            blobPtr = Marshal.AllocHGlobal(activationSize);
            Marshal.StructureToPtr(activation, blobPtr, false);

            propVariantPtr = Marshal.AllocHGlobal(Marshal.SizeOf<PropVariantBlob>());
            var propVariant = new PropVariantBlob
            {
                vt = 65, // VT_BLOB
                cbSize = (uint)activationSize,
                pBlobData = blobPtr,
            };
            Marshal.StructureToPtr(propVariant, propVariantPtr, false);

            deviceObject = ActivateProcessLoopback(propVariantPtr);
            audioClient = deviceObject as IAudioClient
                          ?? throw new InvalidCastException("激活结果不是 IAudioClient。");

            var hr = audioClient.Initialize(
                shareMode: 0, // AUDCLNT_SHAREMODE_SHARED
                streamFlags: AudclntStreamFlagsLoopback,
                hnsBufferDuration: 200_000, // 20 ms
                hnsPeriodicity: 0,
                format: formatPtr,
                audioSessionGuid: IntPtr.Zero);
            if (hr < 0) throw new COMException($"IAudioClient.Initialize 失败（0x{hr:X8}）。", hr);

            var captureId = IID_IAudioCaptureClient;
            hr = audioClient.GetService(ref captureId, out var captureObject);
            if (hr < 0) throw new COMException($"获取 IAudioCaptureClient 失败（0x{hr:X8}）。", hr);
            captureClient = (IAudioCaptureClient)captureObject;

            hr = audioClient.Start();
            if (hr < 0) throw new COMException($"启动进程回环捕获失败（0x{hr:X8}）。", hr);

            Log.Info($"进程回环捕获已启动（排除进程 {excludeProcessId} 及其子进程）。");
            _started?.TrySetResult(true);

            var buffer = new float[SampleRate * Channels / 5]; // 200 ms safety cap
            while (_running)
            {
                var gotData = false;
                var hrNext = captureClient.GetNextPacketSize(out var packetFrames);
                while (hrNext >= 0 && packetFrames > 0)
                {
                    gotData = true;
                    var hrBuffer = captureClient.GetBuffer(
                        out var data,
                        out var frames,
                        out var flags,
                        out _,
                        out _);
                    if (hrBuffer < 0) break;

                    var samples = (int)Math.Min(frames * Channels, buffer.Length);
                    if (samples > 0)
                    {
                        if ((flags & AudclntBufferflagsSilent) != 0 || data == IntPtr.Zero)
                        {
                            Array.Clear(buffer, 0, samples);
                        }
                        else
                        {
                            Marshal.Copy(data, buffer, 0, samples);
                        }
                        var chunk = new float[samples];
                        Array.Copy(buffer, chunk, samples);
                        AudioAvailable?.Invoke(chunk);
                    }

                    captureClient.ReleaseBuffer(frames);
                    hrNext = captureClient.GetNextPacketSize(out packetFrames);
                }

                if (!gotData) Thread.Sleep(4);
            }

            try { audioClient.Stop(); } catch { /* shutting down */ }
        }
        catch (Exception ex)
        {
            Log.Warn($"进程回环捕获不可用：{ex.Message}");
            _started?.TrySetResult(false);
            Failed?.Invoke(ex);
        }
        finally
        {
            if (captureClient is not null && Marshal.IsComObject(captureClient))
            {
                try { Marshal.ReleaseComObject(captureClient); } catch { }
            }
            if (audioClient is not null && Marshal.IsComObject(audioClient))
            {
                try { Marshal.ReleaseComObject(audioClient); } catch { }
            }
            if (deviceObject is not null && Marshal.IsComObject(deviceObject))
            {
                try { Marshal.ReleaseComObject(deviceObject); } catch { }
            }
            if (formatPtr != IntPtr.Zero) Marshal.FreeHGlobal(formatPtr);
            if (blobPtr != IntPtr.Zero) Marshal.FreeHGlobal(blobPtr);
            if (propVariantPtr != IntPtr.Zero) Marshal.FreeHGlobal(propVariantPtr);
            if (comInitialized) CoUninitialize();
            _running = false;
        }
    }

    public void Stop()
    {
        _running = false;
        try
        {
            _thread?.Join(TimeSpan.FromSeconds(2));
        }
        catch (Exception ex)
        {
            Log.Warn($"等待进程回环捕获线程退出失败：{ex.Message}");
        }
        _thread = null;
        _started = null;
    }

    public void Dispose() => Stop();

    // ---------------------------------------------------------------- COM interop

    private static object ActivateProcessLoopback(IntPtr propVariantPtr)
    {
        var iid = IID_IAudioClient;
        var handler = new ActivationCompletionHandler();
        var hr = ActivateAudioInterfaceAsync(
            VirtualAudioDeviceProcessLoopback,
            ref iid,
            propVariantPtr,
            handler,
            out var operation);
        if (hr < 0) throw new COMException("ActivateAudioInterfaceAsync 调用失败。", hr);

        try
        {
            if (!handler.Completed.Wait(TimeSpan.FromSeconds(6)))
            {
                throw new TimeoutException("等待音频接口激活超时。");
            }
            if (handler.ActivateResult < 0)
            {
                throw new COMException("音频接口激活被拒绝。", handler.ActivateResult);
            }

            if (handler.DevicePointer == IntPtr.Zero)
            {
                throw new InvalidOperationException("音频接口激活未返回设备指针。");
            }

            var result = Marshal.GetObjectForIUnknown(handler.DevicePointer);
            Marshal.Release(handler.DevicePointer);
            return result;
        }
        finally
        {
            if (operation is not null && Marshal.IsComObject(operation))
            {
                try { Marshal.ReleaseComObject(operation); } catch { }
            }
        }
    }

    private static IntPtr CreateFloatFormat()
    {
        var pointer = Marshal.AllocHGlobal(WaveFormatExtensibleSize);
        Span<byte> buffer = stackalloc byte[WaveFormatExtensibleSize];
        buffer.Clear();
        BitConverter.TryWriteBytes(buffer[0..], (ushort)0xFFFE);          // WAVE_FORMAT_EXTENSIBLE
        BitConverter.TryWriteBytes(buffer[2..], (ushort)Channels);
        BitConverter.TryWriteBytes(buffer[4..], SampleRate);
        BitConverter.TryWriteBytes(buffer[8..], SampleRate * Channels * (BitsPerSample / 8));
        BitConverter.TryWriteBytes(buffer[12..], (ushort)(Channels * (BitsPerSample / 8)));
        BitConverter.TryWriteBytes(buffer[14..], (ushort)BitsPerSample);
        BitConverter.TryWriteBytes(buffer[16..], (ushort)22);             // cbSize
        BitConverter.TryWriteBytes(buffer[18..], (ushort)BitsPerSample);  // wValidBitsPerSample
        BitConverter.TryWriteBytes(buffer[20..], 3);                      // SPEAKER_FRONT_LEFT | RIGHT
        // KSDATAFORMAT_SUBTYPE_IEEE_FLOAT
        buffer[24] = 0x03;
        buffer[26] = 0x00;
        buffer[28] = 0x00;
        buffer[30] = 0x10;
        buffer[32] = 0x80;
        buffer[33] = 0x00;
        buffer[34] = 0x00;
        buffer[35] = 0xAA;
        buffer[36] = 0x00;
        buffer[37] = 0x38;
        buffer[38] = 0x9B;
        buffer[39] = 0x71;
        Marshal.Copy(buffer.ToArray(), 0, pointer, WaveFormatExtensibleSize);
        return pointer;
    }

    private static readonly Guid IID_IAudioClient = new("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2");
    private static readonly Guid IID_IAudioCaptureClient = new("C8ADBD64-E71E-48a0-A4DE-185C395CD317");

    [DllImport("Mmdevapi.dll", ExactSpelling = true)]
    private static extern int ActivateAudioInterfaceAsync(
        [MarshalAs(UnmanagedType.LPWStr)] string deviceInterfacePath,
        ref Guid riid,
        IntPtr activationParams,
        IActivateAudioInterfaceCompletionHandler completionHandler,
        out IActivateAudioInterfaceAsyncOperation operation);

    [DllImport("ole32.dll")]
    private static extern int CoInitializeEx(IntPtr reserved, int coInit);

    [DllImport("ole32.dll")]
    private static extern void CoUninitialize();

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    private struct AudioClientActivationParams
    {
        public int ActivationType;
        public uint TargetProcessId;
        public int ProcessLoopbackMode;
    }

    [StructLayout(LayoutKind.Explicit, Size = 24)]
    private struct PropVariantBlob
    {
        [FieldOffset(0)] public ushort vt;
        [FieldOffset(8)] public uint cbSize;
        [FieldOffset(16)] public IntPtr pBlobData;
    }

    [ComVisible(true)]
    private sealed class ActivationCompletionHandler : IActivateAudioInterfaceCompletionHandler
    {
        public readonly ManualResetEventSlim Completed = new(false);
        public int ActivateResult;
        public IntPtr DevicePointer;

        public void ActivateCompleted(IActivateAudioInterfaceAsyncOperation operation)
        {
            try
            {
                var hr = operation.GetActivateResult(out var result, out var device);
                ActivateResult = hr;
                DevicePointer = device;
                if (hr < 0 && device != IntPtr.Zero)
                {
                    Marshal.Release(device);
                    DevicePointer = IntPtr.Zero;
                }
            }
            catch (Exception ex)
            {
                ActivateResult = unchecked((int)0x80004005);
                Log.Warn($"激活回调异常：{ex.Message}");
            }
            finally
            {
                Completed.Set();
            }
        }
    }

    [ComImport]
    [Guid("41D949AB-9862-444A-80F6-C261334DA5EB")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IActivateAudioInterfaceCompletionHandler
    {
        void ActivateCompleted(IActivateAudioInterfaceAsyncOperation operation);
    }

    [ComImport]
    [Guid("72A22D78-CDE4-431D-B8CC-843A71199B6D")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IActivateAudioInterfaceAsyncOperation
    {
        [PreserveSig]
        int GetActivateResult(out int activateResult, out IntPtr activatedInterface);
    }

    [ComImport]
    [Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAudioClient
    {
        [PreserveSig] int Initialize(int shareMode, int streamFlags, long hnsBufferDuration, long hnsPeriodicity, IntPtr format, IntPtr audioSessionGuid);
        [PreserveSig] int GetBufferSize(out uint bufferFrames);
        [PreserveSig] int GetStreamLatency(out long latency);
        [PreserveSig] int GetCurrentPadding(out uint paddingFrames);
        [PreserveSig] int IsFormatSupported(int shareMode, IntPtr format, out IntPtr closestMatch);
        [PreserveSig] int GetMixFormat(out IntPtr format);
        [PreserveSig] int GetDevicePeriod(out long defaultPeriod, out long minimumPeriod);
        [PreserveSig] int Start();
        [PreserveSig] int Stop();
        [PreserveSig] int Reset();
        [PreserveSig] int SetEventHandle(IntPtr eventHandle);
        [PreserveSig] int GetService(ref Guid iid, [MarshalAs(UnmanagedType.IUnknown)] out object service);
    }

    [ComImport]
    [Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD317")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAudioCaptureClient
    {
        [PreserveSig] int GetBuffer(out IntPtr data, out uint frames, out uint flags, out ulong devicePosition, out ulong qpcPosition);
        [PreserveSig] int ReleaseBuffer(uint frames);
        [PreserveSig] int GetNextPacketSize(out uint frames);
    }
}
