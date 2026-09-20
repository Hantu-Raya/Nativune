using System.Diagnostics;
using System.Net;
using System.Net.Http.Headers;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Nativune;

internal static class Program
{
    private static readonly TimeSpan LoginTimeout = TimeSpan.FromMinutes(10);

    public static async Task<int> Main(string[] args)
    {
        try
        {
            var options = CommandLine.Parse(args);
            if (options.Help || options.Command == "help")
            {
                PrintHelp();
                return 0;
            }
            if (options.Command is not ("login" or "library" or "logout" or "self-check" or "media" or "media-control" or "web" or "native-fixture" or "native-interactions"))
                throw new UsageException("Unknown command. Use help for usage.");
            var requiresCredentials = options.Command is not ("web" or "native-fixture" or "native-interactions");
            var root = RootLocator.Resolve(options.Root, requiresCredentials);
            using var cancellation = new CancellationController();
            return options.Command switch
            {
                "login" => await LoginAsync(root, cancellation.Token),
                "library" => await LibraryAsync(root, cancellation.Token),
                "logout" => await LogoutAsync(root, cancellation.Token),
                "self-check" => SelfCheck.Run(root),
                "media" => await MediaProbe.RunAsync(false, cancellation.Token),
                "media-control" => await MediaProbe.RunAsync(true, cancellation.Token),
                "web" => WebHost.Run(root),
                "native-fixture" => NativeFixture.Run(root, measureInteractions: false),
                "native-interactions" => NativeFixture.Run(root, measureInteractions: true),
                _ => throw new UsageException("Unknown command. Use help for usage.")
            };
        }
        catch (UsageException ex)
        {
            Console.Error.WriteLine(ex.Message);
            return 2;
        }
        catch (OperationCanceledException)
        {
            Console.Error.WriteLine("Operation cancelled or timed out.");
            return 130;
        }
        catch (CredentialException ex)
        {
            Console.Error.WriteLine($"Credentials unavailable: {ex.Message}");
            return 3;
        }
        catch (AuthenticationException ex)
        {
            Console.Error.WriteLine($"Authentication failed: {ex.Message}");
            return 4;
        }
        catch (ApiException ex)
        {
            Console.Error.WriteLine($"Library probe failed: {ex.Message}");
            return 5;
        }
        catch (SelfCheckException ex)
        {
            Console.Error.WriteLine($"Self-check failed: {ex.Message}");
            return 6;
        }
        catch (Exception)
        {
            Console.Error.WriteLine("Operation failed.");
            return 1;
        }
    }

    private static async Task<int> LoginAsync(string root, CancellationToken cancellationToken)
    {
        var store = new TokenStore(root);
        if (store.Exists)
            throw new AuthenticationException("An account is already present; run logout before login.");

        var credentials = ClientCredentials.Load(root);
        using var api = new OAuthApi(credentials);
        var token = await LoopbackOAuth.AuthorizeAsync(credentials, api, cancellationToken, LoginTimeout);
        store.Save(token);
        Console.WriteLine("Login complete. One account is stored locally.");
        return 0;
    }

    private static async Task<int> LibraryAsync(string root, CancellationToken cancellationToken)
    {
        var credentials = ClientCredentials.Load(root);
        var store = new TokenStore(root);
        var token = store.Load() ?? throw new CredentialException("No local account; run login first.");
        using var api = new OAuthApi(credentials);

        if (token.AccessTokenExpiresUtc <= DateTimeOffset.UtcNow.AddMinutes(1))
        {
            token = await api.RefreshAsync(token, cancellationToken);
            store.Save(token);
        }

        var channel = await api.GetChannelsAsync(token.AccessToken, cancellationToken);
        PlaylistSummary? playlists;
        try
        {
            playlists = await api.GetOwnedPlaylistsAsync(token.AccessToken, cancellationToken);
        }
        catch (ApiException ex) when (ex.ChannelNotFound)
        {
            playlists = null;
        }
        var liked = await api.GetLikedVideosAsync(token.AccessToken, cancellationToken);

        Console.WriteLine(channel.Count == 0
            ? "Channel: none found (the account has no available channel)."
            : $"Channel: present ({channel.Count} channel(s)).");
        Console.WriteLine(playlists.HasValue ? $"Owned playlists: {playlists.Value.Count}." : "Owned playlists: unavailable (YouTube reports channelNotFound).");
        Console.WriteLine(playlists.HasValue
            ? $"Listen Later playlist: {(playlists.Value.HasExactListenLater ? "found" : "not found")}."
            : "Listen Later playlist: could not be checked without an available channel.");
        Console.WriteLine($"Liked videos: {liked.Count} (API cap 1000; reached={(liked.ReachedApiCap ? "yes" : "no")}).");
        Console.WriteLine("Requested scope: youtube.readonly.");
        Console.WriteLine("Third-party playlist parity: not provided by this probe.");
        return 0;
    }

    private static async Task<int> LogoutAsync(string root, CancellationToken cancellationToken)
    {
        var store = new TokenStore(root);
        if (!store.Exists)
        {
            Console.WriteLine("No local account was present.");
            return 0;
        }

        var revoked = true;
        var cancelled = false;
        StoredTokens? token = null;
        try
        {
            token = store.Load();
        }
        catch (CredentialException)
        {
            revoked = false;
            Console.Error.WriteLine("Warning: local credentials were unreadable; remote revoke was skipped.");
        }

        if (token is not null)
        {
            try
            {
                using var api = new OAuthApi(null);
                revoked = await api.RevokeAsync(token.RefreshToken, cancellationToken);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                cancelled = true;
                revoked = false;
            }
            catch (Exception)
            {
                revoked = false;
            }
        }

        try
        {
            store.Delete();
        }
        catch (CredentialException)
        {
            Console.Error.WriteLine("Warning: local credential cleanup failed.");
            return 1;
        }

        if (cancelled)
        {
            Console.Error.WriteLine("Warning: remote revoke was cancelled; local credentials were removed.");
            return 130;
        }

        if (revoked)
        {
            Console.WriteLine("Logged out; remote revoke succeeded and local credentials were removed.");
            return 0;
        }

        Console.Error.WriteLine("Warning: remote revoke failed; local credentials were removed.");
        return 1;
    }

