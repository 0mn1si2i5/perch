using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Perch.Windows;

internal static class DshServiceCacheTests
{
    public static async Task Run(string root)
    {
        var store = new Store(Path.Combine(root, "dsh connection cache"));
        var account = new Account { App = "dsh", Dsh = new() { Mode = "external" } };
        using var service = new DshService(store);
        await using var first = new WalletServer("12.50");
        await using var second = new WalletServer("48.75");

        await service.Connect(account, first.Url);
        var firstAuthorization = service.State(account).Read()!.Authorization!;
        Check((await service.Balance(account)).Balances?.Single().Amount == 12.50m, "The first instance's wallet is read through its authenticated RPC connection");
        first.FailBalance = true;
        var retained = await service.Balance(account);
        Check(retained.Cached && retained.Balances?.Single().Amount == 12.50m, "A temporary failure on the same connection keeps its own last successful wallet");

        second.FailBalance = true;
        await service.Connect(account, second.Url);
        var reconnected = await service.Balance(account);
        Check(reconnected.Balances == null && !reconnected.Cached, "A successful reconnect must not reuse a different instance's wallet when the new wallet fails");

        second.FailBalance = false;
        Check((await service.Balance(account)).Balances?.Single().Amount == 48.75m, "The new instance can establish its own wallet cache");
        // A background host can replace its descriptor without the panel calling Connect.
        service.State(account).Write(new("ready", Authorization: firstAuthorization));
        var replaced = await service.Balance(account);
        Check(replaced.Balances == null && !replaced.Cached, "A descriptor authorization change must invalidate the previous instance's wallet too");

        var managed = new Account { App = "dsh", ProfilePath = Path.Combine(root, "managed reconnect home"), Dsh = new() { Mode = "npm" } };
        var beforeAuthentication = second.AuthenticationRequests;
        await Refuses(() => service.Connect(managed, second.Url), "An untracked service must not be attached as a managed child");
        Check(service.State(managed).Read() == null && second.AuthenticationRequests == beforeAuthentication,
            "Reject an untracked managed reconnect before authenticating or writing a launchable descriptor");
        using var current = Process.GetCurrentProcess();
        var managedRuntime = new DshRuntime("ready", ChildPid: current.Id, ChildStarted: current.StartTime.ToUniversalTime().Ticks, Authorization: firstAuthorization);
        service.State(managed).Write(managedRuntime);
        await Refuses(() => service.Connect(managed, second.Url), "A managed reconnect cannot switch to another service origin");
        Check(service.State(managed).Read() == managedRuntime && second.AuthenticationRequests == beforeAuthentication,
            "A rejected origin must preserve the owned process and authorization without contacting the other service");
        await service.Connect(managed, first.Url);
        Check(service.State(managed).Read()?.ChildPid == current.Id, "Same-origin managed reauthentication preserves process ownership");

        await service.Connect(account, second.Url);
        var quotas = new QuotaService(new Clients(), service);
        await quotas.Refresh(account, false);
        var automaticRequests = second.BalanceRequests;
        await quotas.Refresh(account, false);
        Check(second.BalanceRequests == automaticRequests, "Automatic polling must respect the dsh billing cache");
        await quotas.Refresh(account, true);
        Check(second.BalanceRequests == automaticRequests + 1, "A manual refresh must bypass the billing cache");
        second.FailBalance = true;
        await quotas.Refresh(account, true);
        var failedRequests = second.BalanceRequests;
        Check(quotas.Get(account.Id)?.Cached == true, "The failed same-instance wallet refresh retains its cached result");
        await quotas.Refresh(account, false);
        Check(second.BalanceRequests == failedRequests, "Automatic polling must still wait thirty seconds after a failed wallet query");
        Console.WriteLine("PASS: dsh cache isolation, managed reconnect ownership and automatic/manual wallet refresh");
    }

    private static void Check(bool value, string why) { if (!value) throw new Exception(why); }
    private static async Task Refuses(Func<Task> action, string why)
    {
        try { await action(); }
        catch (IOException) { return; }
        throw new Exception(why);
    }

