using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Perch.Windows;

public sealed class DshService(Store store, string? hostExecutable = null) : IDisposable
{
    private sealed class Entry
    {
        public readonly SemaphoreSlim Gate = new(1);
        public DshConnection? Connection;
        public DshAuthorization? Authorization;
        public Snapshot? Snapshot;
        public readonly DshApiBalance Api = new();
        public Quota? OfficialQuota;
    }
    private readonly ConcurrentDictionary<string, Entry> entries = new();
    public DshState State(Account account) => new(store.Root, account.Dsh?.Mode == "external" ? DshState.ForAccount(account.Id) : DshState.ForHome(account.ProfilePath));
    private Entry For(Account account) => entries.GetOrAdd(account.Id, _ => new Entry());

    public async Task Connect(Account account, string url)
    {
        var validated = DshConnection.ValidateUrl(url);
        var entry = For(account);
        await entry.Gate.WaitAsync();
        try
        {
            var state = State(account);
            // External reconnect replaces its authorization even when the old
            // encrypted descriptor is unreadable; it never owns a child process.
            var previous = account.Dsh?.Mode == "external" ? null : state.Read();
            if (account.Dsh?.Mode != "external")
            {
                if (!DshState.ChildAlive(previous) && !state.HostAlive())
                    throw new IOException("这个受管 dsh 服务尚未运行。请打开账号启动服务；连接终端中已有的服务时，请使用“连接已有实例”。");
                if (previous?.Authorization == null)
                    throw new IOException("受管 dsh 尚未取得授权地址，请等待启动完成后重试。");
                var owned = DshConnection.ValidateUrl(previous.Authorization.Url);
                if (!owned.GetLeftPart(UriPartial.Authority).Equals(validated.GetLeftPart(UriPartial.Authority), StringComparison.OrdinalIgnoreCase))
                    throw new IOException("授权 URL 不属于这个受管 dsh 服务。请复制它当前的启动地址；其他服务请使用“连接已有实例”。");
            }
            using var connection = new DshConnection(new(validated.AbsoluteUri, ""));
            await connection.Authenticate();
            var sessions = await connection.Sessions();
            state.Write((previous ?? new DshRuntime("ready")) with { Phase = "ready", Authorization = connection.Authorization, Detail = "" });
            ResetConnection(entry);
            entry.Authorization = connection.Authorization;
            entry.Snapshot = new(true, sessions, "dsh 本机 Web", 0, DateTimeOffset.UtcNow);
        }
        finally { entry.Gate.Release(); }
    }

    public async Task<string> Ensure(Account account)
    {
        var entry = For(account);
        await entry.Gate.WaitAsync();
        try
        {
            var state = State(account);
            var runtime = state.Read();
            if (account.Dsh?.Mode != "external" && !DshState.ChildAlive(runtime) && !state.HostAlive())
            {
                var launch = DshInstallation.Resolve(account);
                Store.PrivateDirectory(Path.GetDirectoryName(state.DirectoryPath)!);
                Store.PrivateDirectory(state.DirectoryPath);
                // This request has paths only. The host can continue after its account is removed.
                File.WriteAllText(state.LaunchPath, JsonSerializer.Serialize(launch, Store.Json));
                var info = new ProcessStartInfo(hostExecutable ?? Environment.ProcessPath ?? throw new IOException("找不到 Perch 后台宿主。")) { UseShellExecute = false, CreateNoWindow = true };
                foreach (var arg in new[] { "--dsh-host", store.Root, state.Key }) info.ArgumentList.Add(arg);
                using var host = Process.Start(info) ?? throw new IOException("无法启动 dsh 后台宿主。");
                var deadline = DateTimeOffset.UtcNow.AddSeconds(70);
                // Ignore an old stopped/error descriptor until this host has acquired the lease.
                while (DateTimeOffset.UtcNow < deadline)
                {
                    runtime = state.Read();
                    if (runtime?.HostPid == host.Id && runtime.Phase == "error") throw new IOException(runtime.Detail);
                    if (runtime?.Phase == "ready" && DshState.ChildAlive(runtime)) break;
                    if (host.HasExited && !state.HostAlive()) throw new IOException("dsh 后台宿主未能启动，请检查安装配置。");
                    await Task.Delay(150);
                }
            }
            else if (account.Dsh?.Mode != "external" && state.HostAlive() && runtime?.Phase == "starting")
            {
                var deadline = DateTimeOffset.UtcNow.AddSeconds(70);
                while (DateTimeOffset.UtcNow < deadline && runtime?.Phase == "starting" && state.HostAlive())
                {
                    await Task.Delay(150);
                    runtime = state.Read();
                }
            }
            if (runtime?.Phase != "ready" || runtime.Authorization == null)
                throw new IOException(runtime?.Detail.Length > 0 ? runtime.Detail : "请重新连接 dsh，粘贴启动输出中的授权 URL。");
            var connection = Connection(entry, runtime);
            var sessions = await connection.Sessions();
            entry.Snapshot = new(true, sessions, "dsh 本机 Web", 0, DateTimeOffset.UtcNow);
            return connection.Authorization.Url;
        }
        finally { entry.Gate.Release(); }
    }

    private static DshConnection Connection(Entry entry, DshRuntime runtime)
    {
        if (runtime.Authorization == null) throw new IOException("请先连接 dsh Web 实例。");
        if (entry.Connection == null || entry.Authorization != runtime.Authorization)
        {
            // A host restart or a replaced descriptor can change the connected
            // instance without going through Connect. Its caches must change too.
            if (entry.Authorization != runtime.Authorization) ResetConnection(entry);
            entry.Connection = new DshConnection(runtime.Authorization);
            entry.Authorization = runtime.Authorization;
        }
        return entry.Connection;
    }