    private static void PrintHelp()
    {
        Console.WriteLine("Nativune - OAuth/library and Windows media capability probe");
        Console.WriteLine();
        Console.WriteLine("Usage: Nativune [--root <project-root>] <command>");
        Console.WriteLine();
        Console.WriteLine("Commands:");
        Console.WriteLine("  help       Show this help (the default command)");
        Console.WriteLine("  login      Open the system browser for Google OAuth (PKCE + state)");
        Console.WriteLine("  library    Report account/channel and read-only library capabilities");
        Console.WriteLine("  logout     Revoke the refresh token and remove local credentials");
        Console.WriteLine("  self-check Verify DPAPI round-trip/tamper rejection and callback state rejection");
        Console.WriteLine("  media      List Windows media sessions and supported controls (read-only)");
        Console.WriteLine("  media-control Select a session and interactively inspect/control it");
        Console.WriteLine("  web        Open official YouTube Music in an isolated WebView2 profile");
        Console.WriteLine("  native-fixture Show the account-free native Compact/Settings fixture for 60 seconds");
        Console.WriteLine("  native-interactions Measure the account-free native Compact/Settings interactions");
        Console.WriteLine();
        Console.WriteLine("The login flow requests only youtube.readonly, uses a loopback callback, and never uses an embedded webview or browser cookies.");
        Console.WriteLine("The web command stores its separate WebView2 profile only under data/webview2.");
        Console.WriteLine("Library output contains counts and capability results only; it does not print private titles or IDs.");
        Console.WriteLine("Run logout before login to switch accounts. Requests are bounded and Ctrl+C cancels them.");
        Console.WriteLine("Media commands do not access Google credentials or browser cookies, and never close the browser.");
        Console.WriteLine("Media output omits track titles/artists; exit 7 means no/removed session, 8 means Windows access failed.");
        Console.WriteLine("Native commands require only an existing --root directory and never access OAuth credentials, profiles, WebView2 or playback.");
    }
}

internal sealed record CliOptions(string Command, string? Root, bool Help);

internal static class CommandLine
{
    public static CliOptions Parse(string[] args)
    {
        if (args.Length == 0)
            return new CliOptions("help", null, true);

        string? command = null;
        string? root = null;
        var help = false;
        for (var i = 0; i < args.Length; i++)
        {
            var arg = args[i];
            if (arg is "--help" or "-h")
            {
                help = true;
                continue;
            }

            if (arg == "--root")
            {
                if (++i >= args.Length || string.IsNullOrWhiteSpace(args[i]))
                    throw new UsageException("--root requires a project root.");
                root = args[i];
                continue;
            }

            if (arg.StartsWith("--root=", StringComparison.Ordinal))
            {
                root = arg[7..];
                if (string.IsNullOrWhiteSpace(root))
                    throw new UsageException("--root requires a project root.");
                continue;
            }

            if (arg.StartsWith("-", StringComparison.Ordinal))
                throw new UsageException($"Unknown option '{arg}'. Use help for usage.");
            if (command is not null)
                throw new UsageException("Only one command may be supplied.");
            command = arg.ToLowerInvariant();
        }

        return new CliOptions(command ?? "help", root, help);
    }
}

internal static class RootLocator
{
    public static string Resolve(string? explicitRoot, bool requireCredentials = true)
    {
        if (explicitRoot is not null)
        {
            var root = Path.GetFullPath(explicitRoot);
            if (!Directory.Exists(root))
                throw new CredentialException("The specified project root does not exist.");
            if (requireCredentials && !File.Exists(CredentialPath(root)))
                throw new CredentialException("The specified project root has no installed OAuth credentials.");
            return root;
        }

        var current = new DirectoryInfo(AppContext.BaseDirectory);
        while (current is not null)
        {
            var marker = requireCredentials ? CredentialPath(current.FullName) : WebViewRuntimeManifestPath(current.FullName);
            if (File.Exists(marker))
                return current.FullName;
            current = current.Parent;
        }

        throw new CredentialException(requireCredentials
            ? "Could not locate a project root containing data/oauth/desktop-client.json."
            : "Could not locate a project root containing .tools/webview2/runtime-path.txt.");
    }

    public static string CredentialPath(string root) => Path.Combine(root, "data", "oauth", "desktop-client.json");
    public static string TokenPath(string root) => Path.Combine(root, "data", "oauth", "token.bin");
    public static string WebViewRuntimeManifestPath(string root) => Path.Combine(root, ".tools", "webview2", "runtime-path.txt");
    public static string WebViewProfilePath(string root) => Path.Combine(root, "data", "webview2");