    // Plain loopback TCP avoids HttpListener URL reservations and any external service.
    private sealed class WalletServer : IAsyncDisposable
    {
        private readonly TcpListener listener = new(IPAddress.Loopback, 0);
        private readonly CancellationTokenSource stopping = new();
        private readonly Task serving;
        private readonly string balance;
        private int authenticationRequests, balanceRequests;
        public volatile bool FailBalance;
        public int AuthenticationRequests => Volatile.Read(ref authenticationRequests);
        public int BalanceRequests => Volatile.Read(ref balanceRequests);
        public string Url { get; }

        public WalletServer(string balance)
        {
            this.balance = balance;
            listener.Start();
            Url = $"http://127.0.0.1:{((IPEndPoint)listener.LocalEndpoint).Port}/?token=cache-test";
            serving = Serve();
        }

        private async Task Serve()
        {
            try
            {
                while (!stopping.IsCancellationRequested)
                {
                    using var client = await listener.AcceptTcpClientAsync(stopping.Token);
                    using var stream = client.GetStream();
                    using var reader = new StreamReader(stream, Encoding.UTF8, false, 1024, true);
                    var request = await reader.ReadLineAsync(stopping.Token) ?? "";
                    var length = 0;
                    var cookie = false;
                    while (await reader.ReadLineAsync(stopping.Token) is { Length: > 0 } header)
                    {
                        if (header.StartsWith("Content-Length:", StringComparison.OrdinalIgnoreCase)) length = int.Parse(header[15..].Trim());
                        if (header.StartsWith("Cookie:", StringComparison.OrdinalIgnoreCase)) cookie = header.Contains("dsh-test=cache-test", StringComparison.Ordinal);
                    }
                    var status = "200 OK";
                    var extra = "";
                    var response = "";
                    if (request.StartsWith("GET /?token=cache-test ", StringComparison.Ordinal))
                    {
                        Interlocked.Increment(ref authenticationRequests);
                        status = "303 See Other";
                        extra = "Set-Cookie: dsh-test=cache-test; Path=/; HttpOnly\r\nLocation: /\r\n";
                    }
                    else if (!cookie) status = "401 Unauthorized";
                    else
                    {
                        var chars = new char[length];
                        if (await reader.ReadBlockAsync(chars.AsMemory(), stopping.Token) != length) throw new IOException("Incomplete test RPC request");
                        using var input = JsonDocument.Parse(new string(chars));
                        var method = input.RootElement.Text("method");
                        if (method == "account/getBalance") Interlocked.Increment(ref balanceRequests);
                        object value = method switch
                        {
                            "session/list" => new { items = Array.Empty<object>() },
                            "session/modelCatalog" => new { @default = new { provider = "deepseek-account" } },
                            "account/getState" => new { status = "credential-stored" },
                            "account/getBalance" => new { status = "ready", value = new[] { new { currency = "CNY", balance } }, bonusWallets = Array.Empty<object>() },
                            _ => throw new IOException("Unexpected test RPC " + method)
                        };
                        response = JsonSerializer.Serialize(new { type = "server-response", rpcId = input.RootElement.Text("rpcId"), result = new { ok = !(FailBalance && method == "account/getBalance"), value } });
                    }
                    var body = Encoding.UTF8.GetBytes(response);
                    var headers = Encoding.ASCII.GetBytes($"HTTP/1.1 {status}\r\n{extra}Content-Type: application/json\r\nContent-Length: {body.Length}\r\nConnection: close\r\n\r\n");
                    await stream.WriteAsync(headers, stopping.Token);
                    await stream.WriteAsync(body, stopping.Token);
                }
            }
            catch (Exception e) when (stopping.IsCancellationRequested && e is OperationCanceledException or SocketException or IOException) { }
        }

        public async ValueTask DisposeAsync()
        {
            stopping.Cancel();
            listener.Stop();
            try { await serving; }
            finally { stopping.Dispose(); }
        }
    }
}