    private static void ResetConnection(Entry entry)
    {
        entry.Connection?.Dispose();
        entry.Connection = null;
        entry.Authorization = null;
        entry.Snapshot = null;
        entry.Api.Clear();
        entry.OfficialQuota = null;
    }

    public async Task<Snapshot> Read(Account account)
    {
        var entry = For(account);
        await entry.Gate.WaitAsync();
        try
        {
            var runtime = State(account).Read();
            if (runtime?.Phase != "ready" || account.Dsh?.Mode != "external" && !DshState.ChildAlive(runtime))
                throw new IOException(runtime?.Phase == "starting" ? "dsh 正在启动…" : runtime?.Phase == "error" ? runtime.Detail : "dsh 尚未连接或服务已停止。");
            var sessions = await Connection(entry, runtime).Sessions();
            var detail = account.Dsh?.Mode != "external" && !State(account).HostAlive() ? "dsh 宿主已退出，服务仍在运行；停止后可重启。" : "dsh 本机 Web";
            return entry.Snapshot = new(true, sessions, detail, 0, DateTimeOffset.UtcNow);
        }
        catch (Exception e) when (e is IOException or HttpRequestException or OperationCanceledException or UnauthorizedAccessException)
        {
            var detail = Failure(e);
            // Keep prior metadata but never present cached task status as live.
            return entry.Snapshot is { } previous ? previous with { Running = false, Cached = true, Detail = detail, Sessions = previous.Sessions.Select(s => s with { Status = "状态未知" }).ToList() }
                : new(false, [], detail, 0, Cached: true);
        }
        finally { entry.Gate.Release(); }
    }

    public async Task<Quota> Balance(Account account, bool manual = false)
    {
        var entry = For(account);
        await entry.Gate.WaitAsync();
        try
        {
            var runtime = State(account).Read();
            if (runtime?.Phase != "ready" || account.Dsh?.Mode != "external" && !DshState.ChildAlive(runtime))
                throw new IOException("dsh 未连接，无法查询余额。");
            var connection = Connection(entry, runtime);
            DshBilling route;
            try { route = await connection.BillingRoute(); }
            catch (Exception e) when (e is IOException or HttpRequestException or OperationCanceledException)
            {
                entry.Api.Clear();
                route = new("模型计费通道查询失败");
            }
            Quota official;
            try { official = entry.OfficialQuota = await connection.OfficialBalance(route.Detail); }
            catch (Exception e) when (e is IOException or HttpRequestException or OperationCanceledException)
            {
                // Keep wallet failures separate from API-key queries.
                official = entry.OfficialQuota is { } previous
                    ? previous with { Cached = true, Detail = route.Detail + "\n官方钱包查询失败，显示上次成功余额" }
                    : new([], DateTimeOffset.UtcNow, route.Detail + "\n官方钱包查询失败");
            }
            var home = account.Dsh?.Mode == "external" ? account.Dsh.BalanceHome : account.ProfilePath;
            var api = await entry.Api.Read(route, home, manual);
            if (api != null)
            {
                // An environment override or model-route change can happen during HTTP too.
                try
                {
                    if (await connection.BillingRoute() != route)
                    {
                        entry.Api.Clear();
                        api = new([], null, "模型或凭据来源已变更，请刷新余额。");
                    }
                }
                catch (Exception e) when (e is IOException or HttpRequestException or OperationCanceledException)
                {
                    entry.Api.Clear();
                    api = new([], null, "无法确认当前计费通道，已清除 API 余额缓存。");
                }
            }
            return official with { ApiBalance = api };
        }
        catch (Exception e) when (e is HttpRequestException or OperationCanceledException) { throw new IOException(Failure(e)); }
        finally { entry.Gate.Release(); }
    }

    public async Task Stop(Account account)
    {
        var entry = For(account);
        await entry.Gate.WaitAsync();
        try
        {
            var state = State(account);
            if (account.Dsh?.Mode == "external")
                state.Write(new("disconnected", Detail: "已断开 dsh 连接。"));
            else if (state.HostAlive())
            {
                if (!EventWaitHandle.TryOpenExisting(state.LockName + ".stop", out var signal))
                    throw new IOException("dsh 正在启动，请稍后重试停止。");
                using (signal) signal.Set();
                var deadline = DateTimeOffset.UtcNow.AddSeconds(10);
                while (state.HostAlive() && DateTimeOffset.UtcNow < deadline) await Task.Delay(100);
                if (state.HostAlive()) throw new IOException("dsh 尚未停止，请稍后重试。");
            }
            else
            {
                var runtime = state.Read();
                if (DshState.ChildAlive(runtime))
                {
                    // Only an explicit stop may terminate an orphaned child we previously launched.
                    using var child = Process.GetProcessById(runtime!.ChildPid);
                    if (child.StartTime.ToUniversalTime().Ticks != runtime.ChildStarted) throw new IOException("dsh 进程已改变，请刷新后重试。");
                    child.Kill(true);
                    await child.WaitForExitAsync();
                    state.Write(runtime with { Phase = "stopped", Authorization = null, Detail = "dsh 服务已停止。" });
                }
            }
            ResetConnection(entry);
        }
        finally { entry.Gate.Release(); }
    }

    private static string Failure(Exception error) => error is OperationCanceledException ? "dsh 查询超时，请检查本机服务。" : error is IOException ? error.Message : "dsh 连接失败，请检查本机服务或重新连接。";
    public void Dispose()
    {
        // Panel shutdown disconnects HTTP only; the independent host keeps tasks alive.
        foreach (var entry in entries.Values) { entry.Connection?.Dispose(); entry.Api.Dispose(); }
    }
}
