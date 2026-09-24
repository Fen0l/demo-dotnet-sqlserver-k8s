// SqlProbe — minimal ASP.NET Core API that proves a .NET pod on NKP can log in
// to SQL Server, and shows HOW it logged in (KERBEROS / NTLM / SQL).
//
// Configuration (env vars, ASP.NET Core "__" convention):
//   ConnectionStrings__Default   full SqlClient connection string (required)
//   SQLPROBE_TABLE               table used by /db/notes (default: dbo.ProbeNotes)
//   SQLPROBE_DEBUG               true = trace SqlClient internals to the log (with Logging__LogLevel__Default=Debug)
//
// Auth mode is decided by the connection string alone:
//   Integrated Security=true            -> Kerberos via GSSAPI (needs TGT in KRB5CCNAME)
//   User Id=...;Password=...            -> SQL authentication
//
// Endpoints:
//   GET  /healthz       liveness (process only, no DB)
//   GET  /readyz        readiness: opens a DB connection, 503 on failure
//   GET  /db/whoami     login name, auth scheme, server, client IP as seen by SQL
//   GET  /db/notes      list rows written so far
//   POST /db/notes      insert one row {"text": "..."} (proves write access)
//   GET  /krb           Kerberos diagnostics: env + klist output (Linux only)

using System.Diagnostics;
using Microsoft.Data.SqlClient;

var builder = WebApplication.CreateBuilder(args);
builder.Logging.AddSimpleConsole(o => { o.SingleLine = true; o.TimestampFormat = "HH:mm:ss "; });

var app = builder.Build();
var log = app.Logger;

string connStr = builder.Configuration.GetConnectionString("Default")
    ?? BuildConnectionString(builder.Configuration);
string table = builder.Configuration["SQLPROBE_TABLE"] ?? "dbo.ProbeNotes";

var safe = new SqlConnectionStringBuilder(connStr);
log.LogInformation("SqlProbe starting. Server={Server} Database={Db} IntegratedSecurity={Int} Encrypt={Enc} ConnectTimeout={To}s",
    safe.DataSource, safe.InitialCatalog, safe.IntegratedSecurity, safe.Encrypt, safe.ConnectTimeout);

// SQLPROBE_DEBUG=true: forward Microsoft.Data.SqlClient's internal EventSource
// (connection open, pre-login/TLS, login, SSPI/Kerberos) to the console log.
// This is what shows WHERE a connection stalls.
SqlClientTraceListener? trace = null;
if (string.Equals(builder.Configuration["SQLPROBE_DEBUG"], "true", StringComparison.OrdinalIgnoreCase))
{
    trace = new SqlClientTraceListener(log);
    log.LogWarning("SQLPROBE_DEBUG=true — SqlClient EventSource tracing enabled (verbose)");
}

// Try one connection at startup, in the background, so `docker logs` shows the
// outcome and the elapsed time even before anyone calls an endpoint.
_ = Task.Run(async () =>
{
    var sw = Stopwatch.StartNew();
    try
    {
        await using var cn = new SqlConnection(connStr);
        await cn.OpenAsync();
        log.LogInformation("Startup probe: connected to {Server} in {Ms} ms (SQL Server {Ver})", safe.DataSource, sw.ElapsedMilliseconds, cn.ServerVersion);
    }
    catch (Exception ex)
    {
        log.LogError("Startup probe: FAILED after {Ms} ms — {Type}: {Msg}", sw.ElapsedMilliseconds, ex.GetType().Name, ex.Message);
        if (ex.InnerException is not null) log.LogError("  inner: {Type}: {Msg}", ex.InnerException.GetType().Name, ex.InnerException.Message);
    }
});

app.MapGet("/", () => Results.Ok(new
{
    app = "SqlProbe",
    endpoints = new[] { "/healthz", "/readyz", "/db/whoami", "/db/notes", "/krb" },
    server = safe.DataSource,
    database = safe.InitialCatalog,
    integratedSecurity = safe.IntegratedSecurity,
}));

app.MapGet("/healthz", () => Results.Ok(new { status = "ok" }));

app.MapGet("/readyz", async (CancellationToken ct) =>
{
    try
    {
        await using var cn = new SqlConnection(connStr);
        await cn.OpenAsync(ct);
        return Results.Ok(new { status = "ready", serverVersion = cn.ServerVersion });
    }
    catch (Exception ex)
    {
        log.LogWarning(ex, "readyz: SQL connection failed");
        return Results.Json(new { status = "not-ready", error = ex.Message }, statusCode: 503);
    }
});

