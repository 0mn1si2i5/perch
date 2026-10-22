using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace Perch.Windows;

public static class Processes
{
    [StructLayout(LayoutKind.Sequential)]
    private struct UnicodeString
    {
        public ushort Length;
        public ushort MaximumLength;
        public nint Buffer;
    }

    /// Reads ChatGPT and Claude processes. A process whose path or command line cannot be read
    /// marks the scan incomplete instead of disappearing from it; one that exited meanwhile does not.
    public static ProcessScan Scan()
    {
        var results = new List<Running>();
        bool complete = true;
        foreach (var name in new[]
        {
            "ChatGPT",
            "Claude"
        }

        )
        {
            Process[] processes;
            try
            {
                processes = Process.GetProcessesByName(name);
            }
            catch (Exception e) when (e is System.ComponentModel.Win32Exception or InvalidOperationException)
            {
                complete = false;
                continue;
            }

            foreach (var process in processes)
            {
                using (process)
                {
                    // PROCESS_QUERY_LIMITED_INFORMATION also opens clients started as administrator.
                    var handle = OpenProcess(0x1000, false, process.Id);
                    if (handle == 0)
                    {
                        if (Marshal.GetLastPInvokeError() != 87)
                            complete = false;
                        continue;
                    }

                    try
                    {
                        var executable = ImagePath(handle);
                        var command = CommandLine(handle);
                        if (executable == null || command == null)
                        {
                            if (!Exited(handle))
                                complete = false;
                            continue;
                        }

                        long window = 0;
                        try
                        {
                            window = process.MainWindowHandle.ToInt64();
                        }
                        catch (Exception e) when (e is InvalidOperationException or NotSupportedException)
                        {
                        }

                        results.Add(new Running(process.Id, executable, command, window));
                    }
                    finally
                    {
                        CloseHandle(handle);
                    }
                }
            }
        }

        return new ProcessScan(results, complete);
    }

    private static string? ImagePath(nint handle)
    {
        var buffer = new char[32768];
        int size = buffer.Length;
        return QueryFullProcessImageName(handle, 0, buffer, ref size) ? new string(buffer, 0, size) : null;
    }

    private static bool Exited(nint handle) => GetExitCodeProcess(handle, out var code) && code != 259;

    private static string? CommandLine(nint handle)
    {
        NtQueryInformationProcess(handle, 60, 0, 0, out var length);
        if (length < Marshal.SizeOf<UnicodeString>() || length > 131072)
            return null;
        var buffer = Marshal.AllocHGlobal(length);
        try
        {
            if (NtQueryInformationProcess(handle, 60, buffer, length, out _) != 0)
                return null;
            var value = Marshal.PtrToStructure<UnicodeString>(buffer);
            long start = buffer.ToInt64(), end = start + length, text = value.Buffer.ToInt64();
            if (value.Length % 2 != 0 || text < start || text + value.Length > end)
                return null;
            return Marshal.PtrToStringUni(value.Buffer, value.Length / 2);
        }
        finally
        {
            Marshal.FreeHGlobal(buffer);
        }
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern nint OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern bool QueryFullProcessImageName(nint process, uint flags, char[] name, ref int size);
    [DllImport("kernel32.dll")]
    private static extern bool GetExitCodeProcess(nint process, out uint code);
    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(nint handle);
    [DllImport("ntdll.dll")]
    private static extern int NtQueryInformationProcess(nint process, int information, nint buffer, int size, out int returned);
}