    public static void EnsureNoReparsePath(string root, string path)
    {
        var fullRoot = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        var fullPath = Path.GetFullPath(path);
        var prefix = fullRoot + Path.DirectorySeparatorChar;
        if (!fullPath.Equals(fullRoot, StringComparison.OrdinalIgnoreCase) &&
            !fullPath.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("A runtime path escaped the Nativune root.");

        var current = fullRoot;
        EnsureNotReparse(current);
        var relative = Path.GetRelativePath(fullRoot, fullPath);
        if (relative == ".") return;
        foreach (var component in relative.Split(
            new[] { Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar },
            StringSplitOptions.RemoveEmptyEntries))
        {
            current = Path.Combine(current, component);
            if (!Path.Exists(current)) break;
            EnsureNotReparse(current);
        }
    }

    public static void EnsureNoReparseTree(string root, string directory)
    {
        EnsureNoReparsePath(root, directory);
        if (!Directory.Exists(directory))
            throw new DirectoryNotFoundException($"Required directory is missing: {directory}");
        var pending = new Stack<string>();
        pending.Push(directory);
        while (pending.Count > 0)
        {
            var current = pending.Pop();
            foreach (var entry in Directory.EnumerateFileSystemEntries(current))
            {
                EnsureNotReparse(entry);
                if (Directory.Exists(entry)) pending.Push(entry);
            }
        }
    }

    public static void EnsureRegularFile(string root, string path)
    {
        EnsureNoReparsePath(root, path);
        if (!File.Exists(path) || Directory.Exists(path))
            throw new FileNotFoundException("A required Nativune file is missing.", path);
    }

    private static void EnsureNotReparse(string path)
    {
        if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
            throw new InvalidOperationException($"Nativune refuses to use a reparse-point path: {path}");
    }
}

internal sealed record ClientCredentials(string ClientId, string ClientSecret, Uri AuthorizationEndpoint, Uri TokenEndpoint)
{
    public static ClientCredentials Load(string root)
    {
        var path = RootLocator.CredentialPath(root);
        try
        {
            using var document = JsonDocument.Parse(File.ReadAllText(path));
            var installed = document.RootElement.GetProperty("installed");
            var clientId = RequiredString(installed, "client_id");
            var clientSecret = OptionalString(installed, "client_secret") ?? string.Empty;
            var auth = ValidateEndpoint(RequiredString(installed, "auth_uri"), "accounts.google.com", "/o/oauth2/auth", "/o/oauth2/v2/auth");
            var token = ValidateEndpoint(RequiredString(installed, "token_uri"), "oauth2.googleapis.com", "/token");
            return new ClientCredentials(clientId, clientSecret, auth, token);
        }
        catch (CredentialException)
        {
            throw;
        }
        catch (Exception)
        {
            throw new CredentialException("The installed OAuth credentials are missing or malformed.");
        }
    }

    private static string RequiredString(JsonElement parent, string name)
    {
        if (!parent.TryGetProperty(name, out var property) || property.ValueKind != JsonValueKind.String)
            throw new CredentialException("The installed OAuth credentials are missing a required field.");
        var value = property.GetString();
        if (string.IsNullOrWhiteSpace(value))
            throw new CredentialException("The installed OAuth credentials are missing a required field.");
        return value;
    }

    private static string? OptionalString(JsonElement parent, string name)
    {
        if (!parent.TryGetProperty(name, out var property) || property.ValueKind == JsonValueKind.Null)
            return null;
        if (property.ValueKind != JsonValueKind.String)
            throw new CredentialException("The installed OAuth credentials are malformed.");
        return property.GetString();
    }

    private static Uri ValidateEndpoint(string value, string host, params string[] paths)
    {
        if (!Uri.TryCreate(value, UriKind.Absolute, out var uri)
            || uri.Scheme != Uri.UriSchemeHttps
            || !uri.Host.Equals(host, StringComparison.OrdinalIgnoreCase)
            || !uri.IsDefaultPort
            || !string.IsNullOrEmpty(uri.UserInfo)
            || !string.IsNullOrEmpty(uri.Query)
            || !string.IsNullOrEmpty(uri.Fragment)
            || !paths.Contains(uri.AbsolutePath.TrimEnd('/'), StringComparer.Ordinal))
            throw new CredentialException("The installed OAuth endpoint is not an approved Google endpoint.");
        return uri;
    }
}

internal sealed class TokenStore
{
    private readonly string _path;

    public TokenStore(string root) => _path = RootLocator.TokenPath(root);
    public bool Exists => File.Exists(_path);

    public StoredTokens? Load()
    {
        if (!Exists)
            return null;
        try
        {
            var encoded = File.ReadAllText(_path).Trim();
            var encrypted = Convert.FromBase64String(encoded);
            var plain = Dpapi.Unprotect(encrypted);
            try
            {
                var token = JsonSerializer.Deserialize<StoredTokens>(plain);
                if (token is null || string.IsNullOrWhiteSpace(token.RefreshToken) || string.IsNullOrWhiteSpace(token.AccessToken))
                    throw new CredentialException("The local OAuth credential is malformed.");
                return token;
            }
            finally
            {
                CryptographicOperations.ZeroMemory(plain);
            }
        }
        catch (CredentialException)
        {
            throw;
        }
        catch (Exception)
        {
            throw new CredentialException("The local OAuth credential is corrupt or unavailable.");
        }
    }

    public void Save(StoredTokens token)
    {
        if (string.IsNullOrWhiteSpace(token.RefreshToken) || string.IsNullOrWhiteSpace(token.AccessToken))
            throw new CredentialException("The token response did not contain usable credentials.");

        var plain = JsonSerializer.SerializeToUtf8Bytes(token);
        try
        {
            var encrypted = Dpapi.Protect(plain);
            var encoded = Convert.ToBase64String(encrypted);
            var directory = Path.GetDirectoryName(_path)!;
            Directory.CreateDirectory(directory);
            var temporary = _path + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try
            {
                File.WriteAllText(temporary, encoded + Environment.NewLine, new UTF8Encoding(false));
                if (File.Exists(_path))
                    File.Replace(temporary, _path, null);
                else
                    File.Move(temporary, _path);
            }
            finally
            {
                if (File.Exists(temporary))
                    File.Delete(temporary);
            }
            CryptographicOperations.ZeroMemory(encrypted);
        }
        catch (CredentialException)
        {
            throw;
        }
        catch (Exception)
        {
            throw new CredentialException("The local OAuth credential could not be protected or saved.");
        }
        finally
        {
            CryptographicOperations.ZeroMemory(plain);
        }
    }

