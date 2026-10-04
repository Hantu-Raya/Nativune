#if NATIVUNE_DISCORD_TEST_HOOKS
using System.Text.Json;

namespace Nativune;

// File commands are accepted only in the disposable bench profile, never from a web page.
public sealed partial class WebHostWindow
{
    private async Task ProcessObsDesignerBenchCommandsAsync()
    {
        if (_discordBenchDirectory is not { } directory) return;

        var forcedFailure = TakeObsCommandPayload("command-obs-font-enumeration-fail");
        if (forcedFailure is not null)
            SystemFonts.HookForceEnumerationFailure = forcedFailure.Trim() == "on";

        if (TakeDiscordBenchCommand("command-obs-fonts-dump"))
        {
            var result = SystemFonts.Enumerate();
            var body = JsonSerializer.Serialize(new
            {
                families = result.Families.Select(f => new
                {
                    canonical = f.Canonical, display = f.Display, aliases = f.Aliases
                }),
                truncated = result.Truncated,
                error = result.Failed ? "Could not enumerate installed fonts" : null
            });
            DiscordPresenceDiagnostics.WriteAtomically(Path.Combine(directory, "fonts.json"), body);
        }

        if (TakeDiscordBenchCommand("command-obs-designer-open"))
            _ = OpenOverlayDesignerAsync(ObsButton);
        if (TakeDiscordBenchCommand("command-obs-designer-close"))
            if (_overlayDesignerWindow is { } closingDesigner) await closingDesigner.RequestCloseAsync();
        if (TakeDiscordBenchCommand("command-lyrics-open"))
            await OpenLyricsSettingsAsync();
        if (TakeDiscordBenchCommand("command-lyrics-close"))
            CloseLyricsSettingsWindow();
        var navigation = TakeObsCommandPayload("command-obs-designer-navigate");
        if (navigation is not null && _overlayDesignerWindow is { } designer)
            designer.NavigateForHook(navigation.Trim());
        if (TakeDiscordBenchCommand("command-obs-designer-process-failed") && _overlayDesignerWindow?.Core is { } previewCore)
        {
            try { await previewCore.CallDevToolsProtocolMethodAsync("Page.crash", "{}"); }
            catch (Exception) { } // The preview renderer intentionally disconnects its CDP request.
        }

        if (TakeDiscordBenchCommand("command-obs-preview-fonts-dump"))
        {
            var result = "{\"fonts\":[]}";
            try
            {
                if (_overlayDesignerWindow?.Core is { } core)
                {
                    await core.CallDevToolsProtocolMethodAsync("DOM.enable", "{}");
                    await core.CallDevToolsProtocolMethodAsync("CSS.enable", "{}");
                    var document = await core.CallDevToolsProtocolMethodAsync("DOM.getDocument", "{\"depth\":1}");
                    var rootNode = JsonDocument.Parse(document).RootElement.GetProperty("root").GetProperty("nodeId").GetInt32();
                    var query = await core.CallDevToolsProtocolMethodAsync("DOM.querySelector",
                        JsonSerializer.Serialize(new { nodeId = rootNode, selector = "#title" }));
                    var titleNode = JsonDocument.Parse(query).RootElement.GetProperty("nodeId").GetInt32();
                    if (titleNode != 0)
                        result = await core.CallDevToolsProtocolMethodAsync("CSS.getPlatformFontsForNode",
                            JsonSerializer.Serialize(new { nodeId = titleNode }));
                }
            }
            catch (Exception ex)
            {
                result = JsonSerializer.Serialize(new { fonts = Array.Empty<object>(), error = ex.GetType().Name });
            }
            DiscordPresenceDiagnostics.WriteAtomically(Path.Combine(directory, "preview-fonts.json"), result);
        }
        if (TakeDiscordBenchCommand("command-obs-preview-state-dump"))
        {
            var result = "{\"error\":\"Preview unavailable\"}";
            try
            {
                if (_overlayDesignerWindow?.Core is { } core)
                    result = await core.ExecuteScriptAsync("window.__state || null");
            }
            catch (Exception ex) { result = JsonSerializer.Serialize(new { error = ex.GetType().Name }); }
            DiscordPresenceDiagnostics.WriteAtomically(Path.Combine(directory, "preview-state.json"), result);
        }

        if (TakeDiscordBenchCommand("command-obs-designer-snapshot"))
        {
            var snapshot = _overlayDesignerWindow?.SnapshotForHook();
            DiscordPresenceDiagnostics.WriteAtomically(Path.Combine(directory, "designer.json"),
                JsonSerializer.Serialize(new { open = _overlayDesignerWindow is not null, state = snapshot }));
        }
    }

    private DiscordBenchRawJson ObsDesignerBenchStateJson()
    {
        object snapshot = _overlayDesignerWindow is { } window
            ? window.SnapshotForHook()
            : new { open = false, visible = false, navigated = false, nonce = (string?)null };
        return new DiscordBenchRawJson(JsonSerializer.Serialize(snapshot));
    }

    private DiscordBenchRawJson ObsLyricsBenchStateJson() =>
        new(JsonSerializer.Serialize(new { open = _lyricsWindow is not null }));
}
#endif