// The money endpoint. auth_scheme comes from sys.dm_exec_connections and is the
// authoritative proof of Kerberos: "KERBEROS" (good), "NTLM" (Windows clients
// only), "SQL" (SQL auth). Needs VIEW SERVER STATE, granted in ad/03-sql-login.sql.
app.MapGet("/db/whoami", async (CancellationToken ct) =>
{
    const string sql = """
        SELECT
            SUSER_SNAME()                    AS LoginName,
            ORIGINAL_LOGIN()                 AS OriginalLogin,
            USER_NAME()                      AS DatabaseUser,
            DB_NAME()                        AS DatabaseName,
            @@SERVERNAME                     AS ServerName,
            SERVERPROPERTY('MachineName')    AS MachineName,
            CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(64)) AS ProductVersion,
            c.auth_scheme                    AS AuthScheme,
            c.net_transport                  AS NetTransport,
            c.encrypt_option                 AS EncryptOption,
            c.client_net_address             AS ClientNetAddress,
            c.protocol_version               AS TdsProtocolVersion,
            SYSDATETIMEOFFSET()              AS ServerTime
        FROM sys.dm_exec_connections c
        WHERE c.session_id = @@SPID;
        """;
    try
    {
        await using var cn = new SqlConnection(connStr);
        await cn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, cn);
        await using var rd = await cmd.ExecuteReaderAsync(ct);
        if (!await rd.ReadAsync(ct)) return Results.Problem("no row returned");

        var row = new Dictionary<string, object?>();
        for (int i = 0; i < rd.FieldCount; i++)
            row[rd.GetName(i)] = rd.IsDBNull(i) ? null : rd.GetValue(i);
        row["Pod"] = Environment.MachineName;
        return Results.Ok(row);
    }
    catch (SqlException ex)
    {
        log.LogError(ex, "whoami failed");
        return Results.Json(new { error = ex.Message, number = ex.Number, state = ex.State }, statusCode: 502);
    }
    catch (Exception ex)
    {
        log.LogError(ex, "whoami failed");
        return Results.Json(new { error = ex.Message, type = ex.GetType().Name }, statusCode: 502);
    }
});

// Proves write access. Table is created on first use (needs CREATE TABLE => db_ddladmin).
string ensureTableSql = $"""
    IF OBJECT_ID(N'{table}', N'U') IS NULL
        CREATE TABLE {table} (
            Id        int IDENTITY(1,1) PRIMARY KEY,
            Pod       nvarchar(128)  NOT NULL,
            LoginName nvarchar(256)  NOT NULL,
            Note      nvarchar(1024) NOT NULL,
            CreatedAt datetime2      NOT NULL DEFAULT SYSUTCDATETIME()
        );
    """;

app.MapGet("/db/notes", async (CancellationToken ct) =>
{
    try
    {
        await using var cn = new SqlConnection(connStr);
        await cn.OpenAsync(ct);
        await using (var ensure = new SqlCommand(ensureTableSql, cn)) await ensure.ExecuteNonQueryAsync(ct);

        await using var cmd = new SqlCommand($"SELECT TOP 50 Id, Pod, LoginName, Note, CreatedAt FROM {table} ORDER BY Id DESC", cn);
        await using var rd = await cmd.ExecuteReaderAsync(ct);
        var rows = new List<object>();
        while (await rd.ReadAsync(ct))
            rows.Add(new { id = rd.GetInt32(0), pod = rd.GetString(1), login = rd.GetString(2), note = rd.GetString(3), createdAt = rd.GetDateTime(4) });
        return Results.Ok(rows);
    }
    catch (Exception ex)
    {
        log.LogError(ex, "notes list failed");
        return Results.Json(new { error = ex.Message }, statusCode: 502);
    }
});

app.MapPost("/db/notes", async (NoteRequest? body, CancellationToken ct) =>
{
    string note = string.IsNullOrWhiteSpace(body?.Text) ? $"hello from {Environment.MachineName} at {DateTime.UtcNow:O}" : body!.Text!;
    try
    {
        await using var cn = new SqlConnection(connStr);
        await cn.OpenAsync(ct);
        await using (var ensure = new SqlCommand(ensureTableSql, cn)) await ensure.ExecuteNonQueryAsync(ct);

        await using var cmd = new SqlCommand(
            $"INSERT INTO {table} (Pod, LoginName, Note) OUTPUT INSERTED.Id VALUES (@pod, SUSER_SNAME(), @note)", cn);
        cmd.Parameters.AddWithValue("@pod", Environment.MachineName);
        cmd.Parameters.AddWithValue("@note", note);
        var id = (int)(await cmd.ExecuteScalarAsync(ct))!;
        return Results.Created($"/db/notes/{id}", new { id, note });
    }
    catch (Exception ex)
    {
        log.LogError(ex, "notes insert failed");
        return Results.Json(new { error = ex.Message }, statusCode: 502);
    }
});

