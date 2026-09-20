using System.Reflection;

namespace Nativune;

internal static class AppVersion
{
    internal static string Number { get; } = ReadNumber();
    internal static string DisplayName => $"Nativune {Number}";

    private static string ReadNumber()
    {
        var assembly = typeof(AppVersion).Assembly;
        var informational = assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()
            ?.InformationalVersion;
        if (!string.IsNullOrWhiteSpace(informational))
        {
            var metadata = informational.IndexOf('+', StringComparison.Ordinal);
            return metadata < 0 ? informational : informational[..metadata];
        }

        return assembly.GetName().Version?.ToString(3) ?? "unknown";
    }
}
