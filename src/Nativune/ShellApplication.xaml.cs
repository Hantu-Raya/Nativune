using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;

namespace Nativune;

public partial class ShellApplication : Application
{
    private readonly Action _onLaunched;

    internal ShellApplication(Action onLaunched)
    {
        ArgumentNullException.ThrowIfNull(onLaunched);
        _onLaunched = onLaunched;
        InitializeComponent();
        // Logged only; WinUI's default handling (terminate) is unchanged.
        // e.Message can carry WinRT origin text that the exception's own stack lacks.
        UnhandledException += (_, e) => AppLog.Write("crash", (e.Exception?.ToString() ?? "") + Environment.NewLine + "    xaml: " + e.Message);
    }

    internal static void Run(Action onLaunched)
    {
        ArgumentNullException.ThrowIfNull(onLaunched);
        WinRT.ComWrappersSupport.InitializeComWrappers();

        Application.Start(_ =>
        {
            var context = new DispatcherQueueSynchronizationContext(
                DispatcherQueue.GetForCurrentThread());
            SynchronizationContext.SetSynchronizationContext(context);
            new ShellApplication(onLaunched);
        });
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        _onLaunched();
    }
}