// Kerberos diagnostics: what the app process sees. Useful when /db/whoami fails
// with "GSSAPI ... No credentials cache found" or "Server not found in Kerberos database".
app.MapGet("/krb", async (CancellationToken ct) =>
{
    var env = new Dictionary<string, string?>
    {
        ["KRB5CCNAME"] = Environment.GetEnvironmentVariable("KRB5CCNAME"),
        ["KRB5_CONFIG"] = Environment.GetEnvironmentVariable("KRB5_CONFIG"),
        ["KRB5_TRACE"] = Environment.GetEnvironmentVariable("KRB5_TRACE"),
    };
    string klist;
    try
    {
        var psi = new ProcessStartInfo("klist") { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false };
        using var p = Process.Start(psi)!;
        klist = await p.StandardOutput.ReadToEndAsync(ct) + await p.StandardError.ReadToEndAsync(ct);
        await p.WaitForExitAsync(ct);
    }
    catch (Exception ex) { klist = $"klist unavailable: {ex.Message}"; }

    string krb5conf;
    try { krb5conf = await File.ReadAllTextAsync(env["KRB5_CONFIG"] ?? "/etc/krb5.conf", ct); }
    catch (Exception ex) { krb5conf = $"unreadable: {ex.Message}"; }

    return Results.Ok(new { env, klist, krb5conf });
});

app.Run();

// Kustomize-friendly alternative to ConnectionStrings__Default: plain env vars.
//   SQLPROBE_SERVER    host[,port]  — MUST be the FQDN for Kerberos (SPN = MSSQLSvc/<fqdn>:<port>)
//   SQLPROBE_DATABASE  database     (default: master)
//   SQLPROBE_AUTH      integrated | sql   (default: integrated)
//   SQLPROBE_USER / SQLPROBE_PASSWORD     (sql only)
//   SQLPROBE_SPN       optional explicit "Server SPN" override
//   SQLPROBE_TRUST_SERVER_CERT  true|false (default true; lab SQL usually has a self-signed cert)
static string BuildConnectionString(IConfiguration cfg)
{
    string server = cfg["SQLPROBE_SERVER"]
        ?? throw new InvalidOperationException("Set ConnectionStrings__Default or SQLPROBE_SERVER");
    var b = new SqlConnectionStringBuilder
    {
        DataSource = server,
        InitialCatalog = cfg["SQLPROBE_DATABASE"] ?? "master",
        Encrypt = SqlConnectionEncryptOption.Mandatory,
        TrustServerCertificate = !string.Equals(cfg["SQLPROBE_TRUST_SERVER_CERT"], "false", StringComparison.OrdinalIgnoreCase),
        ConnectTimeout = 15,
        ApplicationName = "SqlProbe",
    };
    if (string.Equals(cfg["SQLPROBE_AUTH"] ?? "integrated", "sql", StringComparison.OrdinalIgnoreCase))
    {
        b.UserID = cfg["SQLPROBE_USER"] ?? throw new InvalidOperationException("SQLPROBE_USER required for SQLPROBE_AUTH=sql");
        b.Password = cfg["SQLPROBE_PASSWORD"] ?? throw new InvalidOperationException("SQLPROBE_PASSWORD required for SQLPROBE_AUTH=sql");
    }
    else
    {
        b.IntegratedSecurity = true;
    }
    if (cfg["SQLPROBE_SPN"] is { Length: > 0 } spn) b.ServerSPN = spn;
    return b.ConnectionString;
}

record NoteRequest(string? Text);

// Bridges Microsoft.Data.SqlClient.EventSource -> ILogger. Keywords: 1=ExecutionTrace,
// 2=Trace, 4=Scope, 8=NotificationTrace, ..., 0x40=AdvancedTrace, 0x100=Correlation,
// 0x200=StateDump, 0x400=SNITrace (network/TDS layer), 0x800=SNIScope.
sealed class SqlClientTraceListener : System.Diagnostics.Tracing.EventListener
{
    private readonly ILogger _log;
    public SqlClientTraceListener(ILogger log) => _log = log;

    protected override void OnEventSourceCreated(System.Diagnostics.Tracing.EventSource source)
    {
        if (source.Name == "Microsoft.Data.SqlClient.EventSource")
            EnableEvents(source, System.Diagnostics.Tracing.EventLevel.Verbose,
                (System.Diagnostics.Tracing.EventKeywords)(1 | 2 | 0x40 | 0x400));
    }

    protected override void OnEventWritten(System.Diagnostics.Tracing.EventWrittenEventArgs e)
    {
        if (e.Payload is { Count: > 0 })
            _log.LogDebug("[SqlClient:{Event}] {Payload}", e.EventName, string.Join(" | ", e.Payload));
    }
}
