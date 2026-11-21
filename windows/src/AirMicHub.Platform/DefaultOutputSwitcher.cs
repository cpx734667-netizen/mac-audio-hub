using System.Runtime.InteropServices;
using AirMicHub.Core;
using AirMicHub.Audio;

namespace AirMicHub.Platform;

public sealed record DefaultOutputResult(bool Success, string Message);

/// <summary>
/// Switches the Windows default render device through the undocumented IPolicyConfig COM
/// interface, then verifies the change by reading the default endpoint back. Windows has no
/// stable public API for this; if activation or verification fails we tell the user to
/// switch manually instead of pretending the karaoke output was unified.
/// </summary>
public sealed class DefaultOutputSwitcher
{
    private readonly AudioDeviceService _devices;

    public DefaultOutputSwitcher(AudioDeviceService devices)
    {
        _devices = devices;
    }

    public string? CurrentDefaultDeviceId => _devices.GetDefaultRenderDeviceId();

    /// <summary>True when the undocumented policy COM object can be created (no changes made).</summary>
    public bool IsSupported()
    {
        try
        {
            var policy = (IPolicyConfig)new PolicyConfigClient();
            if (Marshal.IsComObject(policy)) Marshal.ReleaseComObject(policy);
            return true;
        }
        catch (Exception ex)
        {
            Log.Warn($"IPolicyConfig 不可用：{ex.Message}");
            return false;
        }
    }

    public DefaultOutputResult SetDefault(string deviceId)
    {
        if (string.IsNullOrWhiteSpace(deviceId))
        {
            return new DefaultOutputResult(false, "没有选择输出设备。");
        }

        var devices = _devices.GetRenderDevices();
        var target = devices.FirstOrDefault(device =>
            string.Equals(device.Id, deviceId, StringComparison.OrdinalIgnoreCase));
        if (target is null)
        {
            return new DefaultOutputResult(false, "所选输出设备已不存在，请重新选择。");
        }

        try
        {
            var policyConfig = (IPolicyConfig)new PolicyConfigClient();
            var errors = new List<string>();
            foreach (var role in new[] { 0, 1, 2 }) // Console, Multimedia, Communications
            {
                try
                {
                    var hr = policyConfig.SetDefaultEndpoint(deviceId, role);
                    if (hr < 0) errors.Add($"role {role}: 0x{hr:X8}");
                }
                catch (Exception ex)
                {
                    errors.Add($"role {role}: {ex.Message}");
                }
            }

            var actual = _devices.GetDefaultRenderDeviceId();
            if (string.Equals(actual, deviceId, StringComparison.OrdinalIgnoreCase))
            {
                Log.Info($"系统默认输出已切换到：{target.Name}");
                return new DefaultOutputResult(true, $"系统默认输出已切换到「{target.Name}」");
            }

            var detail = errors.Count > 0 ? $"（{string.Join("，", errors)}）" : string.Empty;
            Log.Warn($"系统默认输出切换未生效，当前默认：{actual}{detail}");
            return new DefaultOutputResult(
                false,
                "系统默认输出切换未生效。请打开「声音设置」手动选择同一个音箱。" + detail);
        }
        catch (Exception ex)
        {
            Log.Warn($"IPolicyConfig 不可用：{ex.Message}");
            return new DefaultOutputResult(
                false,
                "Windows 不允许本应用自动切换默认输出。请打开「声音设置」手动把系统默认输出设为同一个音箱。");
        }
    }

    [ComImport]
    [Guid("870af99c-171d-4f9e-af0d-e63df40c2bc9")]
    private class PolicyConfigClient
    {
    }

    [ComImport]
    [Guid("f8679f50-850a-41cf-9c72-430f290290c8")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IPolicyConfig
    {
        [PreserveSig] int GetMixFormat([MarshalAs(UnmanagedType.LPWStr)] string deviceId, out IntPtr format);
        [PreserveSig] int GetDeviceFormat([MarshalAs(UnmanagedType.LPWStr)] string deviceId, int defaultFormat, out IntPtr format);
        [PreserveSig] int ResetDeviceFormat([MarshalAs(UnmanagedType.LPWStr)] string deviceId);
        [PreserveSig] int SetDeviceFormat([MarshalAs(UnmanagedType.LPWStr)] string deviceId, IntPtr endpointFormat, IntPtr mixFormat);
        [PreserveSig] int GetProcessingPeriod([MarshalAs(UnmanagedType.LPWStr)] string deviceId, int defaultPeriod, out long defaultPeriodValue, out long minimumPeriod);
        [PreserveSig] int SetProcessingPeriod([MarshalAs(UnmanagedType.LPWStr)] string deviceId, ref long period);
        [PreserveSig] int GetShareMode([MarshalAs(UnmanagedType.LPWStr)] string deviceId, IntPtr mode);
        [PreserveSig] int SetShareMode([MarshalAs(UnmanagedType.LPWStr)] string deviceId, IntPtr mode);
        [PreserveSig] int GetPropertyValue([MarshalAs(UnmanagedType.LPWStr)] string deviceId, int store, IntPtr key, IntPtr value);
        [PreserveSig] int SetPropertyValue([MarshalAs(UnmanagedType.LPWStr)] string deviceId, int store, IntPtr key, IntPtr value);
        [PreserveSig] int SetDefaultEndpoint([MarshalAs(UnmanagedType.LPWStr)] string deviceId, int role);
        [PreserveSig] int SetEndpointVisibility([MarshalAs(UnmanagedType.LPWStr)] string deviceId, int visible);
    }
}