    public void Delete()
    {
        try
        {
            if (File.Exists(_path))
                File.Delete(_path);
        }
        catch (Exception)
        {
            throw new CredentialException("The local OAuth credential could not be removed.");
        }
    }
}

internal sealed class StoredTokens
{
    public string RefreshToken { get; set; } = string.Empty;
    public string AccessToken { get; set; } = string.Empty;
    public DateTimeOffset AccessTokenExpiresUtc { get; set; }
}

internal static class Dpapi
{
    private const uint CryptProtectUiForbidden = 0x1;

    [StructLayout(LayoutKind.Sequential)]
    private struct DataBlob
    {
        public int Length;
        public IntPtr Data;
    }

    [DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CryptProtectData(ref DataBlob input, string? description, IntPtr entropy, IntPtr reserved, IntPtr prompt, uint flags, out DataBlob output);

    [DllImport("crypt32.dll", SetLastError = true)]
    private static extern bool CryptUnprotectData(ref DataBlob input, IntPtr description, IntPtr entropy, IntPtr reserved, IntPtr prompt, uint flags, out DataBlob output);

    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr handle);

    public static byte[] Protect(byte[] plain)
    {
        var input = Allocate(plain);
        var output = default(DataBlob);
        try
        {
            if (!CryptProtectData(ref input, "Nativune token", IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, CryptProtectUiForbidden, out output))
                throw new CryptographicException("DPAPI protection failed.");
            return CopyAndLocalFree(ref output);
        }
        finally
        {
            ZeroAndFree(ref input);
            if (output.Data != IntPtr.Zero)
                LocalFree(output.Data);
        }
    }

    public static byte[] Unprotect(byte[] encrypted)
    {
        var input = Allocate(encrypted);
        var output = default(DataBlob);
        try
        {
            if (!CryptUnprotectData(ref input, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, CryptProtectUiForbidden, out output))
                throw new CryptographicException("DPAPI unprotection failed.");
            return CopyAndLocalFree(ref output);
        }
        finally
        {
            ZeroAndFree(ref input);
            if (output.Data != IntPtr.Zero)
                LocalFree(output.Data);
        }
    }

    private static DataBlob Allocate(byte[] bytes)
    {
        var blob = new DataBlob { Length = bytes.Length, Data = Marshal.AllocHGlobal(bytes.Length) };
        Marshal.Copy(bytes, 0, blob.Data, bytes.Length);
        return blob;
    }

    private static byte[] CopyAndLocalFree(ref DataBlob blob)
    {
        var result = new byte[blob.Length];
        Marshal.Copy(blob.Data, result, 0, result.Length);
        if (blob.Length > 0)
            Marshal.Copy(new byte[blob.Length], 0, blob.Data, blob.Length);
        LocalFree(blob.Data);
        blob = default;
        return result;
    }

    private static void ZeroAndFree(ref DataBlob blob)
    {
        if (blob.Data == IntPtr.Zero)
            return;
        if (blob.Length > 0)
            Marshal.Copy(new byte[blob.Length], 0, blob.Data, blob.Length);
        Marshal.FreeHGlobal(blob.Data);
        blob = default;
    }
}

internal sealed class OAuthApi : IDisposable
{
    private const string RevokeEndpoint = "https://oauth2.googleapis.com/revoke";
    private const string YouTubeEndpoint = "https://youtube.googleapis.com/youtube/v3/";
    private static readonly TimeSpan RequestTimeout = TimeSpan.FromSeconds(30);
    private readonly HttpClient _http = new(new HttpClientHandler { AllowAutoRedirect = false }) { Timeout = Timeout.InfiniteTimeSpan };
    private readonly ClientCredentials? _credentials;

    public OAuthApi(ClientCredentials? credentials) => _credentials = credentials;

    public async Task<StoredTokens> ExchangeCodeAsync(string code, string verifier, string redirectUri, CancellationToken cancellationToken)
    {
        var credentials = _credentials ?? throw new AuthenticationException("OAuth client credentials are unavailable.");
        var form = new Dictionary<string, string>
        {
            ["code"] = code,
            ["client_id"] = credentials.ClientId,
            ["redirect_uri"] = redirectUri,
            ["grant_type"] = "authorization_code",
            ["code_verifier"] = verifier
        };
        if (!string.IsNullOrEmpty(credentials.ClientSecret))
            form["client_secret"] = credentials.ClientSecret;

        var response = await PostFormAsync(credentials.TokenEndpoint, form, cancellationToken);
        if (!response.Success)
            throw new AuthenticationException("Google did not accept the authorization code.");
        return ParseToken(response.Body, null, true);
    }

    public async Task<StoredTokens> RefreshAsync(StoredTokens old, CancellationToken cancellationToken)
    {
        var credentials = _credentials ?? throw new AuthenticationException("OAuth client credentials are unavailable.");
        var form = new Dictionary<string, string>
        {
            ["refresh_token"] = old.RefreshToken,
            ["client_id"] = credentials.ClientId,
            ["grant_type"] = "refresh_token"
        };
        if (!string.IsNullOrEmpty(credentials.ClientSecret))
            form["client_secret"] = credentials.ClientSecret;

        var response = await PostFormAsync(credentials.TokenEndpoint, form, cancellationToken);
        if (!response.Success)
            throw new AuthenticationException("The stored Google credential is expired or revoked.");
        return ParseToken(response.Body, old.RefreshToken, false);
    }

