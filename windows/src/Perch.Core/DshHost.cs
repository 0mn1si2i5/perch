using System;
using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace Perch.Windows;

public sealed record DshRuntime(string Phase, int HostPid = 0, int ChildPid = 0, long ChildStarted = 0, DshAuthorization? Authorization = null, string Detail = "");

/// One protected descriptor per home; account deletion never deletes a running descriptor.
public sealed class DshState
{
    public string DirectoryPath { get; }
    public string Key { get; }
    public string LaunchPath => Path.Combine(DirectoryPath, "launch.json");
    public string RuntimePath => Path.Combine(DirectoryPath, "runtime.bin");
    public string LockName => "Local\\com.omnis.perch.dsh." + WindowsIdentity.GetCurrent().User!.Value + "." + Key;
    public DshState(string root, string key)
    {
        if (!Regex.IsMatch(key, "^[a-f0-9]{64}$")) throw new IOException("无效的 dsh 实例标识。");
        Key = key;
        DirectoryPath = Path.Combine(Path.GetFullPath(root), "dsh", key);
    }
    public static string ForHome(string home) => Hash("home:" + Path.GetFullPath(home).TrimEnd(Path.DirectorySeparatorChar).ToUpperInvariant());
    public static string ForAccount(string id) => Hash("account:" + id);
    private static string Hash(string value) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value))).ToLowerInvariant();

    public DshRuntime? Read()
    {
        if (!File.Exists(RuntimePath)) return null;
        try
        {
            // The host replaces this descriptor while the panel polls it. Allow that
            // replacement while keeping this reader's already-open revision intact.
            using var file = new FileStream(RuntimePath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            using var encrypted = new MemoryStream();
            file.CopyTo(encrypted);
            var plain = ProtectedData.Unprotect(encrypted.ToArray(), null, DataProtectionScope.CurrentUser);
            try { return JsonSerializer.Deserialize<DshRuntime>(plain, Store.Json); }
            finally { CryptographicOperations.ZeroMemory(plain); }
        }
        catch (Exception e) when (e is CryptographicException or JsonException) { throw new IOException("dsh 连接记录不可读，请重新连接。", e); }
    }

    public void Write(DshRuntime state)
    {
        Store.PrivateDirectory(Path.GetDirectoryName(DirectoryPath)!);
        Store.PrivateDirectory(DirectoryPath);
        var plain = JsonSerializer.SerializeToUtf8Bytes(state, Store.Json);
        var temporary = RuntimePath + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            File.WriteAllBytes(temporary, ProtectedData.Protect(plain, null, DataProtectionScope.CurrentUser));
            File.Move(temporary, RuntimePath, true);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(plain);
            if (File.Exists(temporary)) File.Delete(temporary);
        }
    }

    public static bool ChildAlive(DshRuntime? state)
    {
        if (state == null || state.ChildPid <= 0) return false;
        try
        {
            using var child = Process.GetProcessById(state.ChildPid);
            return !child.HasExited && child.StartTime.ToUniversalTime().Ticks == state.ChildStarted;
        }
        catch (Exception e) when (e is ArgumentException or InvalidOperationException or System.ComponentModel.Win32Exception) { return false; }
    }

    public bool HostAlive()
    {
        using var mutex = new Mutex(false, LockName);
        bool acquired;
        try { acquired = mutex.WaitOne(0); }
        catch (AbandonedMutexException) { acquired = true; }
        if (acquired) mutex.ReleaseMutex();
        return !acquired;
    }
}

/// This mode runs before WPF's single-instance gate and outlives the panel process.
public static class DshHost
{
    public static int Run(string root, string key)
    {
        var state = new DshState(root, key);
        using var lease = new Mutex(false, state.LockName);
        bool acquired;
        try { acquired = lease.WaitOne(0); }
        catch (AbandonedMutexException) { acquired = true; }
        if (!acquired) return 0;
        try { return Serve(state).GetAwaiter().GetResult(); }
        finally { lease.ReleaseMutex(); }
    }

    private static async Task<int> Serve(DshState state)
    {
        Process? child = null;
        DshRuntime runtime = new("starting", Environment.ProcessId, Detail: "dsh 正在启动…");
        try
        {
            if (DshState.ChildAlive(state.Read())) return 0;
            var launch = JsonSerializer.Deserialize<DshLaunch>(File.ReadAllText(state.LaunchPath), Store.Json) ?? throw new IOException("dsh 启动配置不可读。");
            using var stop = new EventWaitHandle(false, EventResetMode.ManualReset, state.LockName + ".stop");
            stop.Reset();
            state.Write(runtime);
            child = Process.Start(launch.StartInfo()) ?? throw new IOException("dsh 启动失败，请检查 Node 和安装目录。");
            runtime = runtime with { ChildPid = child.Id, ChildStarted = child.StartTime.ToUniversalTime().Ticks };
            state.Write(runtime);
            var urlReady = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
            // Never retain raw stdout/stderr: startup output can contain credentials or task text.
            async Task Drain(StreamReader reader, bool announce)
            {
                while (await reader.ReadLineAsync() is { } line)
                    if (announce && line.StartsWith("dsh web: http://", StringComparison.Ordinal))
                    {
                        var candidate = line[9..].Split(' ', 2)[0];
                        try { urlReady.TrySetResult(DshConnection.ValidateUrl(candidate).AbsoluteUri); }
                        catch (IOException) { /* Ignore unrelated/malformed announcements; startup will time out. */ }
                    }
            }
            var stdout = Drain(child.StandardOutput, true);
            var stderr = Drain(child.StandardError, false);
            var exited = child.WaitForExitAsync();
            var stopped = Task.Run(() => stop.WaitOne());
            var first = await Task.WhenAny(urlReady.Task, exited, stopped, Task.Delay(TimeSpan.FromSeconds(60)));
            if (first != urlReady.Task)
            {
                if (!child.HasExited) child.Kill(true);
                stop.Set();
                await exited;
                await Task.WhenAll(stdout, stderr, stopped);
                state.Write(runtime with { Phase = "error", Detail = "dsh 未能启动 Web 服务。请在终端检查构建、Node 版本和 Web profile 配置。" });
                return 1;
            }
            using var connection = new DshConnection(new(await urlReady.Task, ""));
            await connection.Authenticate();
            await connection.Sessions();
            runtime = runtime with { Phase = "ready", Authorization = connection.Authorization, Detail = "" };
            state.Write(runtime);
            if (await Task.WhenAny(exited, stopped) == stopped && !child.HasExited)
                child.Kill(true);
            stop.Set();
            await exited;
            await Task.WhenAll(stdout, stderr, stopped);
            state.Write(runtime with { Phase = "stopped", Detail = "dsh 服务已停止。" });
            return 0;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or System.ComponentModel.Win32Exception or HttpRequestException or OperationCanceledException)
        {
            if (child != null && !child.HasExited) child.Kill(true);
            state.Write(runtime with { Phase = "error", Detail = "dsh 启动或认证失败，请检查安装与 Web profile 后重试。" });
            return 1;
        }
        finally { child?.Dispose(); }
    }
}