    public async Task<bool> RevokeAsync(string refreshToken, CancellationToken cancellationToken)
    {
        var form = new Dictionary<string, string> { ["token"] = refreshToken };
        var response = await PostFormAsync(new Uri(RevokeEndpoint), form, cancellationToken);
        return response.Success;
    }

    public async Task<ChannelSummary> GetChannelsAsync(string accessToken, CancellationToken cancellationToken)
    {
        using var document = await GetJsonAsync("channels", new Dictionary<string, string>
        {
            ["part"] = "id",
            ["mine"] = "true",
            ["maxResults"] = "50"
        }, accessToken, cancellationToken);
        return new ChannelSummary(CountItems(document));
    }

    public async Task<PlaylistSummary> GetOwnedPlaylistsAsync(string accessToken, CancellationToken cancellationToken)
    {
        var count = 0;
        var hasListenLater = false;
        string? pageToken = null;
        for (var page = 0; ; page++)
        {
            if (page > 1000)
                throw new ApiException("The owned-playlist result was unexpectedly large.");
            var query = new Dictionary<string, string>
            {
                ["part"] = "snippet",
                ["mine"] = "true",
                ["maxResults"] = "50"
            };
            if (!string.IsNullOrEmpty(pageToken))
                query["pageToken"] = pageToken;
            using var document = await GetJsonAsync("playlists", query, accessToken, cancellationToken);
            try
            {
                var items = ReadItems(document);
                foreach (var item in items.EnumerateArray())
                {
                    count++;
                    if (item.TryGetProperty("snippet", out var snippet)
                        && snippet.TryGetProperty("title", out var title)
                        && title.ValueKind == JsonValueKind.String
                        && string.Equals(title.GetString(), "Listen Later", StringComparison.Ordinal))
                        hasListenLater = true;
                }
                pageToken = NextPageToken(document);
            }
            catch (ApiException)
            {
                throw;
            }
            catch (Exception)
            {
                throw new ApiException("YouTube returned invalid owned-playlist data.");
            }
            if (string.IsNullOrEmpty(pageToken))
                break;
        }
        return new PlaylistSummary(count, hasListenLater);
    }

    public async Task<LikedSummary> GetLikedVideosAsync(string accessToken, CancellationToken cancellationToken)
    {
        const int apiCap = 1000;
        var count = 0;
        string? pageToken = null;
        for (var page = 0; count < apiCap; page++)
        {
            if (page >= 20)
                throw new ApiException("Liked-video pagination exceeded the expected API limit.");
            var query = new Dictionary<string, string>
            {
                ["part"] = "id",
                ["myRating"] = "like",
                ["maxResults"] = Math.Min(50, apiCap - count).ToString(System.Globalization.CultureInfo.InvariantCulture)
            };
            if (!string.IsNullOrEmpty(pageToken))
                query["pageToken"] = pageToken;
            using var document = await GetJsonAsync("videos", query, accessToken, cancellationToken);
            try
            {
                var items = ReadItems(document);
                count += items.GetArrayLength();
                pageToken = NextPageToken(document);
            }
            catch (Exception)
            {
                throw new ApiException("YouTube returned invalid liked-video data.");
            }
            if (string.IsNullOrEmpty(pageToken))
                break;
        }
        return new LikedSummary(count, count >= apiCap);
    }

    private async Task<HttpResult> PostFormAsync(Uri endpoint, IReadOnlyDictionary<string, string> values, CancellationToken cancellationToken)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(RequestTimeout);
        using var request = new HttpRequestMessage(HttpMethod.Post, endpoint)
        {
            Content = new FormUrlEncodedContent(values)
        };
        HttpResponseMessage response;
        try
        {
            response = await _http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token);
        }
        catch (HttpRequestException)
        {
            return new HttpResult(false, string.Empty);
        }
        using (response)
        {
            var body = await ReadBodyAsync(response, timeout.Token);
            return new HttpResult(response.IsSuccessStatusCode, body);
        }
    }

    private async Task<JsonDocument> GetJsonAsync(string resource, IReadOnlyDictionary<string, string> query, string accessToken, CancellationToken cancellationToken)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(RequestTimeout);
        var builder = new UriBuilder(new Uri(YouTubeEndpoint + resource));
        builder.Query = string.Join("&", query.Select(pair => $"{Uri.EscapeDataString(pair.Key)}={Uri.EscapeDataString(pair.Value)}"));
        using var request = new HttpRequestMessage(HttpMethod.Get, builder.Uri);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", accessToken);
        HttpResponseMessage response;
        try
        {
            response = await _http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token);
        }
        catch (HttpRequestException)
        {
            throw new ApiException("YouTube request could not be completed.");
        }
        using (response)
        {
            var body = await ReadBodyAsync(response, timeout.Token);
            if (!response.IsSuccessStatusCode)
            {
                var channelNotFound = false;
                try
                {
                    using var error = JsonDocument.Parse(body);
                    channelNotFound = response.StatusCode == HttpStatusCode.NotFound
                        && error.RootElement.TryGetProperty("error", out var detail)
                        && detail.TryGetProperty("errors", out var errors)
                        && errors.ValueKind == JsonValueKind.Array
                        && errors.EnumerateArray().Any(item => item.TryGetProperty("reason", out var reason)
                            && reason.ValueKind == JsonValueKind.String && reason.GetString() == "channelNotFound");
                }
                catch (JsonException) { }
                throw new ApiException($"YouTube rejected the authenticated request (HTTP {(int)response.StatusCode}).", channelNotFound);
            }
            try
            {
                return JsonDocument.Parse(body);
            }
            catch (Exception)
            {
                throw new ApiException("YouTube returned invalid JSON.");
            }
        }
    }

    private static async Task<string> ReadBodyAsync(HttpResponseMessage response, CancellationToken cancellationToken)
    {
        await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken);
        using var reader = new StreamReader(stream, Encoding.UTF8, false, 4096, leaveOpen: false);
        var builder = new StringBuilder();
        var buffer = new char[4096];
        while (true)
        {
            var read = await reader.ReadAsync(buffer.AsMemory(), cancellationToken);
            if (read == 0)
                break;
            if (builder.Length + read > 4 * 1024 * 1024)
                throw new ApiException("The remote response was too large.");
            builder.Append(buffer, 0, read);
        }
        return builder.ToString();
    }

    private static StoredTokens ParseToken(string body, string? existingRefreshToken, bool requireRefresh)
    {
        try
        {
            using var document = JsonDocument.Parse(body);
            var root = document.RootElement;
            var access = root.GetProperty("access_token").GetString();
            var refresh = root.TryGetProperty("refresh_token", out var refreshProperty) ? refreshProperty.GetString() : existingRefreshToken;
            if (string.IsNullOrWhiteSpace(access) || string.IsNullOrWhiteSpace(refresh) || (requireRefresh && existingRefreshToken is null && string.IsNullOrWhiteSpace(refresh)))
                throw new AuthenticationException("Google did not return a usable credential.");
            var expiresIn = 3600L;
            if (root.TryGetProperty("expires_in", out var expiresProperty) && expiresProperty.TryGetInt64(out var parsed) && parsed > 0)
                expiresIn = Math.Min(parsed, 86_400L);
            return new StoredTokens
            {
                AccessToken = access,
                RefreshToken = refresh,
                AccessTokenExpiresUtc = DateTimeOffset.UtcNow.AddSeconds(expiresIn)
            };
        }
        catch (AuthenticationException)
        {
            throw;
        }
        catch (Exception)
        {
            throw new AuthenticationException("Google returned an invalid token response.");
        }
    }

    private static readonly JsonElement EmptyItems = JsonSerializer.SerializeToElement(Array.Empty<object>());

    internal static int CountItems(JsonDocument document) => ReadItems(document).GetArrayLength();

    private static JsonElement ReadItems(JsonDocument document)
    {
        var root = document.RootElement;
        if (root.TryGetProperty("items", out var items) && items.ValueKind == JsonValueKind.Array)
            return items;
        if (!root.TryGetProperty("items", out _)
            && root.TryGetProperty("pageInfo", out var pageInfo)
            && pageInfo.ValueKind == JsonValueKind.Object
            && pageInfo.TryGetProperty("totalResults", out var total)
            && total.ValueKind == JsonValueKind.Number
            && total.TryGetInt32(out var count) && count == 0)
            return EmptyItems;
        throw new ApiException("YouTube returned invalid list data.");
    }

    private static string? NextPageToken(JsonDocument document)
    {
        if (!document.RootElement.TryGetProperty("nextPageToken", out var token) || token.ValueKind != JsonValueKind.String)
            return null;
        return token.GetString();
    }

    public void Dispose() => _http.Dispose();

    private sealed record HttpResult(bool Success, string Body);
}

internal static class LoopbackOAuth
{
    private const string Scope = "https://www.googleapis.com/auth/youtube.readonly";

    public static async Task<StoredTokens> AuthorizeAsync(ClientCredentials credentials, OAuthApi api, CancellationToken cancellationToken, TimeSpan timeout)
    {
        using var lifetime = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        lifetime.CancelAfter(timeout);
        using var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        var port = ((IPEndPoint)listener.LocalEndpoint).Port;
        var redirectUri = $"http://127.0.0.1:{port}/oauth2callback/";
        var verifier = Base64Url(RandomNumberGenerator.GetBytes(32));
        var state = Base64Url(RandomNumberGenerator.GetBytes(32));
        var challenge = Base64Url(SHA256.HashData(Encoding.ASCII.GetBytes(verifier)));
        var authUrl = BuildAuthorizationUrl(credentials.AuthorizationEndpoint, credentials.ClientId, redirectUri, state, challenge);

        try
        {
            Process.Start(new ProcessStartInfo { FileName = authUrl, UseShellExecute = true });
            Console.WriteLine("Waiting for Google consent in your browser (10-minute timeout).");
        }
        catch (AuthenticationException)
        {
            throw;
        }
        catch (Exception)
        {
            throw new AuthenticationException("The system browser could not be opened.");
        }

        while (true)
        {
            using var client = await listener.AcceptTcpClientAsync(lifetime.Token);
            using var connectionTimeout = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
            connectionTimeout.CancelAfter(TimeSpan.FromSeconds(5));
            CallbackData callback;
            try
            {
                callback = await ReadCallbackAsync(client, state, connectionTimeout.Token);
            }
            catch (OperationCanceledException) when (!lifetime.IsCancellationRequested) { continue; }
            catch (IOException) { continue; }
            catch (UriFormatException) { continue; }
            if (!callback.IsCallback)
                continue;
            if (!string.IsNullOrEmpty(callback.Error))
                throw new AuthenticationException("Google authorization was not granted.");
            if (string.IsNullOrWhiteSpace(callback.Code))
                throw new AuthenticationException("Google returned no authorization code.");
            return await api.ExchangeCodeAsync(callback.Code, verifier, redirectUri, lifetime.Token);
        }
    }

    private static string BuildAuthorizationUrl(Uri endpoint, string clientId, string redirectUri, string state, string challenge)
    {
        var query = new Dictionary<string, string>
        {
            ["client_id"] = clientId,
            ["redirect_uri"] = redirectUri,
            ["response_type"] = "code",
            ["scope"] = Scope,
            ["access_type"] = "offline",
            ["prompt"] = "consent select_account",
            ["code_challenge"] = challenge,
            ["code_challenge_method"] = "S256",
            ["state"] = state
        };
        var builder = new UriBuilder(endpoint)
        {
            Query = string.Join("&", query.Select(pair => $"{Uri.EscapeDataString(pair.Key)}={Uri.EscapeDataString(pair.Value)}"))
        };
        return builder.Uri.AbsoluteUri;
    }

    internal static async Task<CallbackData> ReadCallbackAsync(TcpClient client, string expectedState, CancellationToken cancellationToken)
    {
        await using var stream = client.GetStream();
        var line = await ReadRequestLineAsync(stream, cancellationToken);
        if (line is null)
            return new CallbackData(false, null, null, null);
        var parts = line.Split(' ', 3, StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length != 3 || parts[0] != "GET" || !parts[1].StartsWith('/') || !Uri.TryCreate("http://localhost" + parts[1], UriKind.Absolute, out var target))
        {
            await WriteResponseAsync(stream, 400, "Invalid callback.", cancellationToken);
            return new CallbackData(false, null, null, null);
        }
        var headersEnded = false;
        for (var header = 0; header < 32; header++)
        {
            var headerLine = await ReadRequestLineAsync(stream, cancellationToken);
            if (headerLine is null) break;
            if (headerLine.Length == 0) { headersEnded = true; break; }
        }
        if (!headersEnded)
            return new CallbackData(false, null, null, null);
        if (target.AbsolutePath is not "/oauth2callback" and not "/oauth2callback/")
        {
            await WriteResponseAsync(stream, 404, "Not found.", cancellationToken);
            return new CallbackData(false, null, null, null);
        }

        var values = ParseQuery(target.Query);
        var state = values.GetValueOrDefault("state");
        var code = values.GetValueOrDefault("code");
        var error = values.GetValueOrDefault("error");
        if (!CallbackSecurity.StateMatches(expectedState, state))
        {
            await WriteResponseAsync(stream, 400, "Invalid authorization state.", cancellationToken);
            return new CallbackData(false, null, null, null);
        }
        await WriteResponseAsync(stream, 200, "You may close this window.", cancellationToken);
        return new CallbackData(true, state, code, error);
    }

    private static async Task<string?> ReadRequestLineAsync(NetworkStream stream, CancellationToken cancellationToken)
    {
        var bytes = new List<byte>(256);
        var one = new byte[1];
        while (bytes.Count < 8192)
        {
            var read = await stream.ReadAsync(one.AsMemory(), cancellationToken);
            if (read == 0)
                break;
            bytes.Add(one[0]);
            if (bytes.Count >= 2 && bytes[^2] == (byte)'\r' && bytes[^1] == (byte)'\n')
                return Encoding.ASCII.GetString(CollectionsMarshal.AsSpan(bytes)[..^2]);
        }
        return null;
    }

    private static async Task WriteResponseAsync(NetworkStream stream, int status, string message, CancellationToken cancellationToken)
    {
        var body = $"<html><body>{WebUtility.HtmlEncode(message)}</body></html>";
        var bodyBytes = Encoding.UTF8.GetBytes(body);
        var header = $"HTTP/1.1 {status} OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {bodyBytes.Length}\r\nConnection: close\r\n\r\n";
        var bytes = Encoding.UTF8.GetBytes(header).Concat(bodyBytes).ToArray();
        await stream.WriteAsync(bytes, cancellationToken);
    }

    private static Dictionary<string, string> ParseQuery(string query)
    {
        var result = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var part in query.TrimStart('?').Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            var pieces = part.Split('=', 2);
            var key = Uri.UnescapeDataString(pieces[0].Replace('+', ' '));
            var value = pieces.Length == 2 ? Uri.UnescapeDataString(pieces[1].Replace('+', ' ')) : string.Empty;
            if (!result.TryAdd(key, value))
                throw new UriFormatException("Duplicate callback parameter.");
        }
        return result;
    }

    private static string Base64Url(byte[] value) => Convert.ToBase64String(value).TrimEnd('=').Replace('+', '-').Replace('/', '_');
    internal sealed record CallbackData(bool IsCallback, string? State, string? Code, string? Error);
}

internal static class CallbackSecurity
{
    public static bool StateMatches(string expected, string? actual)
    {
        if (string.IsNullOrEmpty(actual))
            return false;
        return CryptographicOperations.FixedTimeEquals(Encoding.UTF8.GetBytes(expected), Encoding.UTF8.GetBytes(actual));
    }
}

internal readonly record struct ChannelSummary(int Count);
internal readonly record struct PlaylistSummary(int Count, bool HasExactListenLater);
internal readonly record struct LikedSummary(int Count, bool ReachedApiCap);

internal static class SelfCheck
{
    public static int Run(string root)
    {
        var directory = Path.Combine(root, "data", "oauth", ".self-check-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            var isolatedRoot = Path.Combine(directory, "root");
            Directory.CreateDirectory(Path.Combine(isolatedRoot, "data", "oauth"));
            ShellChecks.Run(isolatedRoot);
            var store = new TokenStore(isolatedRoot);
            store.Save(new StoredTokens
            {
                RefreshToken = "self-check-refresh",
                AccessToken = "self-check-access",
                AccessTokenExpiresUtc = DateTimeOffset.UtcNow.AddMinutes(5)
            });
            var roundTrip = store.Load();
            if (roundTrip is null || roundTrip.RefreshToken != "self-check-refresh")
                throw new SelfCheckException("DPAPI round-trip failed.");

            var tokenPath = RootLocator.TokenPath(isolatedRoot);
            var bytes = Convert.FromBase64String(File.ReadAllText(tokenPath));
            bytes[^1] ^= 1;
            File.WriteAllText(tokenPath, Convert.ToBase64String(bytes));
            try
            {
                _ = store.Load();
                throw new SelfCheckException("DPAPI tamper rejection failed.");
            }
            catch (CredentialException)
            {
                // Expected: an altered protected blob must not load.
            }

            CheckCallbackAsync("wrong-state", false).GetAwaiter().GetResult();
            CheckCallbackAsync("expected-state", true).GetAwaiter().GetResult();
            var credentialsPath = RootLocator.CredentialPath(isolatedRoot);
            var configuration = new { installed = new { client_id = "self-check.apps.googleusercontent.com",
                auth_uri = "https://accounts.google.com/o/oauth2/auth", token_uri = "https://oauth2.googleapis.com/token" } };
            File.WriteAllText(credentialsPath, JsonSerializer.Serialize(configuration));
            _ = ClientCredentials.Load(isolatedRoot);
            File.WriteAllText(credentialsPath, JsonSerializer.Serialize(configuration).Replace("oauth2.googleapis.com", "example.com"));
            try
            {
                _ = ClientCredentials.Load(isolatedRoot);
                throw new SelfCheckException("Untrusted token endpoint was accepted.");
            }
            catch (CredentialException) { }

            if (!WebHostPolicy.IsAllowedMainFrameNavigation(new Uri("https://music.youtube.com/"))
                || !WebHostPolicy.IsAllowedMainFrameNavigation(new Uri("https://www.youtube.com/"))
                || !WebHostPolicy.IsAllowedMainFrameNavigation(new Uri("https://accounts.google.com/"))
                || !WebHostPolicy.IsAllowedMainFrameNavigation(new Uri("https://accounts.youtube.com/"))
                || !WebHostPolicy.IsAllowedMainFrameNavigation(new Uri("https://accounts.google.com.my/"))
                || WebHostPolicy.IsAllowedMainFrameNavigation(new Uri("https://accounts.google.com.my.evil.example/"))
                || WebHostPolicy.IsAllowedMainFrameNavigation(new Uri("https://accounts.youtube.com.evil.example/"))
                || WebHostPolicy.IsAllowedMainFrameNavigation(new Uri("http://music.youtube.com/"))
                || WebHostPolicy.IsAllowedMainFrameNavigation(new Uri("https://music.youtube.com.evil.example/"))
                || WebHostPolicy.IsAllowedMainFrameNavigation(new Uri("https://music.youtube.com:444/")))
            {
                throw new SelfCheckException("Web navigation origin boundary failed.");
            }

            using var emptyChannel = JsonDocument.Parse("{\"kind\":\"youtube#channelListResponse\",\"pageInfo\":{\"totalResults\":0}}");
            if (OAuthApi.CountItems(emptyChannel) != 0)
                throw new SelfCheckException("An empty YouTube result did not report zero items.");
            using var malformedList = JsonDocument.Parse("{\"pageInfo\":{\"totalResults\":1}}");
            try
            {
                _ = OAuthApi.CountItems(malformedList);
                throw new SelfCheckException("Missing non-empty YouTube items were accepted.");
            }
            catch (ApiException) { }

            ReleaseUpdaterChecks.Run(root);
            Console.WriteLine("Self-check passed: DPAPI, loopback state, credential endpoints, WebView navigation origin boundary, malformed YouTube lists, and release updater checks.");
            return 0;
        }
        finally
        {
            try
            {
                if (Directory.Exists(directory))
                    Directory.Delete(directory, recursive: true);
            }
            catch (Exception)
            {
                throw new SelfCheckException("Self-check temporary data could not be removed.");
            }
        }
    }

    private static async Task CheckCallbackAsync(string state, bool expectedAcceptance)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        using var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        using var sender = new TcpClient();
        await sender.ConnectAsync((IPEndPoint)listener.LocalEndpoint, timeout.Token);
        using var receiver = await listener.AcceptTcpClientAsync(timeout.Token);
        var callback = LoopbackOAuth.ReadCallbackAsync(receiver, "expected-state", timeout.Token);
        await sender.GetStream().WriteAsync(Encoding.ASCII.GetBytes(
            $"GET /oauth2callback/?state={state}&code=synthetic-code HTTP/1.1\r\nHost: localhost\r\n\r\n"), timeout.Token);
        var result = await callback;
        if (result.IsCallback != expectedAcceptance || (expectedAcceptance && result.Code != "synthetic-code"))
            throw new SelfCheckException("Loopback callback accepted an invalid state or rejected a valid callback.");
    }
}

internal sealed class CancellationController : IDisposable
{
    private readonly CancellationTokenSource _source = new();
    private readonly ConsoleCancelEventHandler _handler;
    public CancellationToken Token => _source.Token;

    public CancellationController()
    {
        _handler = (_, args) =>
        {
            args.Cancel = true;
            _source.Cancel();
        };
        Console.CancelKeyPress += _handler;
    }

    public void Dispose()
    {
        Console.CancelKeyPress -= _handler;
        _source.Dispose();
    }
}

internal class ProbeException : Exception
{
    public ProbeException(string message) : base(message) { }
}

internal sealed class UsageException : ProbeException
{
    public UsageException(string message) : base(message) { }
}

internal sealed class CredentialException : ProbeException
{
    public CredentialException(string message) : base(message) { }
}

internal sealed class AuthenticationException : ProbeException
{
    public AuthenticationException(string message) : base(message) { }
}

internal sealed class ApiException : ProbeException
{
    public bool ChannelNotFound { get; }
    public ApiException(string message, bool channelNotFound = false) : base(message) => ChannelNotFound = channelNotFound;
}

internal sealed class SelfCheckException : ProbeException
{
    public SelfCheckException(string message) : base(message) { }
}
