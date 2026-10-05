# Dot-sourced by obs-overlay-e2e.ps1 after its shared E2E/UIA/CDP helpers.
# P2 checks keep evidence in $runDirectory; a missing capability is blocked, never a pass.
function Save-P2Evidence([string] $Name, $Value) {
    $path = Join-Path $runDirectory ("p2-{0}.json" -f (ConvertTo-SafeName $Name))
    [IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $Value -Depth 32), [Text.UTF8Encoding]::new($false))
    [IO.Path]::GetRelativePath($runDirectory, $path)
}
$script:p2FxFields = @('BackgroundBlur', 'PlayedBrightness', 'UnplayedBrightness', 'BackgroundBrightness')
$script:p2NumberBoxes = @('WidthBox', 'ScaleBox', 'OpacityBox') + @($script:p2FxFields | ForEach-Object { "${_}Box" })
# §5 visual order, matching the designer rows immediately after HideAnimationPicker and before Copy/Save.
$script:p2FxTabOrder = @($script:p2FxFields | ForEach-Object { "${_}Slider"; "${_}Box"; "${_}ResetButton" })
function Get-P2Fx($Options) {
    $fx = [ordered]@{}
    foreach ($field in $script:p2FxFields) { $fx[$field] = Get-Prop $Options $field }
    $fx
}
function Test-P2FxEqual($Actual, $Expected) {
    ((Get-P2Fx $Actual) | ConvertTo-Json -Compress) -ceq ((Get-P2Fx $Expected) | ConvertTo-Json -Compress)
}
function Get-P2FxDefaults([string] $Theme) {
    $values = switch ($Theme) {
        'pill' { 14; 115; 45; 100 }
        'matte' { 0; 100; 100; 100 }
        { $_ -in @('matte-light', 'simple') } { 0; 100; 0; 100 }
        { $_ -in @('standard', 'classic') } { 14; 100; 100; 40 }
        'album-art' { 0; 100; 100; 100 }
        'card' { 16; 100; 100; 35 }
        default { throw "Unknown LookFx theme $Theme" }
    }
    $fx = [ordered]@{}
    for ($i = 0; $i -lt $script:p2FxFields.Count; $i++) { $fx[$script:p2FxFields[$i]] = $values[$i] }
    $fx
}
function Test-P2ResolvedFx($Page, $Expected) {
    $resolved = Get-Prop $Page 'fx'
    $resolved -and $resolved.blur -eq (Get-Prop $Expected 'BackgroundBlur') -and
        $resolved.played -eq (Get-Prop $Expected 'PlayedBrightness') -and
        $resolved.unplayed -eq (Get-Prop $Expected 'UnplayedBrightness') -and
        $resolved.background -eq (Get-Prop $Expected 'BackgroundBrightness')
}
function Invoke-P2FxRevert($Designer) {
    if ((Get-P2DesignerHook $Designer.Run).state.dirty) {
        Invoke-Element (Assert-P2Control $Designer 'RevertChangesButton')
        [void] (Invoke-P2DialogChoice $Designer.Run 'Discard changes*' 'Discard')
    }
    $reverted = Wait-For {
        $s = Get-P2DesignerHook $Designer.Run
        if ($s.open -and $s.state.dirty -eq $false -and -not $s.state.dialogActive -and
            @(Get-P2ModalTitles $Designer).Count -eq 0) { $s }
    } 10 150
    if (-not $reverted) {
        $path = Save-P2DesignerDiagnostics $Designer.Run 'fx-revert-timeout'
        throw "FX Revert did not settle to a clean draft; evidence: $path"
    }
    $reverted
}
function Save-P2PixelEvidence($Chrome, [string] $Name) {
    $bytes = Get-ChromeShotBytes $Chrome
    $path = Join-Path $runDirectory ("p2-{0}.png" -f (ConvertTo-SafeName $Name))
    [IO.File]::WriteAllBytes($path, $bytes)
    $stream = [IO.MemoryStream]::new($bytes); $bitmap = $null; $locked = $null
    try {
        $bitmap = [Drawing.Bitmap]::new($stream)
        $locked = $bitmap.LockBits([Drawing.Rectangle]::new(0, 0, $bitmap.Width, $bitmap.Height),
            [Drawing.Imaging.ImageLockMode]::ReadOnly, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $pixels = [byte[]]::new($bitmap.Width * $bitmap.Height * 4)
        for ($y = 0; $y -lt $bitmap.Height; $y++) {
            [Runtime.InteropServices.Marshal]::Copy([IntPtr]::Add($locked.Scan0, $y * $locked.Stride), $pixels,
                $y * $bitmap.Width * 4, $bitmap.Width * 4)
        }
        [ordered]@{ image = [IO.Path]::GetRelativePath($runDirectory, $path); width = $bitmap.Width; height = $bitmap.Height
            pixelHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($pixels)) }
    } finally {
        if ($locked) { $bitmap.UnlockBits($locked) }; if ($bitmap) { $bitmap.Dispose() }; $stream.Dispose()
    }
}
function Get-P2Designer($Run) {
    $hwnd = Wait-For { $h = [ObsE2E]::Find([uint32] $Run.App.Id, 'Overlay designer'); if ($h -ne [IntPtr]::Zero) { $h } } 20 200
    if (-not $hwnd) { throw 'Overlay designer window did not open.' }
    [pscustomobject]@{ Hwnd = $hwnd; El = $AE::FromHandle($hwnd); Run = $Run }
}
function Get-P2Control($Designer, [string] $Id) { Find-Element $Designer.El 'AutomationId' $Id 2 }
function Assert-P2Control($Designer, [string] $Id) {
    $el = Get-P2Control $Designer $Id
    if (-not $el) {
        $path = Save-P2DesignerDiagnostics $Designer.Run "missing-control-$Id"
        throw "Missing UIA control $Id; evidence: $path"
    }
    $el
}
function Get-P2DescribedByNames([int[]] $RuntimeId) {
    if (-not ('ObsP2UiaRelations' -as [type])) {
        # .NET UIAutomationClient omits DescribedBy. Read the actual focused peer's native relation.
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ObsP2UiaRelations
{
    [ComImport, Guid("30CBE57D-D9D0-452A-AB13-7AC5AC4825EE"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IUIAutomation
    {
        void CompareElements(); void CompareRuntimeIds(); void GetRootElement();
        void ElementFromHandle(); void ElementFromPoint();
        void GetFocusedElement(out IUIAutomationElement element);
    }
    [ComImport, Guid("D22108AA-8AC5-49A5-837B-37BBB3D7591E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IUIAutomationElement
    {
        void SetFocus();
        void GetRuntimeId([MarshalAs(UnmanagedType.SafeArray, SafeArraySubType = VarEnum.VT_I4)] out int[] id);
        void FindFirst(); void FindAll(); void FindFirstBuildCache(); void FindAllBuildCache(); void BuildUpdatedCache();
        void GetCurrentPropertyValue(int propertyId, [MarshalAs(UnmanagedType.Struct)] out object value);
        void GetCachedPropertyValue(); void GetCurrentPropertyValueEx(); void GetCachedPropertyValueEx();
        void GetCurrentPatternAs(); void GetCachedPatternAs(); void GetCurrentPattern(); void GetCachedPattern();
        void GetCachedParent(); void GetCachedChildren(); void GetCurrentProcessId(); void GetCurrentControlType();
        void GetCurrentLocalizedControlType();
        void GetCurrentName([MarshalAs(UnmanagedType.BStr)] out string name);
    }
    [ComImport, Guid("14314595-B4BC-4055-95F2-58F2E42C9855"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IUIAutomationElementArray
    {
        void GetLength(out int length);
        void GetElement(int index, out IUIAutomationElement element);
    }
    private static void Release(object value)
    {
        if (value != null && Marshal.IsComObject(value)) Marshal.ReleaseComObject(value);
    }
    public static string[] DescribedByNames(int[] expectedRuntimeId)
    {
        object automation = null, relation = null;
        IUIAutomationElement focused = null;
        try
        {
            automation = Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("FF48DBA4-60EF-4201-AA87-54103EEF594E")));
            ((IUIAutomation)automation).GetFocusedElement(out focused);
            if (focused == null) throw new InvalidOperationException("Native UIA has no focused element.");
            int[] id; focused.GetRuntimeId(out id);
            if (id == null || expectedRuntimeId == null || id.Length != expectedRuntimeId.Length)
                throw new InvalidOperationException("Native UIA focus changed before DescribedBy read.");
            for (int i = 0; i < id.Length; i++)
                if (id[i] != expectedRuntimeId[i])
                    throw new InvalidOperationException("Native UIA focus changed before DescribedBy read.");
            focused.GetCurrentPropertyValue(30105, out relation); // UIA_DescribedByPropertyId
            if (relation == null) return new string[0];
            var elements = relation as IUIAutomationElementArray;
            if (elements == null) throw new InvalidOperationException("DescribedBy did not return IUIAutomationElementArray.");
            int count; elements.GetLength(out count);
            var names = new string[count];
            for (int i = 0; i < count; i++)
            {
                IUIAutomationElement element = null;
                try { elements.GetElement(i, out element); element.GetCurrentName(out names[i]); }
                finally { Release(element); }
            }
            return names;
        }
        finally { Release(relation); Release(focused); Release(automation); }
    }
}
'@
    }
    [ObsP2UiaRelations]::DescribedByNames($RuntimeId)
}
function Get-P2ControlGeometry($Designer, $El) {
    $bounds = $El.Current.BoundingRectangle; $window = $Designer.El.Current.BoundingRectangle
    $finite = @($bounds.X, $bounds.Y, $bounds.Width, $bounds.Height,
        $bounds.Right, $bounds.Bottom, $window.X, $window.Y, $window.Width, $window.Height,
        $window.Right, $window.Bottom | Where-Object {
            [double]::IsNaN($_) -or [double]::IsInfinity($_)
        }).Count -eq 0
    $nonempty = -not $bounds.IsEmpty -and $bounds.Width -gt 0 -and $bounds.Height -gt 0 -and
        -not $window.IsEmpty -and $window.Width -gt 0 -and $window.Height -gt 0
    [ordered]@{ offscreen = $El.Current.IsOffscreen; enabled = $El.Current.IsEnabled
        bounds = $bounds.ToString(); window = $window.ToString(); finite = $finite; nonempty = $nonempty
        inside = $finite -and $nonempty -and $bounds.Left -ge $window.Left -and $bounds.Right -le $window.Right -and
            $bounds.Top -ge $window.Top -and $bounds.Bottom -le $window.Bottom }
}
function Get-P2SettledControl($Designer, [string] $Id) {
    $result = [ordered]@{ settled = $false; method = $null; geometry = $null
        errors = [Collections.Generic.List[string]]::new() }
    $deadline = [DateTime]::UtcNow.AddSeconds(8)
    $acted = $false; $stable = 0; $previous = $null
    do {
        try {
            $Designer.El = $AE::FromHandle($Designer.Hwnd)
            $el = Assert-P2Control $Designer $Id
            $result.geometry = Get-P2ControlGeometry $Designer $el
            if (-not $acted) {
                $pattern = $null
                if ($el.TryGetCurrentPattern([System.Windows.Automation.ScrollItemPattern]::Pattern, [ref] $pattern)) {
                    $pattern.ScrollIntoView(); $result.method = 'ScrollItem'
                } elseif ($el.Current.IsEnabled -and $el.Current.IsKeyboardFocusable) {
                    $el.SetFocus(); $result.method = 'Focus'
                } else {
                    $result.method = 'AncestorScroll'
                }
                $acted = $true
                $stable = 0
                Start-Sleep -Milliseconds 150
                continue
            }
            $g = $result.geometry
            if (-not $g.offscreen -and $g.inside) {
                if ($previous -ceq $g.bounds) { $stable++ } else { $stable = 1 }
                $previous = $g.bounds
                if ($stable -ge 3) { $result.settled = $true; break }
            } else {
                $stable = 0; $previous = $null
                if ($result.method -eq 'AncestorScroll') {
                    $ancestor = [System.Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($el)
                    $scroll = $null
                    while ($ancestor) {
                        if ($ancestor.TryGetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern, [ref] $scroll) -and
                            $scroll.Current.VerticallyScrollable) { break }
                        $ancestor = [System.Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($ancestor)
                    }
                    if (-not $ancestor) { throw "$Id has no ScrollItem, focus target or vertically scrolling ancestor." }
                    $bounds = $el.Current.BoundingRectangle; $window = $Designer.El.Current.BoundingRectangle
                    $amount = if (-not $bounds.IsEmpty -and $bounds.Top -lt $window.Top) {
                        [System.Windows.Automation.ScrollAmount]::SmallDecrement
                    } else { [System.Windows.Automation.ScrollAmount]::SmallIncrement }
                    $scroll.Scroll([System.Windows.Automation.ScrollAmount]::NoAmount, $amount)
                }
            }
        } catch { $result.errors.Add($_.Exception.Message); $stable = 0 }
        Start-Sleep -Milliseconds 150
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $result.settled) { $result.errors.Add("$Id did not reach settled finite, nonempty in-window UIA bounds within 8 s.") }
    $result
}
function Get-P2FocusTarget($Designer, [string] $Id) {
    $el = Assert-P2Control $Designer $Id
    if ($Id -in $script:p2NumberBoxes) {
        $input = @($el.FindAll($Scope::Descendants, [System.Windows.Automation.Condition]::TrueCondition) |
            Where-Object { $_.Current.AutomationId -eq 'InputBox' -and
                $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Edit -and
                $_.Current.IsEnabled -and $_.Current.IsKeyboardFocusable }) | Select-Object -First 1
        if (-not $el.Current.IsEnabled -or -not $input) { throw "$Id has no enabled, focusable InputBox edit." }
        return $input
    }
    $el
}
function Set-P2Focus($Designer, [string] $Id) {
    $target = Get-P2FocusTarget $Designer $Id
    $target.SetFocus()
    $focused = Wait-For { [System.Windows.Automation.Automation]::Compare($target, $AE::FocusedElement) } 2 50
    if (-not $focused) { throw "Focus did not reach $Id's resolved UIA target." }
}
function Get-P2TabOrder($Designer, [string[]] $Ids) {
    foreach ($id in $Ids) {
        $el = Assert-P2Control $Designer $id
        if ($el.Current.IsEnabled -and (Get-P2FocusTarget $Designer $id).Current.IsKeyboardFocusable) { $id }
    }
}
function Get-P2PopupControl($Designer, [string] $Id) {
    $local = Get-P2Control $Designer $Id
    if ($local) { return $local }
    @($AE::RootElement.FindAll($Scope::Descendants, [System.Windows.Automation.Condition]::TrueCondition) |
        Where-Object { $_.Current.ProcessId -eq $Designer.Run.App.Id -and $_.Current.AutomationId -eq $Id }) |
        Select-Object -First 1
}
function Get-P2PickerHex($Designer) {
    $picker = Get-P2PopupControl $Designer 'ColourPicker'
    if (-not $picker) { throw 'Native ColorPicker missing from designer popup UIA.' }
    $field = Find-Element $picker 'AutomationId' 'HexTextBox' 2
    if ($field) { return $field }
    $field = @($picker.FindAll($Scope::Descendants, [System.Windows.Automation.Condition]::TrueCondition) |
        Where-Object { $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Edit -and
            $_.Current.Name -like '*Hexadecimal*' }) | Select-Object -First 1
    if ($field) { return $field }
    # Flyout visuals may be hosted outside the designer HWND. Still require a native edit in this app's popup.
    $field = @($AE::RootElement.FindAll($Scope::Descendants, [System.Windows.Automation.Condition]::TrueCondition) |
        Where-Object { $_.Current.ProcessId -eq $Designer.Run.App.Id -and
            $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Edit -and
            ($_.Current.AutomationId -eq 'HexTextBox' -or $_.Current.Name -like '*Hexadecimal*') }) |
        Select-Object -First 1
    if (-not $field) { throw 'Native ColorPicker HexTextBox/Hexadecimal edit is missing from UIA.' }
    $field
}
function Save-P2DesignerDiagnostics($Run, [string] $Label, $Expected = $null, [switch] $SkipHook) {
    $evidence = [ordered]@{ expected = $Expected; native = $null; lastNative = Get-Prop $Run 'P2LastDesignerHook'
        selectedRows = @(); dialogTitles = @(); tree = @(); screenshot = $null; errors = [Collections.Generic.List[string]]::new() }
    if (-not $SkipHook) {
        try { $evidence.native = Get-P2DesignerHook $Run } catch { $evidence.errors.Add("Native snapshot: $($_.Exception.Message)") }
    }
    try {
        $hwnd = [ObsE2E]::Find([uint32] $Run.App.Id, 'Overlay designer')
        $evidence['hwnd'] = $hwnd.ToInt64()
        if ($hwnd -eq [IntPtr]::Zero) { $hwnd = [ObsE2E]::Find([uint32] $Run.App.Id, $null); $evidence['hwnd'] = $hwnd.ToInt64() }
        if ($hwnd -ne [IntPtr]::Zero) {
            $root = $AE::FromHandle($hwnd)
            $evidence.tree = @(@($root) + @($root.FindAll($Scope::Descendants, [System.Windows.Automation.Condition]::TrueCondition)) |
                ForEach-Object {
                    try {
                        $entry = Describe $_; $bounds = $_.Current.BoundingRectangle
                        $entry['bounds'] = [ordered]@{ x = $bounds.X; y = $bounds.Y; width = $bounds.Width; height = $bounds.Height }
                        $entry['IsOffscreen'] = $_.Current.IsOffscreen
                        $entry['HasKeyboardFocus'] = $_.Current.HasKeyboardFocus
                        if ($_.Current.ControlType -eq [System.Windows.Automation.ControlType]::ListItem) {
                            $entry['IsSelected'] = (Get-Pattern $_ ([System.Windows.Automation.SelectionItemPattern])).Current.IsSelected
                        }
                        $entry
                    } catch { [ordered]@{ error = $_.Exception.Message } }
                })
            $evidence.selectedRows = @($evidence.tree | Where-Object { (Get-Prop $_ 'IsSelected') -eq $true })
            $evidence.dialogTitles = @(Get-P2ModalTitles ([pscustomobject]@{ Hwnd = $hwnd; El = $root; Run = $Run }))
            $evidence.screenshot = Save-WindowShot $hwnd $Label
        }
    } catch { $evidence.errors.Add("UIA snapshot: $($_.Exception.Message)") }
    $nativeTitle = Get-Prop (Get-Prop $evidence.native 'state') 'dialogTitle'
    if ($nativeTitle) { $evidence.dialogTitles = @($evidence.dialogTitles + @($nativeTitle) | Sort-Object -Unique) }
    Save-P2Evidence "$($Run.Name)-$Label" $evidence
}
function Get-P2ModalTitles($Designer) {
    $Designer.El = $AE::FromHandle($Designer.Hwnd)
    @($Designer.El.FindAll($Scope::Descendants, [System.Windows.Automation.Condition]::TrueCondition) |
        Where-Object { -not $_.Current.IsOffscreen -and ($_.Current.Name -match '^(Save changes to|Discard changes to|Delete .*\?|Saving…|Deleting…|The overlay was turned off)' -or
            $_.Current.AutomationId -eq 'Title' -and $_.Current.Name -ne 'Overlay designer') } |
        ForEach-Object { $_.Current.Name } | Sort-Object -Unique)
}
function Wait-P2EffectiveDraft($Designer, $SourceId, $Theme, [string] $Label, [string] $PreviousKey = $null) {
    $last = @{ snapshot = $null; modal = @() }
    try {
        $ready = Wait-For {
            $last.snapshot = Get-P2DesignerHook $Designer.Run
            $last.modal = @(Get-P2ModalTitles $Designer)
            $s = $last.snapshot.state
            if ($last.modal.Count -gt 0 -or (Get-Prop $s 'dialogActive') -eq $true) {
                throw 'Unexpected modal while awaiting a clean effective draft.'
            }
            if ($last.snapshot.open -and $s.sourceId -ceq $SourceId -and
                $null -ne $s.options -and $s.options.Theme -eq $Theme -and $s.draftKey -and
                (-not $PreviousKey -or $s.draftKey -ne $PreviousKey)) {
                if ($s.dirty -ne $false -or $s.draftRev -ne $s.lastSavedRev) {
                    throw 'Effective draft became dirty without an edit.'
                }
                # A second dispatcher snapshot catches delayed programmatic TextChanged echoes.
                Start-Sleep -Milliseconds 200
                $settled = Get-P2DesignerHook $Designer.Run
                $modal = @(Get-P2ModalTitles $Designer)
                if (-not $settled.open -or $settled.state.sourceId -cne $SourceId -or $settled.state.options.Theme -ne $Theme -or
                    $settled.state.draftKey -ne $s.draftKey -or $settled.state.dirty -ne $false -or
                    $settled.state.draftRev -ne $s.draftRev -or $settled.state.lastSavedRev -ne $s.lastSavedRev -or
                    $modal.Count -gt 0 -or (Get-Prop $settled.state 'dialogActive') -eq $true) {
                    throw 'Clean effective draft did not remain stable.'
                }
                $settled
            }
        } 10 150
        if (-not $ready) { throw 'Effective sourceId/theme/new draftKey did not settle within 10 s.' }
        $ready
    } catch {
        $reason = $_.Exception.Message
        $path = Save-P2DesignerDiagnostics $Designer.Run $Label ([ordered]@{
            sourceId = $SourceId; theme = $Theme; previousKey = $PreviousKey; last = $last; reason = $reason })
        throw "$reason Evidence: $path"
    }
}
function Open-P2Designer($Run, [switch] $Settings) {
    [void] (Wait-BenchReady $Run.Root)
    if ($Settings) {
        $settingsWindow = Open-ObsSettings $Run.App
        $button = Get-ObsControl $settingsWindow 'ObsDesignerButton'
        if (-not $button -or -not $button.Current.IsEnabled) { throw 'Settings OBS designer button unavailable.' }
        Invoke-Element $button
    } else {
        Send-ObsHookCommand $Run.Root 'command-obs-designer-open' | Out-Null
        $settingsWindow = $null
    }
    $designer = Get-P2Designer $Run
    $designer | Add-Member -NotePropertyName Settings -NotePropertyValue $settingsWindow
    $previousKey = Get-Prop $Run 'P2ClosedDraftKey'
    $opened = Wait-For {
        $s = Get-P2DesignerHook $Run
        if ($s.open -and $s.state.draftKey -and (-not $previousKey -or $s.state.draftKey -ne $previousKey)) { $s }
    } 10 150
    if (-not $opened) {
        $path = Save-P2DesignerDiagnostics $Run 'designer-reopen' @{ previousKey = $previousKey }
        throw "Designer did not open with a fresh draftKey; evidence: $path"
    }
    $designer | Add-Member -NotePropertyName OpenedHook -NotePropertyValue $opened
    $designer
}
function Close-P2Designer($Designer, [switch] $Cleanup) {
    if (-not $Designer -or $Designer.Run.App.HasExited) { return }
    try {
        $before = Get-P2DesignerHook $Designer.Run
        if (-not $before.open -and [ObsE2E]::Find([uint32] $Designer.Run.App.Id, 'Overlay designer') -eq [IntPtr]::Zero) { return }
        Send-ObsHookCommand $Designer.Run.Root 'command-obs-designer-close' | Out-Null
        $closed = Wait-For {
            $s = Get-P2DesignerHook $Designer.Run
            if (-not $s.open -and [ObsE2E]::Find([uint32] $Designer.Run.App.Id, 'Overlay designer') -eq [IntPtr]::Zero) { $s }
            elseif (-not $Cleanup -and (Get-Prop $s.state 'dialogActive') -eq $true) { throw 'Designer close unexpectedly requires a modal choice.' }
        } $(if ($Cleanup) { 1 } else { 12 }) 150
        if (-not $closed) { throw 'Designer window did not genuinely close.' }
        $Designer.Run | Add-Member -NotePropertyName P2ClosedDraftKey -NotePropertyValue $before.state.draftKey -Force
    } catch {
        $reason = $_.Exception.Message
        $path = Save-P2DesignerDiagnostics $Designer.Run 'designer-close' @{ reason = $reason }
        if (-not $Cleanup) { throw "$reason Evidence: $path" }
    } finally {
        if ($Designer.Settings) { try { Close-Settings $Designer.Settings 'CancelButton' } catch { } }
    }
}
function Get-P2Value($El) { (Get-Pattern $El ([System.Windows.Automation.ValuePattern])).Current.Value }
function Set-P2Value($El, [string] $Value) { (Get-Pattern $El ([System.Windows.Automation.ValuePattern])).SetValue($Value) }
function Get-P2Result($Designer) { (Assert-P2Control $Designer 'DesignerResult').Current.Name }
function Get-P2Files($Run) { [ordered]@{ hash = Get-Sha256 (Join-Path $Run.Root 'data/obs-looks.json'); state = Get-Overlay (Get-State $Run.Root 'p2') 'previewNonces' } }
function Select-P2Item($Designer, [string] $Id, [string] $Name) {
    $combo = Assert-P2Control $Designer $Id
    (Get-Pattern $combo ([System.Windows.Automation.ExpandCollapsePattern])).Expand()
    $item = Find-Element $combo 'Name' $Name 1
    if (-not $item) {
        $item = @($AE::RootElement.FindAll($Scope::Descendants, [System.Windows.Automation.Condition]::TrueCondition) |
            Where-Object { $_.Current.ProcessId -eq $Designer.Run.App.Id -and $_.Current.Name -eq $Name -and
                $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::ListItem }) | Select-Object -First 1
    }
    if (-not $item) { throw "Picker $Id has no '$Name'." }
    (Get-Pattern $item ([System.Windows.Automation.SelectionItemPattern])).Select()
    Start-Sleep -Milliseconds 200
}
function Get-P2Text($Designer, [string] $Id) {
    $el = Assert-P2Control $Designer $Id
    if ($Id -in $script:p2NumberBoxes) {
        try { return (Get-Pattern $el ([System.Windows.Automation.RangeValuePattern])).Current.Value } catch { }
    }
    try { Get-P2Value $el } catch { $el.Current.Name }
}
function Get-P2Focus { Describe ($AE::FocusedElement) }
# Popup closure may briefly leave UIA with no focused peer; only an exact target match completes the wait.
function Wait-P2Focus($Run, [string] $Id, [double] $Seconds, [string] $Label) {
    $poll = [ordered]@{ expectedAutomationId = $Id; last = $null; errors = [Collections.Generic.List[string]]::new() }
    $focus = Wait-For {
        $poll.last = $null
        try {
            $poll.last = Get-P2Focus
            if ((Get-Prop $poll.last 'AutomationId') -ceq $Id) { $poll.last }
        } catch [System.Windows.Automation.ElementNotAvailableException] {
            $poll.errors.Add($_.Exception.Message)
        }
    } $Seconds
    if (-not $focus) { [void] (Save-P2DesignerDiagnostics $Run "$Label-focus-timeout" $poll) }
    $focus
}
function Get-P2PreviewState($Run) { Get-Overlay (Get-State $Run.Root 'preview') 'previewNonces' }
function Get-P2Nonce($Run) { Get-Prop (Get-P2PreviewState $Run) 'current' }
function Get-P2Http([string] $Path) { Invoke-RawHttp '127.0.0.1' (New-Request -Path $Path) }
function Get-P2DesignerHook($Run) {
    $path = Join-Path (Get-BenchDirectory $Run.Root) 'designer.json'
    try {
        Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue
        Send-ObsHookCommand $Run.Root 'command-obs-designer-snapshot' | Out-Null
        $result = Wait-For { if (Test-Path -LiteralPath $path) { Get-Content -Raw -LiteralPath $path | ConvertFrom-Json -Depth 16 } } 10
        if (-not $result -or $null -eq $result.open -or ($result.open -and
            ($null -eq $result.state -or $null -eq $result.state.PSObject.Properties['nonce']))) {
            throw 'Designer state hook returned no {open,state:{nonce,...}} designer.json.'
        }
        $Run | Add-Member -NotePropertyName P2LastDesignerHook -NotePropertyValue $result -Force
        $result
    } catch {
        $path = Save-P2DesignerDiagnostics $Run 'native-snapshot-timeout' @{ reason = $_.Exception.Message } -SkipHook
        throw "Designer snapshot failed; evidence: $path"
    }
}
function Get-P2PreviewPageState($Run) {
    $path = Join-Path (Get-BenchDirectory $Run.Root) 'preview-state.json'
    try {
        Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue
        Send-ObsHookCommand $Run.Root 'command-obs-preview-state-dump' | Out-Null
        $result = Wait-For { if (Test-Path -LiteralPath $path) { Get-Content -Raw -LiteralPath $path | ConvertFrom-Json -Depth 24 } } 10
        if (-not $result -or (Get-Prop $result 'error') -or $null -eq (Get-Prop $result 'counters')) {
            throw "Native preview state CDP dump unavailable: $(Get-Prop $result 'error')"
        }
        $result
    } catch {
        $path = Save-P2DesignerDiagnostics $Run 'preview-snapshot-timeout' @{ reason = $_.Exception.Message }
        throw "Native preview snapshot failed; evidence: $path"
    }
}
function Get-P2PreviewSecuritySnapshot($Run, [string] $Label) {
    $native = Get-P2DesignerHook $Run
    $ids = @(Get-ProcessTree $Run.App.Id $Run.Root)
    $windows = [Collections.Generic.List[object]]::new()
    [void] [ObsE2E]::EnumWindows([ObsE2E+EnumProc]{
        param($handle, $unused)
        [uint32] $ownerId = 0
        [void] [ObsE2E]::GetWindowThreadProcessId($handle, [ref] $ownerId)
        if ($ownerId -in $ids -and [ObsE2E]::IsWindowVisible($handle)) {
            $title = [Text.StringBuilder]::new(512)
            $class = [Text.StringBuilder]::new(256)
            [void] [ObsE2E]::GetWindowText($handle, $title, $title.Capacity)
            [void] [ObsE2E]::GetClassName($handle, $class, $class.Capacity)
            $windows.Add([ordered]@{ hwnd = $handle.ToInt64(); processId = $ownerId
                title = $title.ToString(); class = $class.ToString() })
        }
        return $true
    }, [IntPtr]::Zero)
    [ordered]@{
        qpc = Get-Qpc; native = $native; trustedUrl = Get-Prop $native 'previewUrl'; nonce = $native.state.nonce
        preview = Get-P2PreviewState $Run; hwndCount = $windows.Count
        windows = @($windows | Sort-Object { $_.hwnd })
        tree = @($ids | ForEach-Object { Get-Process -Id $_ -ErrorAction Stop } | Select-Object Id, ProcessName)
        diagnostics = Save-P2DesignerDiagnostics $Run $Label -SkipHook
    }
}
function Test-P2PreviewHostSecurity($Run) {
    $designer = $null
    $caseNames = @('wrongHost', 'wrongPath', 'wrongQuery', 'oldNonce', 'newWindow', 'download', 'permission')
    $results = [ordered]@{}
    $evidence = [ordered]@{ cases = [ordered]@{}; setup = $null; cleanup = $null; error = $null }
    $setupPassed = $false; $cleanupPassed = $false
    try {
        $designer = Open-P2Designer $Run
        $oldHost = Wait-For {
            $h = Get-P2DesignerHook $Run
            if ($h.open -and $h.state.navigated -and $h.state.state -eq 'Open') { $h }
        } 15 150
        if (-not $oldHost) { throw 'Initial preview did not reach its native Open state.' }
        $oldNonce = $oldHost.state.nonce
        Close-P2Designer $designer; $designer = $null
        $retired = Get-P2Http "/events?look=draft&pv=$oldNonce"
        $designer = Open-P2Designer $Run
        $opened = Wait-For {
            $h = Get-P2DesignerHook $Run
            if ($h.open -and $h.state.navigated -and $h.state.state -eq 'Open') { $h }
        } 15 150
        if (-not $opened) { throw 'Reopened preview did not reach its native Open state.' }
        $nonce = $opened.state.nonce
        $trustedUrl = "${overlayUrl}?look=draft&preview=1&pv=$nonce&sample=playing"
        $initial = Get-P2PreviewSecuritySnapshot $Run 'security-setup'
        $evidence.setup = [ordered]@{ oldHost = $oldHost; oldNonce = $oldNonce; retiredStatus = $retired.status
            trustedUrl = $trustedUrl; initial = $initial }
        $setupPassed = $retired.status -eq 410 -and $nonce -match '^[a-z0-9]{8}$' -and $nonce -cne $oldNonce -and
            $initial.trustedUrl -ceq $trustedUrl -and $initial.preview.current -ceq $nonce -and $initial.preview.open -eq 1 -and
            $initial.native.state.settings.hostObjects -eq $false -and $initial.native.state.settings.webMessages -eq $false -and
            @($initial.tree | Where-Object { $_.ProcessName -eq 'msedgewebview2' }).Count -gt 0
        if (-not $setupPassed) { throw 'Trusted preview/retired nonce prerequisites failed; see setup evidence.' }
        $specs = @(
            @{ name = 'wrongHost'; kind = 'navigation'; url = $trustedUrl.Replace('localhost', '127.0.0.1') }
            @{ name = 'wrongPath'; kind = 'navigation'; url = $trustedUrl.Replace('/?', '/denied?') }
            @{ name = 'wrongQuery'; kind = 'navigation'; url = "$trustedUrl&unexpected=1" }
            @{ name = 'oldNonce'; kind = 'navigation'; url = $trustedUrl.Replace("pv=$nonce", "pv=$oldNonce") }
            @{ name = 'newWindow'; kind = 'new-window' }
            @{ name = 'download'; kind = 'download' }
            @{ name = 'permission'; kind = 'permission' }
        )
        foreach ($spec in $specs) {
            $entry = [ordered]@{ request = $spec; before = $null; decisionStartIndex = $null
                response = $null; after = $null; newDecisions = @(); matchedDecisions = @(); error = $null }
            $passed = $false
            try {
                $entry.before = Get-P2PreviewSecuritySnapshot $Run "security-$($spec.name)-before"
                $baseline = @($entry.before.native.state.navigation)
                $entry.decisionStartIndex = $baseline.Count
                if ($spec.kind -eq 'navigation') {
                    Send-ObsHookCommand $Run.Root 'command-obs-designer-navigate' $spec.url | Out-Null
                } else {
                    $responsePath = Join-Path (Get-BenchDirectory $Run.Root) 'designer-security-probe.json'
                    Remove-Item -LiteralPath $responsePath -ErrorAction SilentlyContinue
                    Send-ObsHookCommand $Run.Root 'command-obs-designer-security-probe' $spec.kind | Out-Null
                    $entry.response = Wait-For {
                        if (Test-Path -LiteralPath $responsePath) {
                            Get-Content -Raw -LiteralPath $responsePath | ConvertFrom-Json -Depth 32
                        }
                    } 12 150
                    if (-not $entry.response) { throw 'Security probe produced no fresh command response.' }
                }
                $decisionSeen = Wait-For {
                    $h = Get-P2DesignerHook $Run
                    $delta = @($h.state.navigation | Select-Object -Skip $baseline.Count)
                    if (@($delta | Where-Object { $_.kind -ceq $spec.kind }).Count -gt 0) { $h }
                } 10 150
                $entry.after = Get-P2PreviewSecuritySnapshot $Run "security-$($spec.name)-after"
                $all = @($entry.after.native.state.navigation)
                $entry.newDecisions = @($all | Select-Object -Skip $baseline.Count)
                $entry.matchedDecisions = @($entry.newDecisions | Where-Object {
                    $_.kind -ceq $spec.kind -and ($spec.kind -ne 'navigation' -or $_.uri -ceq $spec.url)
                })
                $prefix = @($all | Select-Object -First $baseline.Count)
                $prefixUnchanged = (ConvertTo-Json -InputObject $prefix -Depth 16 -Compress) -ceq
                    (ConvertTo-Json -InputObject $baseline -Depth 16 -Compress)
                $stable = $true
                foreach ($snapshot in @($entry.before, $entry.after)) {
                    $stable = $stable -and $snapshot.native.open -eq $true -and $snapshot.native.state.navigated -eq $true -and
                        $snapshot.native.state.state -ceq 'Open' -and $snapshot.trustedUrl -ceq $trustedUrl -and
                        $snapshot.nonce -ceq $nonce -and $snapshot.preview.current -ceq $nonce -and $snapshot.preview.open -eq 1 -and
                        $snapshot.native.state.draftKey -ceq $initial.native.state.draftKey -and
                        $snapshot.native.state.settings.hostObjects -eq $false -and $snapshot.native.state.settings.webMessages -eq $false -and
                        $snapshot.native.state.hostVisible -eq $true -and $snapshot.hwndCount -eq $initial.hwndCount -and
                        (@($snapshot.windows | ForEach-Object { $_.hwnd }) -join ',') -ceq
                            (@($initial.windows | ForEach-Object { $_.hwnd }) -join ',')
                }
                $nativeDenied = $decisionSeen -and $prefixUnchanged -and $entry.matchedDecisions.Count -gt 0 -and
                    @($entry.matchedDecisions | Where-Object { $_.allowed -ne $false }).Count -eq 0 -and
                    @($entry.newDecisions | Where-Object { $_.allowed -ne $false }).Count -eq 0
                $probePassed = $true
                if ($spec.kind -ne 'navigation') {
                    $response = $entry.response
                    $js = Get-Prop (Get-Prop (Get-Prop $response 'javascript') 'result') 'value'
                    $nativeEvents = @($response.nativeEvents | Where-Object { $_.kind -ceq $spec.kind })
                    $completed = @($entry.after.native.commands.history | Where-Object {
                        $_.id -eq $response.commandId -and $_.command -ceq 'command-obs-designer-security-probe' -and $_.stage -ceq 'complete'
                    })
                    $probePassed = $response.kind -ceq $spec.kind -and -not $response.error -and $completed.Count -eq 1 -and
                        $response.commandId -gt $entry.before.native.commands.lastCommand.id -and
                        $response.decisionStartIndex -eq $baseline.Count -and $response.sourceBefore -ceq $trustedUrl -and
                        $response.sourceAfter -ceq $trustedUrl -and $js.kind -ceq $spec.kind -and
                        -not (Get-Prop $response.javascript 'exceptionDetails') -and $nativeEvents.Count -gt 0 -and
                        @($response.decisions | Where-Object { $_.kind -ceq $spec.kind -and $_.allowed -eq $false }).Count -gt 0
                    switch ($spec.kind) {
                        'new-window' { $probePassed = $probePassed -and $js.blocked -eq $true -and
                            @($nativeEvents | Where-Object { $_.handled -ne $true }).Count -eq 0 }
                        'download' { $probePassed = $probePassed -and $js.clicked -eq $true -and
                            @($nativeEvents | Where-Object { $_.cancel -ne $true }).Count -eq 0 }
                        'permission' { $probePassed = $probePassed -and $js.rejected -eq $true -and $js.errorCode -eq 1 -and
                            @($nativeEvents | Where-Object { $_.state -cne 'Deny' }).Count -eq 0 }
                    }
                }
                $passed = [bool] ($nativeDenied -and $stable -and $probePassed)
                if (-not $decisionSeen) { $entry.error = 'Probe did not reach the required native handler; no denial inferred.' }
            } catch {
                $entry.error = $_.Exception.Message
                if (-not $entry.after) {
                    try { $entry.after = Get-P2PreviewSecuritySnapshot $Run "security-$($spec.name)-failed" }
                    catch { $entry['snapshotError'] = $_.Exception.Message }
                }
            }
            $results[$spec.name] = $passed
            $entry['evidence'] = Save-P2Evidence "security-$($spec.name)" $entry
            $evidence.cases[$spec.name] = $entry
            Add-Check "A-SEC.previewHost.$($spec.name)" 'fresh native denial; trusted URL/nonce/preview host retained; no extra HWND' $entry $passed
        }
    } catch {
        $evidence.error = $_.Exception.Message
        try { $evidence['diagnostics'] = Save-P2DesignerDiagnostics $Run 'security-failed' }
        catch { $evidence['diagnosticsError'] = $_.Exception.Message }
    } finally {
        try {
            if (-not $designer -and [ObsE2E]::Find([uint32] $Run.App.Id, 'Overlay designer') -ne [IntPtr]::Zero) {
                $designer = Get-P2Designer $Run
                $designer | Add-Member -NotePropertyName Settings -NotePropertyValue $null
            }
            if ($designer) { Close-P2Designer $designer; $designer = $null }
            $closed = Wait-For {
                $h = Get-P2DesignerHook $Run; $p = Get-P2PreviewState $Run
                $hwnd = [ObsE2E]::Find([uint32] $Run.App.Id, 'Overlay designer')
                if (-not $h.open -and $hwnd -eq [IntPtr]::Zero -and $p.open -eq 0 -and -not $p.current) {
                    [ordered]@{ native = $h; preview = $p; hwnd = $hwnd.ToInt64() }
                }
            } 12 150
            $evidence.cleanup = $closed
            $cleanupPassed = [bool] $closed
        } catch { $evidence.cleanup = [ordered]@{ error = $_.Exception.Message } }
        if ($designer) { Close-P2Designer $designer -Cleanup }
        foreach ($name in $caseNames) {
            if (-not $results.Contains($name)) {
                $results[$name] = $false
                Add-Blocked "A-SEC.previewHost.$name" 'actual native denial with retained trusted preview host' (
                    "Security setup/probe interrupted: $($evidence.error); see p2-security-preview-host.json")
            }
        }
        Add-Check 'A-SEC.previewHost.lifecycle' 'verified close removes designer HWND, current nonce and preview stream' $evidence.cleanup $cleanupPassed
        $evidence['caseResults'] = $results
        $path = Save-P2Evidence 'security-preview-host' $evidence
        Add-Check 'A-SEC.previewHostHandler' 'all seven native denial probes pass with verified lifecycle cleanup' (
            [ordered]@{ evidence = $path; setupPassed = $setupPassed; cases = $results; cleanupPassed = $cleanupPassed }) (
            $setupPassed -and $cleanupPassed -and @($results.Values | Where-Object { -not $_ }).Count -eq 0)
    }
}
function Set-P2Range($Designer, [string] $Id, [double] $Value) {
    (Get-Pattern (Assert-P2Control $Designer $Id) ([System.Windows.Automation.RangeValuePattern])).SetValue($Value)
}
function Get-P2TabTrace($Designer, [string] $FirstId, [int] $Count, [bool] $Reverse = $false) {
    Add-Type -AssemblyName System.Windows.Forms
    Set-P2Focus $Designer $FirstId
    $seen = [Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $Count; $i++) {
        $focused = $AE::FocusedElement
        $entry = Describe $focused
        # NumberBox focuses its inner editable TextBox; attribute the stop to the named enclosing NumberBox.
        if ($entry -and (Get-Prop $entry 'AutomationId') -notin $script:p2NumberBoxes) {
            $ancestor = $focused
            for ($depth = 0; $ancestor -and $depth -lt 8; $depth++) {
                if ($ancestor.Current.AutomationId -in $script:p2NumberBoxes) {
                    $entry['FocusedChild'] = $entry.AutomationId
                    $entry['AutomationId'] = $ancestor.Current.AutomationId
                    break
                }
                $ancestor = [System.Windows.Automation.TreeWalker]::RawViewWalker.GetParent($ancestor)
            }
        }
        $seen.Add($entry)
        [System.Windows.Forms.SendKeys]::SendWait($(if ($Reverse) { '+{TAB}' } else { '{TAB}' }))
        Start-Sleep -Milliseconds 90
    }
    $seen.ToArray()
}
function Watch-P2Writes([string] $Root) {
    $watch = [IO.FileSystemWatcher]::new((Join-Path $Root 'data'), 'obs-looks.json*')
    $watch.IncludeSubdirectories = $false; $watch.EnableRaisingEvents = $true
    $token = [guid]::NewGuid().ToString('N')
    $eventNames = @('Created', 'Changed', 'Renamed', 'Deleted')
    $ids = @($eventNames | ForEach-Object { "p2-$token-$($_.ToLowerInvariant())" })
    for ($i = 0; $i -lt $ids.Count; $i++) {
        Register-ObjectEvent -InputObject $watch -EventName $eventNames[$i] -SourceIdentifier $ids[$i] | Out-Null
    }
    [pscustomobject]@{ Watch = $watch; SourceIdentifiers = $ids }
}
function Stop-P2Writes($Watcher) {
    if (-not $Watcher) { return @() }
    $Watcher.Watch.EnableRaisingEvents = $false
    $events = @($Watcher.SourceIdentifiers | ForEach-Object {
        $id = $_
        $found = @(Get-Event -SourceIdentifier $id -ErrorAction SilentlyContinue | ForEach-Object {
            [ordered]@{ type = $_.SourceEventArgs.ChangeType.ToString(); name = $_.SourceEventArgs.Name; oldName = (Get-Prop $_.SourceEventArgs 'OldName'); utc = $_.TimeGenerated.ToUniversalTime().ToString('o') }
        })
        Unregister-Event -SourceIdentifier $id -ErrorAction SilentlyContinue
        Remove-Event -SourceIdentifier $id -ErrorAction SilentlyContinue
        $found
    })
    $Watcher.Watch.Dispose()
    $events
}
function Get-P2Dialog($Run, [string] $Like) {
    Wait-For {
        $hwnd = [ObsE2E]::Find([uint32] $Run.App.Id, 'Overlay designer')
        if ($hwnd -ne [IntPtr]::Zero) {
            $root = $AE::FromHandle($hwnd)
            $foundTitles = @($root.FindAll($Scope::Descendants, [System.Windows.Automation.Condition]::TrueCondition) |
                Where-Object { $_.Current.Name -like $Like })
            if ($foundTitles.Count) { $root }
        }
    } 12 150
}
function Invoke-P2DialogChoice($Run, [string] $DialogName, [string] $Choice) {
    $dlg = Get-P2Dialog $Run $DialogName
    if (-not $dlg) { throw "Expected dialog '$DialogName' not shown." }
    $button = @($dlg.FindAll($Scope::Descendants, [System.Windows.Automation.Condition]::TrueCondition) |
        Where-Object { $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Button -and $_.Current.Name -eq $Choice }) |
        Select-Object -First 1
    if (-not $button) { throw "Dialog '$DialogName' has no '$Choice' button." }
    $text = @($dlg.FindAll($Scope::Descendants, [System.Windows.Automation.Condition]::TrueCondition) | ForEach-Object { $_.Current.Name })
    Invoke-Element $button
    $text
}
function Select-P2Look($Designer, [string] $Name, [switch] $ExpectPrompt) {
    $saved = @((Read-ObsLooksFile $Designer.Run.Root).looks | Where-Object { $_.name -ceq $Name }) | Select-Object -First 1
    if (-not $saved) { throw "Saved look '$Name' has no expected sourceId/theme in the looks file." }
    $themes = @('pill', 'matte', 'matte-light', 'standard', 'classic', 'simple', 'album-art', 'card')
    $theme = [array]::IndexOf($themes, [string] $saved.options.theme)
    if ($theme -lt 0) { throw "Saved look '$Name' has unknown theme '$($saved.options.theme)'." }
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    $rowName = '^' + [regex]::Escape($Name) + '(?:, [^,]+, \d+ connected| — \d+ connected)?$'
    $lastStale = $null
    do {
        try {
            # Count notifications rebuild the rows; never keep a list/row peer between polls.
            $Designer.El = $AE::FromHandle($Designer.Hwnd)
            $list = $Designer.El.FindFirst($Scope::Descendants,
                [System.Windows.Automation.PropertyCondition]::new($AE::AutomationIdProperty, 'SavedLooksList'))
            if ($list) {
                $row = @($list.FindAll($Scope::Descendants, [System.Windows.Automation.Condition]::TrueCondition) |
                    Where-Object { $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::ListItem -and
                        $_.Current.Name -cmatch $rowName }) | Select-Object -First 1
                if ($row) {
                    $selection = Get-Pattern $row ([System.Windows.Automation.SelectionItemPattern])
                    $selection.Select()
                    if ($selection.Current.IsSelected) {
                        if (-not $ExpectPrompt) {
                            [void] (Wait-P2EffectiveDraft $Designer $saved.id $theme "select-look-$Name")
                        }
                        return $row
                    }
                }
            }
        } catch [System.Windows.Automation.ElementNotAvailableException] { $lastStale = $_.Exception.Message }
        Start-Sleep -Milliseconds 150
    } while ([DateTime]::UtcNow -lt $deadline)
    $label = "select-look-$($Designer.Run.Name)-$Name"
    $evidence = [ordered]@{ requested = $Name; lastStale = $lastStale; seedFile = $null
        designer = $null; list = @(); screenshot = $null; errors = [Collections.Generic.List[string]]::new() }
    # Keep each independent observation even if a disappearing UIA peer prevents another.
    try {
        $seed = Join-Path $runDirectory ("p2-{0}-looks.json" -f (ConvertTo-SafeName $label))
        Copy-Item -LiteralPath (Join-Path $Designer.Run.Root 'data/obs-looks.json') -Destination $seed
        $evidence.seedFile = [IO.Path]::GetRelativePath($runDirectory, $seed)
    } catch { $evidence.errors.Add("Looks file copy: $($_.Exception.Message)") }
    try { $evidence.designer = Save-P2DesignerDiagnostics $Designer.Run $label @{ requested = $Name; sourceId = $saved.id; theme = $theme } }
    catch { $evidence.errors.Add("Designer snapshot: $($_.Exception.Message)") }
    try {
        $Designer.El = $AE::FromHandle($Designer.Hwnd)
        $list = Assert-P2Control $Designer 'SavedLooksList'
        $evidence.list = @(@($list) + @($list.FindAll($Scope::Descendants, [System.Windows.Automation.Condition]::TrueCondition)) |
            ForEach-Object {
                try {
                    $entry = Describe $_
                    $bounds = $_.Current.BoundingRectangle
                    $entry['bounds'] = [ordered]@{ x = $bounds.X; y = $bounds.Y; width = $bounds.Width; height = $bounds.Height }
                    $entry
                } catch { [ordered]@{ error = $_.Exception.Message } }
            })
    } catch { $evidence.errors.Add("Saved looks UIA: $($_.Exception.Message)") }
    $evidence.screenshot = Save-WindowShot $Designer.Hwnd $label
    if (-not $evidence.screenshot) { $evidence.errors.Add('Designer screenshot unavailable.') }
    $path = Save-P2Evidence $label $evidence
    throw "Saved look '$Name' was not present and selected within 10 s; evidence: $path"
}
function Get-P2DesignerSnapshot($Designer) {
    $run = $Designer.Run
    # The live size is intentionally debounced 300 ms; settle the read, not the rapid input sequence.
    Start-Sleep -Milliseconds 400
    [ordered]@{
        file = Get-Sha256 (Join-Path $run.Root 'data/obs-looks.json')
        name = Get-P2Text $Designer 'LookNameBox'
        width = Get-P2Text $Designer 'WidthBox'
        size = (Assert-P2Control $Designer 'SourceSizeText').Current.Name
        result = Get-P2Result $Designer
        focused = Get-P2Focus
        save = Describe (Get-P2Control $Designer 'SaveLookButton')
        revert = Describe (Get-P2Control $Designer 'RevertChangesButton')
        designer = Get-P2DesignerHook $run
    }
}
function Test-P2NonceTimeline($Designer, [string] $Label, [int] $Switches = 12) {
    $run = $Designer.Run
    $first = Wait-For { $v = Get-P2Nonce $run; if ($v -match '^[a-z0-9]{8}$') { $v } } 20
    $timeline = [Collections.Generic.List[object]]::new()
    $baseline = Get-State $run.Root 'nonce-before'
    $unknown = if ($first -eq 'zzzzzzzz') { 'yyyyyyyy' } else { 'zzzzzzzz' }
    $bad = Get-P2Http "/events?look=draft&pv=$unknown"
    $afterBad = Get-State $run.Root 'nonce-bad'
    Add-Check "$Label.unknownNonce" '410, no total/real/by-look/preview-count changes' ([ordered]@{ status = $bad.status; before = $baseline.overlay; after = $afterBad.overlay }) (
        $bad.status -eq 410 -and (Get-Overlay $baseline 'streams') -eq (Get-Overlay $afterBad 'streams') -and
        (Get-Overlay $baseline 'realStreams') -eq (Get-Overlay $afterBad 'realStreams') -and
        ((Get-Overlay $baseline 'streamsByLook') | ConvertTo-Json -Compress) -ceq
            ((Get-Overlay $afterBad 'streamsByLook') | ConvertTo-Json -Compress) -and
        (Get-Overlay $baseline 'previewNonces').open -eq (Get-Overlay $afterBad 'previewNonces').open)
    $previous = $first
    for ($i = 0; $i -lt $Switches; $i++) {
        $source = $(if ($i % 2 -eq 0) { 'Current song' } else { 'Sample song' })
        Select-P2Item $Designer 'PreviewSongSourcePicker' $source
        $current = Wait-For { $v = Get-P2Nonce $run; if ($v -and $v -ne $previous) { $v } } 12
        $old = Get-P2Http "/events?look=draft&pv=$previous"
        $wantReal = [int] (Get-Overlay $baseline 'realStreams') + $(if ($source -eq 'Current song') { 1 } else { 0 })
        $state = Wait-For {
            $s = Get-State $run.Root "nonce-$i"
            if ((Get-Prop (Get-Overlay $s 'previewNonces') 'open') -eq 1 -and (Get-Overlay $s 'realStreams') -eq $wantReal) { $s }
        } 8 250
        $afterOld = Get-State $run.Root "nonce-old-$i"
        $timeline.Add([ordered]@{ index = $i; source = $source; previous = $previous; current = $current; oldStatus = $old.status
            streams = Get-Overlay $state 'streams'; real = Get-Overlay $state 'realStreams'; previewNonces = Get-Overlay $state 'previewNonces'
            afterOld = $afterOld.overlay; byLook = Get-Overlay $state 'streamsByLook' })
        Add-Check "$Label.switch$i" 'old nonce 410, one designer stream, unchanged counts/by-look, expected real demand' $timeline[$i] (
            $state -and $current -and $old.status -eq 410 -and $timeline[$i].real -eq $wantReal -and
            (Get-Prop (Get-Overlay $state 'previewNonces') 'open') -eq 1 -and
            (Get-Overlay $afterOld 'streams') -eq $timeline[$i].streams -and
            (Get-Overlay $afterOld 'realStreams') -eq $timeline[$i].real -and
            ((Get-Overlay $afterOld 'streamsByLook') | ConvertTo-Json -Compress) -ceq ($timeline[$i].byLook | ConvertTo-Json -Compress))
        if ($i -eq 0 -and (Get-Overlay $baseline 'realStreams') -eq 0) {
            $readStart = Get-State $run.Root 'preview-read-start'
            Start-Sleep -Seconds 3
            $readEnd = Get-State $run.Root 'preview-read-end'
            $readStats = Get-ReadStats $readStart $readEnd
            Add-Check "$Label.currentReads" 'current-song preview counts as Real and triggers overlay reads' $readStats ($readStats.overlay -ge 1)
        }
        $previous = $current
    }
    $oldFirst = Get-P2Http "/events?look=draft&pv=$first"
    $final = Get-State $run.Root 'nonce-first-retired'
    $last = $timeline[$timeline.Count - 1]
    Add-Check "$Label.firstNonceRetired" 'first nonce stays 410 after switches; total/real/by-look counts unchanged' ([ordered]@{
        status = $oldFirst.status; before = $last; after = $final.overlay }) (
        $oldFirst.status -eq 410 -and (Get-Overlay $final 'streams') -eq $last.streams -and
        (Get-Overlay $final 'realStreams') -eq $last.real -and
        ((Get-Overlay $final 'streamsByLook') | ConvertTo-Json -Compress) -ceq ($last.byLook | ConvertTo-Json -Compress) -and
        (Get-Prop (Get-Overlay $final 'previewNonces') 'open') -eq 1)
    [ordered]@{ first = $first; current = $previous; switches = $timeline.ToArray() }
}
function Test-AFont {
    if (-not (Test-ChromeAvailable 'A-FONT')) { return }
    $run = $null; $designer = $null; $chrome = $null; $evidence = [ordered]@{}
    try {
        $run = Start-OverlayRun 'A-FONT' @{} 'PlayingLong' -NoReader
        [void] (Wait-BenchReady $run.Root)
        Send-ObsHookCommand $run.Root 'command-obs-fonts-dump' | Out-Null
        $path = Join-Path (Get-BenchDirectory $run.Root) 'fonts.json'
        $dump = Wait-For { if (Test-Path $path) { Get-Content -Raw $path | ConvertFrom-Json -Depth 16 } } 10
        $families = @((Get-Prop $dump 'families') | Where-Object { $_ })
        $evidence.fonts = $dump
        Add-Check 'A-FONT.enumeration' '>=10 unique canonical/display, aliases <=64 UTF-16 units, Segoe UI and Arial' ([ordered]@{ count = $families.Count; error = Get-Prop $dump 'error'; truncated = Get-Prop $dump 'truncated' }) (
            $families.Count -ge 10 -and $families.Count -le 2000 -and -not (Get-Prop $dump 'error') -and -not (Get-Prop $dump 'truncated') -and
            @($families | Where-Object { -not $_.canonical -or -not $_.display -or $_.canonical.Length -gt 64 -or $_.display.Length -gt 64 -or
                @($_.aliases | Where-Object { -not $_ -or $_.Length -gt 64 }).Count -gt 0 }).Count -eq 0 -and
            @($families.canonical | Sort-Object -Unique).Count -eq $families.Count -and 'Segoe UI' -in $families.canonical -and 'Arial' -in $families.canonical)
        $alias = $families | Where-Object { $f = $_; @($f.aliases | Where-Object { $_ -ne $f.canonical -and $_.Length -le 64 }).Count -gt 0 } | Select-Object -First 1
        $aliasName = if ($alias) { @($alias.aliases | Where-Object { $_ -ne $alias.canonical -and $_.Length -le 64 })[0] } else { $null }
        $cases = @(
            @{ label = 'english'; id = 'font0001'; family = 'Segoe UI'; expected = $true; rendered = 'Segoe UI' }
            @{ label = 'missing'; id = 'font0002'; family = 'NativuneNotInstalledNever'; expected = $false; rendered = $null }
        )
        if ($aliasName) { $cases += @{ label = 'localized'; id = 'font0003'; family = $aliasName; expected = $true; rendered = $alias.canonical } }
        else { Add-Blocked 'A-FONT.localizedAlias' 'installed localized alias in the OS font collection' 'No distinct installed alias reported on this PC.' }
        $looks = @($cases | ForEach-Object {
            $opt = Get-ThemeDefaults 'matte'; $opt['font'] = $_.family
            New-ObsLook $_.id $_.label $opt
        })
        [void] (Write-ObsLooksFile $run.Root (ConvertTo-ObsLooksJson (New-ObsLooksDocument $looks)))
        Send-ObsHookCommand $run.Root 'command-obs-looks-reload' | Out-Null
        $designer = Open-P2Designer $run
        $evidence.picker = Describe (Assert-P2Control $designer 'FontPicker')
        $chrome = Start-Chrome 'A-FONT'
        foreach ($case in $cases) {
            # Reset-ChromeCasePage replaces the CDP target; domains must be enabled on each new session.
            [void] (Invoke-Cdp $chrome 'DOM.enable'); [void] (Invoke-Cdp $chrome 'CSS.enable')
            $reader = Start-SseReader "font-$($case.label)" 30 "/events?look=$($case.id)&sample=playing"
            try {
                $lookEvent = Wait-SseLook $reader { param($l) (Get-Prop $l 'id') -eq $case.id } 20
                Add-Check "A-FONT.$($case.label).availability" $case.expected (Get-Prop $lookEvent.data 'fontAvailable') (
                    $lookEvent -and (Get-Prop $lookEvent.data 'fontAvailable') -eq $case.expected)
                [void] (Invoke-ChromeNavigate $chrome ($overlayUrl + "?look=$($case.id)&sample=playing"))
                $probe = Wait-For { $p = Get-PageProbe $chrome; if ((Get-PageField $p 'connection') -eq 'open' -and (Get-PageField $p 'title') -eq 'Sample song') { $p } } 20
                $document = Invoke-Cdp $chrome 'DOM.getDocument'
                $node = Invoke-Cdp $chrome 'DOM.querySelector' @{ nodeId = $document.root.nodeId; selector = '#title' }
                $font = Invoke-Cdp $chrome 'CSS.getPlatformFontsForNode' @{ nodeId = $node.nodeId }
                $titleStyle = Invoke-Cdp $chrome 'Runtime.evaluate' @{ expression = "getComputedStyle(document.getElementById('title')).fontFamily"; returnByValue = $true }
                $titleFontFamily = Get-Prop (Get-Prop $titleStyle 'result') 'value'
                $fallbackStack = '"Segoe UI Variable Display", "Segoe UI", Arial, sans-serif'
                $rendered = @((Get-Prop $font 'fonts') | Where-Object {
                    $family = Get-Prop $_ 'familyName'; $face = Get-Prop $_ 'postScriptName'
                    [int] (Get-Prop $_ 'glyphCount') -gt 0 -and $(if ($case.expected) { $family -in @($case.rendered, $case.family) } else {
                        $family -in @('Segoe UI Variable Display', 'Segoe UI', 'Arial', 'sans-serif') -or
                            ($family -ceq 'Segoe UI Variable' -and $face -cmatch '^Segoe-UI-Variable-Display(?:-|$)')
                    })
                })
                $evidence[$case.label] = [ordered]@{ look = $lookEvent.data; page = $probe; chromeFonts = $font
                    titleFontFamily = $titleFontFamily; titleStyle = $titleStyle; expected = $case }
                Add-Check "A-FONT.$($case.label).rendered" 'nonempty, error-free Chrome title glyphs rendered from selected family or fallback' $font (
                    -not (Get-Prop $font 'error') -and $rendered.Count -gt 0)
                # The preview must actually be editing this saved row; unrelated preview fonts cannot satisfy the oracle.
                $evidence["$($case.label)SelectionBefore"] = Save-P2DesignerDiagnostics $run "font-$($case.label)-before-selection"
                [void] (Select-P2Look $designer $case.label)
                $evidence["$($case.label)SelectionAfter"] = Save-P2DesignerDiagnostics $run "font-$($case.label)-after-selection"
                $previewPath = Join-Path (Get-BenchDirectory $run.Root) 'preview-fonts.json'
                $fontDump = @{ last = $null; page = $null }
                $preview = Wait-For {
                    $state = Get-P2DesignerHook $run
                    if ($state.state.sourceId -ne $case.id -or $state.state.state -ne 'Open') { return }
                    $fontDump.page = Get-P2PreviewPageState $run
                    if ($fontDump.page.theme -ne 'matte' -or $fontDump.page.options.font -cne $case.family -or
                        $fontDump.page.fontAvailable -ne $case.expected) { return }
                    Remove-Item -LiteralPath $previewPath -ErrorAction SilentlyContinue
                    Send-ObsHookCommand $run.Root 'command-obs-preview-fonts-dump' | Out-Null
                    $candidate = Wait-For {
                        if (Test-Path -LiteralPath $previewPath) { Get-Content -Raw -LiteralPath $previewPath | ConvertFrom-Json -Depth 16 }
                    } 10 50
                    if ($candidate) {
                        $fontDump.last = $candidate
                        if ((Get-Prop $candidate 'error') -or @((Get-Prop $candidate 'fonts') |
                            Where-Object { [int] (Get-Prop $_ 'glyphCount') -gt 0 }).Count) { $candidate }
                    }
                } 12 300
                $evidence["$($case.label)Preview"] = $(if ($preview) { $preview } else { $fontDump.last })
                $evidence["$($case.label)PreviewPage"] = $fontDump.page
                if (-not $preview) {
                    $evidence["$($case.label)PreviewTimeout"] = Save-P2DesignerDiagnostics $run "font-$($case.label)-preview-timeout" $fontDump.last
                }
                $chromeFamilies = @((Get-Prop $font 'fonts') | Where-Object { [int] (Get-Prop $_ 'glyphCount') -gt 0 } |
                    ForEach-Object { Get-Prop $_ 'familyName' } | Sort-Object -Unique)
                $previewFamilies = @((Get-Prop $preview 'fonts') | Where-Object { [int] (Get-Prop $_ 'glyphCount') -gt 0 } |
                    ForEach-Object { Get-Prop $_ 'familyName' } | Sort-Object -Unique)
                $previewError = Get-Prop $evidence["$($case.label)Preview"] 'error'
                if (-not $preview -and -not $previewError) { $previewError = 'Preview font dump missing, empty or without rendered glyphs after 12 s.' }
                Add-Check "A-FONT.$($case.label).preview" 'nonempty, error-free preview CDP glyph families equal Chrome title glyph families' ([ordered]@{
                    chrome = $chromeFamilies; preview = $previewFamilies; payload = $evidence["$($case.label)Preview"]; error = $previewError }) (
                    $preview -and -not $previewError -and $chromeFamilies.Count -gt 0 -and $previewFamilies.Count -gt 0 -and
                    ($chromeFamilies -join '|') -ceq ($previewFamilies -join '|'))
                $chromeIdentities = @((Get-Prop $font 'fonts') | Where-Object { [int] (Get-Prop $_ 'glyphCount') -gt 0 } |
                    ForEach-Object { "$(Get-Prop $_ 'familyName')|$(Get-Prop $_ 'postScriptName')" } | Sort-Object -Unique)
                $previewIdentities = @((Get-Prop $preview 'fonts') | Where-Object { [int] (Get-Prop $_ 'glyphCount') -gt 0 } |
                    ForEach-Object { "$(Get-Prop $_ 'familyName')|$(Get-Prop $_ 'postScriptName')" } | Sort-Object -Unique)
                Add-Check "A-FONT.$($case.label).faceAgreement" 'nonempty Chrome/preview platform family and PostScript faces agree exactly' (
                    [ordered]@{ chrome = $chromeIdentities; preview = $previewIdentities }) (
                    $preview -and -not $previewError -and $chromeIdentities.Count -gt 0 -and
                    ($chromeIdentities -join ';') -ceq ($previewIdentities -join ';'))
                if (-not $case.expected) {
                    $previewState = Get-P2PreviewPageState $run
                    $evidence.missingFallback = [ordered]@{ chromeStack = $titleFontFamily; previewStack = Get-Prop $preview 'titleFontFamily'
                        chromeAvailable = Get-PageField $probe 'fontAvailable'; previewAvailable = Get-Prop $previewState 'fontAvailable'; wire = $lookEvent.data }
                    Add-Check 'A-FONT.missing.fallbackStack' 'unavailable wire/page/preview flag and exact Display title fallback stack in both renderers' $evidence.missingFallback (
                        (Get-Prop $lookEvent.data 'fontAvailable') -eq $false -and
                        (Get-PageField $probe 'fontAvailable') -eq $false -and (Get-Prop $previewState 'fontAvailable') -eq $false -and
                        -not (Get-Prop $titleStyle 'exceptionDetails') -and $titleFontFamily -ceq $fallbackStack -and
                        (Get-Prop $preview 'titleFontFamily') -ceq $fallbackStack)
                }
                $persisted = @((Read-ObsLooksFile $run.Root).looks | Where-Object { $_.id -eq $case.id })[0].options.font
                Add-Check "A-FONT.$($case.label).persisted" $case.family $persisted ($persisted -ceq $case.family)
            } finally { Stop-SseReader $reader; Reset-ChromeCasePage $chrome }
        }
        $evidence.beforeClose = Save-P2DesignerDiagnostics $run 'font-before-close'
        $oldDraftKey = (Get-P2DesignerHook $run).state.draftKey
        Close-P2Designer $designer; $designer = $null
        $evidence.afterClose = Get-P2DesignerHook $run
        Send-ObsHookCommand $run.Root 'command-obs-font-enumeration-fail' 'on' | Out-Null
        try {
            $designer = Open-P2Designer $run
            [void] (Select-P2Look $designer 'english')
            $fresh = Get-P2DesignerHook $run
            $evidence.freshFailureWindow = Save-P2DesignerDiagnostics $run 'font-failure-window'
            if (-not $fresh.open -or $fresh.state.draftKey -eq $oldDraftKey -or $fresh.state.sourceId -ne 'font0001' -or
                $fresh.state.dirty -or $fresh.state.dialogActive -or -not $fresh.state.fonts.failed -or $fresh.state.fonts.count -ne 0) {
                throw "Forced font-enumeration failure did not use a fresh clean English draft; evidence: $($evidence.freshFailureWindow)"
            }
            $picker = Assert-P2Control $designer 'FontPicker'
            (Get-Pattern $picker ([System.Windows.Automation.ExpandCollapsePattern])).Expand()
            $options = @($picker.FindAll($Scope::Descendants, [System.Windows.Automation.Condition]::TrueCondition) |
                Where-Object { $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::ListItem } |
                ForEach-Object { $_.Current.Name })
            if ($options.Count -eq 0) {
                $default = @($AE::RootElement.FindAll($Scope::Descendants, [System.Windows.Automation.Condition]::TrueCondition) |
                    Where-Object { $_.Current.ProcessId -eq $run.App.Id -and
                        $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::ListItem -and
                        $_.Current.Name -eq 'Theme default' }) | Select-Object -First 1
                if ($default) {
                    $popupList = [System.Windows.Automation.TreeWalker]::RawViewWalker.GetParent($default)
                    $options = @($popupList.FindAll($Scope::Descendants, [System.Windows.Automation.Condition]::TrueCondition) |
                        Where-Object { $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::ListItem } |
                        ForEach-Object { $_.Current.Name })
                }
            }
            $notice = @($designer.El.FindAll($Scope::Descendants, [System.Windows.Automation.Condition]::TrueCondition) |
                Where-Object { $_.Current.Name -like '*Installed fonts could not be listed*' })
            $evidence.enumerationFailure = [ordered]@{ options = $options; notice = @($notice | ForEach-Object { $_.Current.Name })
                beforeClose = $oldDraftKey; reopened = $fresh; afterClose = $evidence.afterClose }
            Add-Check 'A-FONT.enumerationFailure' 'only Theme default + preserved saved Segoe UI; clear failure message' $evidence.enumerationFailure (
                $options.Count -eq 2 -and 'Theme default' -in $options -and @($options | Where-Object { $_ -like '*Segoe UI*' }).Count -eq 1 -and $notice.Count -gt 0)
        } finally { Send-ObsHookCommand $run.Root 'command-obs-font-enumeration-fail' 'off' | Out-Null }
    } finally {
        [void] (Save-P2Evidence 'font' $evidence)
        Close-P2Designer $designer -Cleanup; Stop-Chrome $chrome; if ($run) { Stop-OverlayRun $run }
        $scenarioResults['A-FONT'] = $evidence
    }
}
function Test-P2StoreCancellation {
    $look = New-ObsLook 'cancel01' 'Cancel test' (Get-ThemeDefaults 'matte')
    $run = $null; $designer = $null; $observed = [ordered]@{}
    try {
        $run = Start-OverlayRun 'A-STORE-2-cancel' @{} 'PlayingLong' -NoReader -LooksJson (
            ConvertTo-ObsLooksJson (New-ObsLooksDocument @($look)))
        $designer = Open-P2Designer $run
        [void] (Select-P2Look $designer 'Cancel test')
        $file = Join-Path $run.Root 'data/obs-looks.json'
        $old = Get-Sha256 $file
        Set-P2Value (Assert-P2Control $designer 'LookNameBox') 'Cancelled rev'
        Send-ObsHookCommand $run.Root 'command-obs-store-fault' 'slow 15000' | Out-Null
        Invoke-Element (Assert-P2Control $designer 'SaveLookButton')
        $disabled = Wait-For { -not (Assert-P2Control $designer 'SaveLookButton').Current.IsEnabled } 2 50
        (Assert-P2Control $designer 'LookNameBox').SetFocus()
        Add-Type -AssemblyName System.Windows.Forms
        $start = Get-Qpc
        [System.Windows.Forms.SendKeys]::SendWait('{ESC}')
        $savingDialog = Get-P2Dialog $run 'Saving…'
        $failure = Wait-For { $s = Get-P2DesignerSnapshot $designer; if ($s.result -like '*Could not save*') { $s } } 13
        $observed.cancel = [ordered]@{ dialog = [bool] $savingDialog; elapsed = Round3 (Get-Seconds $start (Get-Qpc))
            before = $old; after = Get-Sha256 $file; state = $failure; disabled = $disabled
            screenshot = Save-WindowShot $designer.Hwnd 'designer-store-cancelled' }
        Add-Check 'A-STORE-2.closeCancel' 'after 10 s slow commit cancels; old file intact, dirty draft and window preserved' $observed.cancel (
            $disabled -and $savingDialog -and $failure -and $old -eq $observed.cancel.after -and
            $failure.designer.state.dirty -eq $true -and $failure.result -like '*OBS sources are unchanged*' -and
            $observed.cancel.elapsed -ge 9.5 -and $observed.cancel.elapsed -le 13)
        Invoke-Element (Assert-P2Control $designer 'SaveLookButton')
        $retry = Wait-For { if ((Read-ObsLooksFile $run.Root).looks[0].name -eq 'Cancelled rev') { Get-P2DesignerSnapshot $designer } } 10
        $observed.retry = [ordered]@{ state = $retry; file = Read-ObsLooksFile $run.Root }
        Add-Check 'A-STORE-2.retryToken' 'retry on same window commits with new token and clears dirty' $observed.retry (
            $retry -and $retry.designer.state.dirty -eq $false -and $retry.name -eq 'Cancelled rev')
    } finally {
        [void] (Save-P2Evidence 'store2-cancel' $observed)
        Close-P2Designer $designer -Cleanup; if ($run) { Stop-OverlayRun $run }
    }
}
function Test-P2StoreShutdown {
    $look = New-ObsLook 'shut0001' 'Before shutdown' (Get-ThemeDefaults 'matte')
    $run = $null; $designer = $null; $reader = $null; $observed = [ordered]@{}
    try {
        $run = Start-OverlayRun 'A-STORE-2-shutdown' @{} 'PlayingLong' -NoReader -LooksJson (
            ConvertTo-ObsLooksJson (New-ObsLooksDocument @($look)))
        $designer = Open-P2Designer $run
        [void] (Select-P2Look $designer 'Before shutdown')
        $reader = Start-SseReader 'store2-shutdown-stream' 20 '/events?look=shut0001&sample=playing'
        [void] (Wait-SseLook $reader { param($l) (Get-Prop $l 'id') -eq 'shut0001' } 15)
        $file = Join-Path $run.Root 'data/obs-looks.json'
        $old = Get-Sha256 $file
        Set-P2Value (Assert-P2Control $designer 'LookNameBox') 'After shutdown'
        Send-ObsHookCommand $run.Root 'command-obs-store-fault' 'slow 5000' | Out-Null
        Invoke-Element (Assert-P2Control $designer 'SaveLookButton')
        [void] (Wait-For { -not (Assert-P2Control $designer 'SaveLookButton').Current.IsEnabled } 2 50)
        $start = Get-Qpc
        Send-HookCommand $run.Root 'command-quit' | Out-Null
        $samples = [Collections.Generic.List[object]]::new()
        while (-not $run.App.HasExited -and (Get-Seconds $start (Get-Qpc)) -lt 5) {
            $parsed = try { [IO.File]::ReadAllText($file) | ConvertFrom-Json -Depth 16 } catch { $null }
            $samples.Add([ordered]@{ hash = Get-Sha256 $file; valid = @((Get-Prop $parsed 'looks')).Count -eq 1; utc = [DateTime]::UtcNow.ToString('o') })
            Start-Sleep -Milliseconds 100
        }
        $exitInBudget = $run.App.HasExited
        $final = Read-ObsLooksFile $run.Root
        $observed.exit = [ordered]@{ elapsed = Round3 (Get-Seconds $start (Get-Qpc)); code = if ($exitInBudget) { $run.App.ExitCode } else { $null }
            old = $old; final = Get-Sha256 $file; content = $final; samples = $samples.ToArray() }
        Add-Check 'A-STORE-2.shutdown' 'quit <=5 s; every sampled file valid and old-or-new complete' $observed.exit (
            $exitInBudget -and $observed.exit.elapsed -le 5 -and
            @($samples | Where-Object { -not $_.valid -or $_.hash -notin @($old, $observed.exit.final) }).Count -eq 0 -and
            $final.looks[0].name -in @('Before shutdown', 'After shutdown'))
        $afterQuit = @(Get-LookEvents (Read-Sse $reader) | Where-Object { $_.qpc -gt $start })
        $observed.afterQuit = $afterQuit
        Add-Check 'A-STORE-2.noLatePublish' 'no look events on the old source after shutdown begins' $afterQuit ($afterQuit.Count -eq 0)
        Stop-SseReader $reader; $reader = $null
        if ($exitInBudget) {
            $designer = $null
            Remove-Item -LiteralPath (Join-Path (Get-BenchDirectory $run.Root) 'ready.json') -ErrorAction SilentlyContinue
            $run.App = Start-App $run.Root @{ NATIVUNE_TEST_DISCORD_BENCH_PROFILE = 'PlayingLong'; NATIVUNE_TEST_DISCORD_BENCH_STATE = 'Full' }
            [void] (Wait-BenchReady $run.Root)
            $reopened = Get-Overlay (Get-State $run.Root 'shutdown-reopen') 'looks'
            $observed.restarted = $reopened
            Add-Check 'A-STORE-2.shutdownRestart' 'restart reads one intact look with writable store' $reopened (
                (Get-Prop $reopened 'count') -eq 1 -and (Get-Prop $reopened 'readOnly') -eq $false)
        } else {
            Add-Blocked 'A-STORE-2.shutdownRestart' 'restart after <=5 s clean shutdown' 'Dependent on the shutdown timing gate.'
        }
    } finally {
        [void] (Save-P2Evidence 'store2-shutdown' $observed)
        Close-P2Designer $designer -Cleanup; Stop-SseReader $reader; if ($run) { Stop-OverlayRun $run }
    }
}
function Test-P2StoreAbandonment {
    $all = [Collections.Generic.List[object]]::new()
    foreach ($action in @('New', 'Duplicate', 'Select', 'Revert', 'Close')) {
        foreach ($choice in $(if ($action -eq 'Revert') { @('Discard', 'Cancel') } else { @('Save', 'Discard', 'Cancel') })) {
            $label = "$action-$choice"
            $seed = @((New-ObsLook 'matrix01' 'Primary' (Get-ThemeDefaults 'matte')),
                (New-ObsLook 'matrix02' 'Secondary' (Get-ThemeDefaults 'card')))
            $run = $null; $designer = $null; $watcher = $null; $result = [ordered]@{ action = $action; choice = $choice }
            try {
                $run = Start-OverlayRun "A-STORE-2-$label" @{} 'PlayingLong' -NoReader -LooksJson (
                    ConvertTo-ObsLooksJson (New-ObsLooksDocument $seed))
                $designer = Open-P2Designer $run
                [void] (Select-P2Look $designer 'Primary')
                $watcher = Watch-P2Writes $run.Root
                Set-P2Range $designer 'WidthSlider' 450
                Send-ObsHookCommand $run.Root 'command-obs-store-fault' 'slow 3000' | Out-Null
                Invoke-Element (Assert-P2Control $designer 'SaveLookButton')
                $mid = Wait-For { -not (Assert-P2Control $designer 'SaveLookButton').Current.IsEnabled } 2 50
                Set-P2Range $designer 'WidthSlider' 460
                switch ($action) {
                    'New' { Invoke-Element (Assert-P2Control $designer 'NewLookButton') }
                    'Duplicate' { Invoke-Element (Assert-P2Control $designer 'DuplicateLookButton') }
                    'Select' { [void] (Select-P2Look $designer 'Secondary' -ExpectPrompt) }
                    'Revert' { Invoke-Element (Assert-P2Control $designer 'RevertChangesButton') }
                    'Close' {
                        (Assert-P2Control $designer 'LookNameBox').SetFocus()
                        Add-Type -AssemblyName System.Windows.Forms
                        [System.Windows.Forms.SendKeys]::SendWait('{ESC}')
                    }
                }
                $saving = Get-P2Dialog $run 'Saving…'
                $promptName = if ($action -eq 'Revert') { 'Discard changes to*' } else { 'Save changes to*' }
                $prompt = Get-P2Dialog $run $promptName
                $during = Get-P2DesignerHook $run
                $oldFile = Read-ObsLooksFile $run.Root
                $promptText = Invoke-P2DialogChoice $run $promptName $choice
                $expectedDiskWidth = $(if ($choice -eq 'Save') { 460 } else { 450 })
                $file = Wait-For {
                    $f = Read-ObsLooksFile $run.Root
                    if ($f.looks[0].options.width -eq $expectedDiskWidth) { $f }
                } 10
                # Read the committed source after the Save/Discard choice settles; Duplicate must copy that exact revision.
                $committedLook = @((Get-Prop $file 'looks') | Where-Object { (Get-Prop $_ 'id') -eq 'matrix01' }) | Select-Object -First 1
                $committedWidth = Get-Prop (Get-Prop $committedLook 'options') 'width'
                $closed = $action -eq 'Close' -and $choice -ne 'Cancel'
                $after = Get-P2DesignerHook $run
                $result.mid = $mid; $result.savingDialog = [bool] $saving; $result.dirtyPrompt = [bool] $prompt
                $result.promptText = $promptText; $result.beforeChoice = $during; $result.afterChoice = $after
                $result.fileBeforeChoice = $oldFile; $result.fileAfterChoice = $file
                $result.committedSourceWidth = $committedWidth
                $result.writes = @(Stop-P2Writes $watcher); $watcher = $null
                $result.shot = if (-not $closed) { Save-WindowShot $designer.Hwnd "store-$label" } else { $null }
                $actionState = Get-Prop $after 'state'
                $draftCorrect = if ($closed) { -not $after.open } elseif ($choice -eq 'Cancel') {
                    $actionState.dirty -eq $true -and $actionState.options.width -eq 460 -and $actionState.sourceId -eq 'matrix01'
                } elseif ($action -eq 'Select') { $actionState.sourceId -eq 'matrix02' }
                elseif ($action -eq 'Revert') { $actionState.sourceId -eq 'matrix01' -and -not $actionState.dirty -and $actionState.options.width -eq 450 }
                elseif ($action -eq 'Duplicate') {
                    $null -eq $actionState.sourceId -and $null -ne $committedWidth -and $actionState.options.width -eq $committedWidth
                } else { $null -eq $actionState.sourceId -and $actionState.options.width -eq (Get-ThemeDefaults 'pill').width }
                Add-Check "A-STORE-2.abandon.$label" 'Saving… then fresh rev2 dirty prompt; branch persists exactly chosen rev and preserves/abandons draft' $result (
                    $mid -and $saving -and $prompt -and $during.state.dirty -and
                    $during.state.draftRev -gt $during.state.lastSavedRev -and $file -and $draftCorrect -and
                    @($result.writes | Where-Object { $_.name -eq 'obs-looks.json.tmp' -and $_.type -eq 'Created' }).Count -eq
                    $(if ($choice -eq 'Save') { 2 } else { 1 }))
                if ($closed) { $designer = $null }
            } finally {
                $all.Add($result); if ($watcher) { [void] (Stop-P2Writes $watcher) }
                Close-P2Designer $designer -Cleanup; if ($run) { Stop-OverlayRun $run }
            }
        }
    }
    [void] (Save-P2Evidence 'store2-abandonment' $all.ToArray())
}
function Test-P2StoreDelete {
    $seed = @((New-ObsLook 'delete01' 'Primary' (Get-ThemeDefaults 'matte')),
        (New-ObsLook 'delete02' 'Secondary' (Get-ThemeDefaults 'card')))
    $run = $null; $designer = $null; $reader = $null; $result = [ordered]@{}
    try {
        $run = Start-OverlayRun 'A-STORE-2-delete' @{} 'PlayingLong' -NoReader -LooksJson (
            ConvertTo-ObsLooksJson (New-ObsLooksDocument $seed))
        $designer = Open-P2Designer $run
        [void] (Select-P2Look $designer 'Primary')
        $reader = Start-SseReader 'store2-deleted-source' 20 '/events?look=delete01'
        [void] (Wait-SseLook $reader { param($l) (Get-Prop $l 'id') -eq 'delete01' -and -not $l.missing } 15)
        Send-ObsHookCommand $run.Root 'command-obs-store-fault' 'slow 3000' | Out-Null
        Invoke-Element (Assert-P2Control $designer 'DeleteLookButton')
        $confirmed = Invoke-P2DialogChoice $run "Delete 'Primary'?*" 'Delete'
        $modal = Wait-For { Get-P2Dialog $run 'Deleting…' } 2 50
        $disabled = -not (Assert-P2Control $designer 'LookNameBox').Current.IsEnabled -and
            -not (Assert-P2Control $designer 'SavedLooksList').Current.IsEnabled
        $editsIgnored = $false
        try { Set-P2Value (Assert-P2Control $designer 'LookNameBox') 'Lost edit' } catch { $editsIgnored = $true }
        $deleted = Wait-For {
            $s = Read-ObsLooksFile $run.Root
            if (@($s.looks).Count -eq 1 -and $s.looks[0].id -eq 'delete02') { $s }
        } 8
        $selected = Wait-For { $state = Get-P2DesignerHook $run; if ($state.state.sourceId -eq 'delete02') { $state } } 5
        $result.success = [ordered]@{ confirm = $confirmed; modal = [bool] $modal; disabled = $disabled
            editRejected = $editsIgnored; disk = $deleted; designer = $selected }
        $fallback = Wait-SseLook $reader { param($l) (Get-Prop $l 'id') -eq 'delete01' -and (Get-Prop $l 'missing') -eq $true } 8
        $missingText = Wait-For {
            $text = (Assert-P2Control $designer 'MissingLooksText').Current.Name
            if ($text -eq '1 source uses a deleted look') { $text }
        } 5
        $result.success.fallback = $fallback; $result.success.missingText = $missingText
        Add-Check 'A-STORE-2.slowDelete' 'Deleting… read-only editor; deleted stream gets pill fallback and remaining look selected' $result.success (
            $modal -and $disabled -and $editsIgnored -and $deleted -and $fallback -and
            (Get-Prop $fallback.data 'theme') -eq 'pill' -and $missingText -eq '1 source uses a deleted look' -and
            $result.success.designer.state.sourceId -eq 'delete02')
        Set-P2Range $designer 'WidthSlider' 450
        $beforeFailure = Get-P2DesignerHook $run
        $oldHash = Get-Sha256 (Join-Path $run.Root 'data/obs-looks.json')
        Send-ObsHookCommand $run.Root 'command-obs-store-fault' 'replace' | Out-Null
        Invoke-Element (Assert-P2Control $designer 'DeleteLookButton')
        [void] (Invoke-P2DialogChoice $run "Delete 'Secondary'?*" 'Delete')
        $errorText = Wait-For { $text = Get-P2Result $designer; if ($text -ceq 'Could not save; OBS sources are unchanged.') { $text } } 8
        $result.failure = [ordered]@{ oldHash = $oldHash; after = Get-Sha256 (Join-Path $run.Root 'data/obs-looks.json')
            text = $errorText; before = $beforeFailure; draft = Get-P2DesignerHook $run
            detail = (Assert-P2Control $designer 'StoreStatusText').Current.Name }
        Add-Check 'A-STORE-2.deleteFailure' 'failed delete keeps selected draft, exact result and unchanged OBS/disk' $result.failure (
            $errorText -ceq 'Could not save; OBS sources are unchanged.' -and $result.failure.after -eq $oldHash -and
            $result.failure.draft.state.sourceId -eq 'delete02' -and
            $result.failure.draft.state.dirty -eq $beforeFailure.state.dirty -and
            $result.failure.draft.state.options.Width -eq 450 -and
            $result.failure.detail -like '*looks file could not be written*')
    } finally {
        [void] (Save-P2Evidence 'store2-delete' $result)
        Close-P2Designer $designer -Cleanup; Stop-SseReader $reader; if ($run) { Stop-OverlayRun $run }
    }
}
function Test-P2DuplicateName {
    $longName = 'N' * 40
    $look = New-ObsLook 'dup00001' $longName (Get-ThemeDefaults 'matte')
    $run = $null; $designer = $null; $result = [ordered]@{}
    try {
        $run = Start-OverlayRun 'A-STORE-2-duplicate-name' @{} 'PlayingLong' -NoReader -LooksJson (
            ConvertTo-ObsLooksJson (New-ObsLooksDocument @($look)))
        $designer = Open-P2Designer $run
        [void] (Select-P2Look $designer $longName)
        Invoke-Element (Assert-P2Control $designer 'DuplicateLookButton')
        $state = Get-P2DesignerHook $run
        $name = Get-P2Text $designer 'LookNameBox'
        $result = [ordered]@{ name = $name; original = $longName; draft = $state
            disk = Read-ObsLooksFile $run.Root }
        Add-Check 'A-DESIGNER.duplicateName' '40-unit source name truncates to 33 plus (copy), new unsaved dirty draft' $result (
            $name -ceq (($longName.Substring(0, 33)) + ' (copy)') -and
            $state.state.sourceId -eq $null -and $state.state.dirty -and
            @($result.disk.looks).Count -eq 1 -and $result.disk.looks[0].name -ceq $longName)
    } finally {
        [void] (Save-P2Evidence 'designer-duplicate-name' $result)
        Close-P2Designer $designer -Cleanup; if ($run) { Stop-OverlayRun $run }
    }
}
function Test-P2PromptSaveEditRace {
    $look = New-ObsLook 'race0001' 'Race look' (Get-ThemeDefaults 'matte')
    $run = $null; $designer = $null; $result = [ordered]@{}
    try {
        $run = Start-OverlayRun 'A-STORE-2-prompt-edit' @{} 'PlayingLong' -NoReader -LooksJson (
            ConvertTo-ObsLooksJson (New-ObsLooksDocument @($look)))
        $designer = Open-P2Designer $run
        [void] (Select-P2Look $designer 'Race look')
        Set-P2Range $designer 'WidthSlider' 450
        Send-ObsHookCommand $run.Root 'command-obs-store-fault' 'slow 3000' | Out-Null
        Invoke-Element (Assert-P2Control $designer 'SaveLookButton')
        [void] (Wait-For { -not (Assert-P2Control $designer 'SaveLookButton').Current.IsEnabled } 2 50)
        Set-P2Range $designer 'WidthSlider' 460
        Invoke-Element (Assert-P2Control $designer 'NewLookButton')
        $saving = Get-P2Dialog $run 'Saving…'
        $prompt = Get-P2Dialog $run 'Save changes*'
        Send-ObsHookCommand $run.Root 'command-obs-store-fault' 'slow 3000' | Out-Null
        [void] (Invoke-P2DialogChoice $run 'Save changes*' 'Save')
        $secondSaving = Wait-For { -not (Assert-P2Control $designer 'SaveLookButton').Current.IsEnabled } 2 50
        Set-P2Range $designer 'WidthSlider' 470
        $again = Get-P2Dialog $run 'Save changes*'
        $beforeCancel = Get-P2DesignerHook $run
        [void] (Invoke-P2DialogChoice $run 'Save changes*' 'Cancel')
        $after = Get-P2DesignerHook $run
        $file = Read-ObsLooksFile $run.Root
        $result = [ordered]@{ saving = [bool] $saving; prompt = [bool] $prompt; secondSaving = [bool] $secondSaving
            secondPrompt = [bool] $again; beforeCancel = $beforeCancel; after = $after; disk = $file
            shot = Save-WindowShot $designer.Hwnd 'designer-prompt-save-edit-race' }
        Add-Check 'A-STORE-2.promptSaveEditRace' 'Save from prompt captures rev2, edit rev3 reprompts; Cancel keeps rev3, disk rev2' $result (
            $saving -and $prompt -and $secondSaving -and $again -and
            $file.looks[0].options.width -eq 460 -and $after.open -and
            $beforeCancel.state.draftRev -gt $beforeCancel.state.lastSavedRev -and
            $after.state.sourceId -eq 'race0001' -and $after.state.options.Width -eq 470 -and $after.state.dirty)
    } finally {
        [void] (Save-P2Evidence 'store2-prompt-edit-race' $result)
        Close-P2Designer $designer -Cleanup; if ($run) { Stop-OverlayRun $run }
    }
}
function Test-P2OffActions {
    $all = [Collections.Generic.List[object]]::new()
    foreach ($branch in @('Save', 'SaveFailure', 'Discard', 'Cancel')) {
        $run = $null; $designer = $null; $entry = [ordered]@{ branch = $branch }
        try {
            $look = New-ObsLook 'off00001' 'Off look' (Get-ThemeDefaults 'matte')
            $run = Start-OverlayRun "A-STORE-2-off-$branch" @{} 'PlayingLong' -NoReader -LooksJson (
                ConvertTo-ObsLooksJson (New-ObsLooksDocument @($look)))
            $designer = Open-P2Designer $run
            if ($branch -eq 'Save') {
                $notice = (Assert-P2Control $designer 'DesignerPreviewNotice').Current.Name
                $shot = Save-WindowShot $designer.Hwnd 'A-STORE-2-designer-preview-notice'
                Add-Check 'A-STORE-2.designerPreviewNotice' 'designer shows the early-preview notice to sighted and UIA users' ([ordered]@{
                    name = $notice; screenshot = $shot }) ($notice -like 'Early preview:*')
            }
            [void] (Select-P2Look $designer 'Off look')
            Set-P2Range $designer 'WidthSlider' 450
            Send-ObsHookCommand $run.Root 'command-obs-store-fault' 'slow 3000' | Out-Null
            Invoke-Element (Assert-P2Control $designer 'SaveLookButton')
            [void] (Wait-For { -not (Assert-P2Control $designer 'SaveLookButton').Current.IsEnabled } 2 50)
            Set-P2Range $designer 'WidthSlider' 460
            Send-HookCommand $run.Root 'command-obs-off' | Out-Null
            $entry.saving = [bool] (Get-P2Dialog $run 'Saving…')
            $entry.prompt = [bool] (Get-P2Dialog $run 'The overlay was turned off.*')
            if ($branch -eq 'SaveFailure') {
                Send-ObsHookCommand $run.Root 'command-obs-store-fault' 'replace' | Out-Null
            }
            $entry.promptText = Invoke-P2DialogChoice $run 'The overlay was turned off.*' $(if ($branch -eq 'SaveFailure') { 'Save' } else { $branch })
            $entry.after = Wait-For {
                $s = Get-P2DesignerHook $run
                if ($branch -in @('Save', 'Discard')) { if (-not $s.open) { $s } }
                elseif ($branch -eq 'SaveFailure') { if ($s.state.result -ceq 'Could not save; OBS sources are unchanged.') { $s } }
                else { if ($s.open -and $s.state.dirty) { $s } }
            } 10
            $entry.disk = Read-ObsLooksFile $run.Root
            $entry.overlay = (Get-State $run.Root "off-$branch").overlay
            $entry.detail = if ($entry.after.open) { (Assert-P2Control $designer 'StoreStatusText').Current.Name } else { $null }
            Add-Check "A-STORE-2.off.$branch" 'off waits for Save, then executes selected offline choice without losing newer edits' $entry (
                $entry.saving -and $entry.prompt -and $entry.after -and -not $entry.overlay.running -and
                $entry.disk.looks[0].options.width -eq $(if ($branch -eq 'Save') { 460 } else { 450 }) -and
                $(if ($branch -in @('Save', 'Discard')) { -not $entry.after.open } else {
                    $entry.after.open -and $entry.after.state.dirty -and $entry.after.state.options.Width -eq 460 -and
                    $entry.after.state.previewHost -eq $false -and
                    $(if ($branch -eq 'SaveFailure') {
                        $entry.after.state.result -ceq 'Could not save; OBS sources are unchanged.' -and
                        $entry.detail -like '*looks file could not be written*'
                    } else { $true })
                }))
            if ($branch -eq 'Cancel') {
                # Off releases the preview WebView; On recreates and renavigates it while the draft is kept.
                Send-HookCommand $run.Root 'command-obs-on' | Out-Null
                $entry.reopened = Wait-For {
                    $s = Get-P2DesignerHook $run
                    if ($s.open -and $s.state.previewHost -and $s.state.navigated -and $s.state.dirty) { $s }
                } 20
                Add-Check 'A-STORE-2.off.Cancel.previewRecreated' 'overlay back on: preview WebView recreated and navigated; draft kept' $entry (
                    $null -ne $entry.reopened -and $entry.reopened.state.options.Width -eq 460)
            }
        } finally {
            $all.Add($entry)
            Close-P2Designer $designer -Cleanup; if ($run) { Stop-OverlayRun $run }
        }
    }
    [void] (Save-P2Evidence 'store2-off-actions' $all.ToArray())
}
function Test-P2LookFxDesigner {
    $themes = @('pill', 'matte', 'matte-light', 'standard', 'classic', 'simple', 'album-art', 'card')
    $nullFx = [ordered]@{ BackgroundBlur = $null; PlayedBrightness = $null; UnplayedBrightness = $null; BackgroundBrightness = $null }
    $seed = @($themes | ForEach-Object {
        $options = Get-ThemeDefaults $_
        foreach ($field in $script:p2FxFields) { $options[$field] = $null }
        New-ObsLook ("fxui000{0}" -f [array]::IndexOf($themes, $_)) "FX $_" $options
    })
    $run = $null; $designer = $null; $reader = $null; $evidence = [ordered]@{}
    try {
        $run = Start-OverlayRun 'A-DESIGNER-fx' @{} 'PlayingLong' -NoReader -LooksJson (
            ConvertTo-ObsLooksJson (New-ObsLooksDocument $seed))
        $designer = Open-P2Designer $run
        foreach ($theme in $themes) {
            [void] (Select-P2Look $designer "FX $theme")
            $defaults = Get-P2FxDefaults $theme
            $supported = $theme -notin @('matte', 'matte-light', 'simple')
            $visibleFields = @($script:p2FxFields | Where-Object { $supported -or $_ -in @('PlayedBrightness', 'UnplayedBrightness') })
            foreach ($field in $visibleFields) {
                $status = (Assert-P2Control $designer "${field}StatusText").Current.Name
                $before = (Get-P2DesignerHook $run).state
                Invoke-Element (Assert-P2Control $designer "${field}ResetButton")
                $after = (Get-P2DesignerHook $run).state
                $entry = [ordered]@{ status = $status; default = $defaults[$field]; before = $before; after = $after }
                $evidence["default.$theme.$field"] = $entry
                Add-Check "A-DESIGNER.fx.default.$theme.$field" 'null shows Theme default (N …); reset of null neither dirties nor advances revision' $entry (
                    $status -match "^Theme default \($($defaults[$field])(?:\s|[)%])" -and
                    (Test-P2FxEqual $after.options $nullFx) -and -not $before.dirty -and -not $after.dirty -and
                    $before.draftRev -eq $after.draftRev)
            }
            foreach ($phase in @('default', 'override')) {
                Select-P2Item $designer 'ColoursPicker' 'Automatic'
                Set-Toggle (Assert-P2Control $designer 'ShowProgressToggle') $true
                if ($theme -eq 'album-art') { Set-Toggle (Assert-P2Control $designer 'ShowArtToggle') $true }
                $kept = [ordered]@{ BackgroundBlur = $null; PlayedBrightness = $null; UnplayedBrightness = $null; BackgroundBrightness = $null }
                if ($phase -eq 'override') {
                    $kept.PlayedBrightness = 150; $kept.UnplayedBrightness = 75
                    if ($supported) { $kept.BackgroundBlur = 23; $kept.BackgroundBrightness = 150 }
                    foreach ($field in $visibleFields) { Set-P2Range $designer "${field}Slider" $kept[$field] }
                }
                foreach ($mode in @('Automatic', 'Custom')) {
                Select-P2Item $designer 'ColoursPicker' $mode
                foreach ($art in $(if ($theme -eq 'album-art') { @($true, $false) } else { @($true) })) {
                    if ($theme -eq 'album-art') { Set-Toggle (Assert-P2Control $designer 'ShowArtToggle') $art }
                    foreach ($progress in @($true, $false)) {
                        Set-Toggle (Assert-P2Control $designer 'ShowProgressToggle') $progress
                        $tree = @($designer.El.FindAll($Scope::Descendants, [System.Windows.Automation.Condition]::TrueCondition))
                        $rows = [ordered]@{}; $correct = $true
                        foreach ($field in $script:p2FxFields) {
                            $background = $field -in @('BackgroundBlur', 'BackgroundBrightness')
                            $visible = -not $background -or $supported
                            $enabled = if ($background) {
                                $visible -and -not ($theme -in @('standard', 'classic', 'card') -and $mode -eq 'Custom') -and
                                    -not ($theme -eq 'album-art' -and -not $art)
                            } else { $progress -or ($theme -eq 'pill' -and $field -eq 'PlayedBrightness') }
                            $controls = @($tree | Where-Object { $_.Current.AutomationId -in @("${field}Slider", "${field}Box", "${field}ResetButton") })
                            $help = @($tree | Where-Object { $_.Current.AutomationId -eq "${field}HelpText" } | ForEach-Object { $_.Current.Name })
                            $status = @($tree | Where-Object { $_.Current.AutomationId -eq "${field}StatusText" } | ForEach-Object { $_.Current.Name })
                            $rows[$field] = [ordered]@{ visible = $visible; enabled = $enabled; controls = @($controls | ForEach-Object { Describe $_ }); help = $help; status = $status }
                            if (-not $visible) {
                                $correct = $correct -and $controls.Count -eq 0 -and
                                    @($tree | Where-Object { $_.Current.AutomationId -in @("${field}StatusText", "${field}HelpText") }).Count -eq 0
                            } else {
                                $correct = $correct -and $controls.Count -eq 3 -and
                                    @($controls | Where-Object { $_.Current.IsEnabled -ne $enabled }).Count -eq 0
                                $resolvedValue = if ($null -eq $kept[$field]) { $defaults[$field] } else { $kept[$field] }
                                $slider = @($controls | Where-Object { $_.Current.AutomationId -eq "${field}Slider" }) | Select-Object -First 1
                                if ($slider) {
                                    $value = (Get-Pattern $slider ([System.Windows.Automation.RangeValuePattern])).Current.Value
                                    $rows[$field]['value'] = $value
                                    $correct = $correct -and $value -eq $resolvedValue
                                }
                                if ($phase -eq 'default') { $correct = $correct -and ($status -join ' ') -match "^Theme default \($resolvedValue(?:\s|[)%])" }
                                if (-not $enabled) {
                                    $reason = if (-not $background) { 'progress' } elseif ($theme -eq 'album-art') { 'artwork' } else { 'Custom' }
                                    $correct = $correct -and ($help -join ' ') -match $reason
                                }
                            }
                        }
                        $state = (Get-P2DesignerHook $run).state
                        $label = "$theme.$phase.$mode.art$art.progress$progress"
                        $entry = [ordered]@{ rows = $rows; expectedOptions = $kept; state = $state }
                        $evidence["applicability.$label"] = $entry
                        Add-Check "A-DESIGNER.fx.applicability.$label" 'all row visibility/enabled states match applicability; inactive explanation and retained overrides' $entry (
                            $correct -and (Test-P2FxEqual $state.options $kept))
                    }
                }
            }
            }
            $reverted = Invoke-P2FxRevert $designer
            Add-Check "A-DESIGNER.fx.revert.$theme" 'Revert restores all nullable effects and clears dirty' $reverted (
                -not $reverted.state.dirty -and (Test-P2FxEqual $reverted.state.options $nullFx))
        }
        [void] (Select-P2Look $designer 'FX card')
        Add-Type -AssemblyName System.Windows.Forms
        foreach ($spec in @(
            @{ field = 'BackgroundBlur'; max = 32; step = 1 },
            @{ field = 'PlayedBrightness'; max = 200; step = 5 },
            @{ field = 'UnplayedBrightness'; max = 100; step = 5 },
            @{ field = 'BackgroundBrightness'; max = 200; step = 5 }
        )) {
            $field = $spec.field
            foreach ($endpoint in @(0, $spec.max)) {
                Set-P2Range $designer "${field}Slider" $endpoint
                $state = (Get-P2DesignerHook $run).state
                $entry = [ordered]@{ state = $state; box = Get-P2Text $designer "${field}Box" }
                $evidence["slider.$field.$endpoint"] = $entry
                Add-Check "A-DESIGNER.fx.slider.$field.$endpoint" 'slider endpoint commits exact override and paired NumberBox' $entry (
                    $null -ne $state.options.$field -and $state.options.$field -eq $endpoint -and [double] $entry.box -eq $endpoint)
            }
            Set-P2Range $designer "${field}Slider" 0
            foreach ($key in @(
                @{ input = "${field}Slider"; key = '{RIGHT}'; value = $spec.step; label = 'arrow' },
                @{ input = "${field}Slider"; key = '{PGUP}'; value = 6 * $spec.step; label = 'page' },
                @{ input = "${field}Slider"; key = '{HOME}'; value = 0; label = 'home' },
                @{ input = "${field}Slider"; key = '{END}'; value = $spec.max; label = 'end' },
                @{ input = "${field}Box"; key = '{DOWN}'; value = $spec.max - $spec.step; label = 'numberArrow' },
                @{ input = "${field}Box"; key = '{UP}'; value = $spec.max; label = 'numberUp' },
                @{ input = "${field}Box"; key = '{PGDN}'; value = $spec.max - 5 * $spec.step; label = 'numberPage' }
            )) {
                Set-P2Focus $designer $key.input
                [System.Windows.Forms.SendKeys]::SendWait($key.key)
                $state = Wait-For { $s = (Get-P2DesignerHook $run).state; if ($s.options.$field -eq $key.value) { $s } } 3 100
                $entry = [ordered]@{ state = $state; expected = $key.value; focus = Get-P2Focus
                    slider = (Get-Pattern (Assert-P2Control $designer "${field}Slider") ([System.Windows.Automation.RangeValuePattern])).Current.Value
                    box = Get-P2Text $designer "${field}Box" }
                $evidence["keyboard.$field.$($key.label)"] = $entry
                Add-Check "A-DESIGNER.fx.keyboard.$field.$($key.label)" 'native key commits snapped override with synchronized slider and inner InputBox' $entry (
                    $state -and $null -ne $state.options.$field -and $entry.slider -eq $key.value -and [double] $entry.box -eq $key.value)
            }
            foreach ($typed in @(
                @{ text = '0'; value = 0; label = 'min' }, @{ text = "$($spec.max)"; value = $spec.max; label = 'max' },
                @{ text = $(if ($spec.step -eq 1) { '2.5' } else { '12.5' }); value = 3 * $spec.step; label = 'snap' }
            )) {
                Set-P2Focus $designer "${field}Box"
                [System.Windows.Forms.SendKeys]::SendWait("^a$($typed.text){TAB}")
                $state = (Get-P2DesignerHook $run).state
                $entry = [ordered]@{ typed = $typed; state = $state; box = Get-P2Text $designer "${field}Box"
                    slider = (Get-Pattern (Assert-P2Control $designer "${field}Slider") ([System.Windows.Automation.RangeValuePattern])).Current.Value }
                $evidence["number.$field.$($typed.label)"] = $entry
                Add-Check "A-DESIGNER.fx.number.$field.$($typed.label)" 'NumberBox accepts endpoints and ties-up snapping, preserving paired slider' $entry (
                    $null -ne $state.options.$field -and $state.options.$field -eq $typed.value -and
                    $entry.slider -eq $typed.value -and [double] $entry.box -eq $typed.value)
            }
            foreach ($invalid in @(@{ text = 'not-a-number'; label = 'text' }, @{ text = ''; label = 'empty' })) {
                $before = (Get-P2DesignerHook $run).state
                Set-P2Focus $designer "${field}Box"
                [System.Windows.Forms.SendKeys]::SendWait("^a{BACKSPACE}$($invalid.text){TAB}")
                $after = (Get-P2DesignerHook $run).state
                $entry = [ordered]@{ before = $before; after = $after; box = Get-P2Text $designer "${field}Box" }
                $evidence["invalid.$field.$($invalid.label)"] = $entry
                Add-Check "A-DESIGNER.fx.invalid.$field.$($invalid.label)" 'invalid/empty NumberBox reverts without a new draft revision' $entry (
                    (Test-P2FxEqual $before.options $after.options) -and $before.draftRev -eq $after.draftRev -and
                    [double] $entry.box -eq $before.options.$field)
            }
            Invoke-Element (Assert-P2Control $designer "${field}ResetButton")
            $reset = (Get-P2DesignerHook $run).state
            Add-Check "A-DESIGNER.fx.reset.$field" 'Reset removes an explicit override, leaving a dirty draft' $reset (
                $null -eq $reset.options.$field -and $reset.dirty)
        }
        [void] (Invoke-P2FxRevert $designer)
        $reader = Start-SseReader 'designer-fx-isolation' 60 '/events?look=fxui0007&sample=playing'
        $initial = Wait-SseLook $reader { param($l) $l.id -eq 'fxui0007' } 15
        $before = Get-P2DesignerSnapshot $designer
        $beforePage = Get-P2PreviewPageState $run; $start = Get-Qpc
        $draftFx = [ordered]@{ BackgroundBlur = 32; PlayedBrightness = 50; UnplayedBrightness = 20; BackgroundBrightness = 60 }
        foreach ($field in $script:p2FxFields) { Set-P2Range $designer "${field}Slider" $draftFx[$field] }
        $page = Wait-For { $p = Get-P2PreviewPageState $run; if (Test-P2ResolvedFx $p $draftFx) { $p } } 8 100
        $after = Get-P2DesignerSnapshot $designer
        $sourceEvents = @(Get-LookEvents (Read-Sse $reader) | Where-Object { $_.qpc -gt $start })
        $evidence.preview = [ordered]@{ before = $before; beforePage = $beforePage; after = $after; page = $page; source = $initial; sourceEvents = $sourceEvents }
        Add-Check 'A-DESIGNER.fx.previewIsolation' 'debounced resolved preview effects; saved source and file unchanged before Save; source dimensions unchanged' $evidence.preview (
            $initial -and (Test-P2FxEqual $initial.data.options $nullFx) -and $page -and (Test-P2FxEqual $page.options $draftFx) -and
            $after.designer.state.dirty -and $after.file -eq $before.file -and $after.size -eq $before.size -and $sourceEvents.Count -eq 0 -and
            (($page.source | ConvertTo-Json -Compress) -ceq ($beforePage.source | ConvertTo-Json -Compress)) -and
            (($page.box | ConvertTo-Json -Compress) -ceq ($beforePage.box | ConvertTo-Json -Compress)))
        Invoke-Element (Assert-P2Control $designer 'SaveLookButton')
        $saved = Wait-For { $s = Get-P2DesignerHook $run; if (-not $s.state.dirty) { $s } } 8
        $source = Wait-SseLook $reader { param($l) $l.id -eq 'fxui0007' -and (Test-P2FxEqual $l.options $draftFx) } 8 $start
        $disk = @((Read-ObsLooksFile $run.Root).looks | Where-Object { $_.id -eq 'fxui0007' })[0]
        $evidence.saved = [ordered]@{ designer = $saved; source = $source; disk = $disk }
        Add-Check 'A-DESIGNER.fx.dirtySave' 'Save publishes exact draft effects on same id and clears dirty' $evidence.saved (
            $saved -and $source -and (Test-P2FxEqual $disk.options $draftFx) -and $saved.state.sourceId -eq 'fxui0007')
        Set-P2Range $designer 'BackgroundBlurSlider' 0
        $reverted = Invoke-P2FxRevert $designer
        $revertedPage = Wait-For { $p = Get-P2PreviewPageState $run; if (Test-P2ResolvedFx $p $draftFx) { $p } } 8
        $evidence.reverted = [ordered]@{ designer = $reverted; page = $revertedPage }
        Add-Check 'A-DESIGNER.fx.savedRevert' 'Revert restores committed effects in preview and clears dirty' $evidence.reverted (
            -not $reverted.state.dirty -and (Test-P2FxEqual $reverted.state.options $draftFx) -and $revertedPage)
        Add-Blocked 'A-DESIGNER.fx.narrator' 'Narrator reads effect names, units, default status, inactive explanation and reset actions' 'Requires an operator-assisted Narrator session; UIA checks do not prove speech output.'
    } finally {
        [void] (Save-P2Evidence 'designer-fx' $evidence)
        Stop-SseReader $reader; Close-P2Designer $designer -Cleanup; if ($run) { Stop-OverlayRun $run }
    }
}
function Get-P2SavedFxPage($Chrome, [string] $Id, [string] $Theme) {
    Set-OverlayViewport $Chrome (Get-DefaultThemeSize $Theme).source
    [void] (Invoke-ChromeNavigate $Chrome ("${overlayUrl}?look=$Id&sample=paused"))
    $page = Wait-For {
        $p = Get-PageProbe $Chrome
        if ((Get-PageField $p 'connection') -eq 'open' -and (Get-PageField $p 'state') -eq 'paused' -and
            (Get-PageField $p 'shown') -eq $true -and (Get-PageField $p 'artLoadedSeq') -ge 1 -and
            (Get-PageField $p 'artLoadedSeq') -eq (Get-PageField $p 'artSeq') -and
            (Get-PageField $p 'artFailed') -eq $false -and $p.running -eq 0) { $p }
    } 20 100
    if (-not $page) { throw "Saved LookFx page $Id/$Theme did not settle to loaded, visible, paused pixels." }
    $page
}
function Test-P2LookFxStore {
    $themes = @('pill', 'matte', 'matte-light', 'standard', 'classic', 'simple', 'album-art', 'card')
    $nullFx = [ordered]@{ BackgroundBlur = $null; PlayedBrightness = $null; UnplayedBrightness = $null; BackgroundBrightness = $null }
    $customFx = [ordered]@{ BackgroundBlur = 23; PlayedBrightness = 150; UnplayedBrightness = 75; BackgroundBrightness = 150 }
    $seed = @($themes | ForEach-Object {
        $options = Get-ThemeDefaults $_
        foreach ($field in $script:p2FxFields) { $options.Remove($field) }
        $options['paused'] = 'dim'; $options['showAnimation'] = 'none'; $options['hideAnimation'] = 'none'
        New-ObsLook ("fxst000{0}" -f [array]::IndexOf($themes, $_)) "Legacy $_" $options
    })
    $json = ConvertTo-ObsLooksJson (New-ObsLooksDocument $seed)
    $seedHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($json))).ToLowerInvariant()
    $run = $null; $designer = $null; $reader = $null; $chrome = $null; $evidence = [ordered]@{}
    try {
        $run = Start-OverlayRun 'A-STORE-2-fx' @{} 'PlayingLong' -NoReader -LooksJson $json
        $file = Join-Path $run.Root 'data/obs-looks.json'
        $designer = Open-P2Designer $run
        Select-P2Item $designer 'PreviewStatePicker' 'Paused'
        $hasChrome = Test-ChromeAvailable 'A-STORE-2.fx'
        if ($hasChrome) { $chrome = Start-Chrome 'store2-fx' }
        $before = [ordered]@{}
        $evidence.missing = $before
        foreach ($theme in $themes) {
            $id = "fxst000{0}" -f [array]::IndexOf($themes, $theme)
            [void] (Select-P2Look $designer "Legacy $theme")
            $defaults = Get-P2FxDefaults $theme
            $native = Get-P2DesignerHook $run
            $page = Wait-For { $p = Get-P2PreviewPageState $run; if ($p.theme -eq $theme -and (Test-P2ResolvedFx $p $defaults)) { $p } } 10
            $entry = [ordered]@{ native = $native; preview = $page; hash = Get-Sha256 $file }
            if (-not $page) {
                $entry['timeout'] = Save-P2DesignerDiagnostics $run "fx-missing-$theme-timeout" @{ sourceId = $id; theme = $theme; resolved = $defaults }
            }
            if ($chrome) {
                $entry.source = Get-P2SavedFxPage $chrome $id $theme
                $entry.pixels = Save-P2PixelEvidence $chrome "fx-missing-$theme"
                Reset-ChromeCasePage $chrome
            }
            $before[$theme] = $entry
            Add-Check "A-STORE-2.fx.missingLoad.$theme" 'missing effects load as null with resolved theme defaults; opening/selecting/preview never writes' $entry (
                $entry.hash -eq $seedHash -and -not $native.state.dirty -and (Test-P2FxEqual $native.state.options $nullFx) -and
                $page -and (Test-P2FxEqual $page.options $nullFx))
        }
        Close-P2Designer $designer; $designer = $null
        Send-ObsHookCommand $run.Root 'command-obs-looks-reload' | Out-Null
        $designer = Open-P2Designer $run
        [void] (Select-P2Look $designer 'Legacy card')
        $loadedHash = Get-Sha256 $file
        Add-Check 'A-STORE-2.fx.noReadTimeWrite' 'startup, disk reload and designer reopen keep exact legacy file hash until explicit Save' (
            [ordered]@{ expected = $seedHash; afterReopen = $loadedHash }) ($loadedHash -eq $seedHash)
        # A no-edit Save must materialise all four nullable keys without changing the default rendering.
        Invoke-Element (Assert-P2Control $designer 'SaveLookButton')
        $explicit = Wait-For {
            $d = Read-ObsLooksFile $run.Root
            if ($d.looks[0].options.PSObject.Properties['backgroundBlur']) { $d }
        } 8
        $evidence.explicit = [ordered]@{ disk = $explicit; before = $seedHash; after = Get-Sha256 $file }
        $allExplicit = $null -ne $explicit -and $explicit.version -eq 1
        foreach ($look in @($explicit.looks)) {
            foreach ($field in $script:p2FxFields) {
                $key = $field.Substring(0, 1).ToLowerInvariant() + $field.Substring(1)
                $allExplicit = $allExplicit -and $null -ne $look.options.PSObject.Properties[$key] -and $null -eq $look.options.$key
            }
        }
        Add-Check 'A-STORE-2.fx.explicitNullKeys' 'successful no-edit Save writes four explicit null camelCase keys for every look; version remains 1' $evidence.explicit (
            $allExplicit -and (Get-Sha256 $file) -ne $seedHash)
        Select-P2Item $designer 'PreviewStatePicker' 'Paused'
        foreach ($theme in $themes) {
            $id = "fxst000{0}" -f [array]::IndexOf($themes, $theme)
            [void] (Select-P2Look $designer "Legacy $theme")
            $defaults = Get-P2FxDefaults $theme
            $page = Wait-For { $p = Get-P2PreviewPageState $run; if ($p.theme -eq $theme -and (Test-P2ResolvedFx $p $defaults)) { $p } } 10
            $entry = [ordered]@{ missing = $before[$theme]; explicitPreview = $page }
            if (-not $page) {
                $entry['timeout'] = Save-P2DesignerDiagnostics $run "fx-explicit-$theme-timeout" @{ sourceId = $id; theme = $theme; resolved = $defaults }
            }
            $stateEqual = $page -and $before[$theme].preview -and
                (($page.options | ConvertTo-Json -Compress) -ceq ($before[$theme].preview.options | ConvertTo-Json -Compress)) -and
                (($page.fx | ConvertTo-Json -Compress) -ceq ($before[$theme].preview.fx | ConvertTo-Json -Compress)) -and
                (($page.source | ConvertTo-Json -Compress) -ceq ($before[$theme].preview.source | ConvertTo-Json -Compress))
            Add-Check "A-STORE-2.fx.missingStateEqual.$theme" 'legacy missing and explicit null resolve to identical preview options/effects/source size' $entry $stateEqual
            if ($chrome) {
                $entry.explicitSource = Get-P2SavedFxPage $chrome $id $theme
                $entry.explicitPixels = Save-P2PixelEvidence $chrome "fx-null-$theme"
                Add-Check "A-STORE-2.fx.missingPixelEqual.$theme" 'decoded RGBA pixels are exactly equal before and after explicit-null Save' $entry (
                    $entry.explicitPixels.pixelHash -ceq $before[$theme].pixels.pixelHash -and
                    $entry.explicitPixels.width -eq $before[$theme].pixels.width -and $entry.explicitPixels.height -eq $before[$theme].pixels.height -and
                    ((Get-PageField $entry.explicitSource 'options') | ConvertTo-Json -Compress) -ceq
                        ((Get-PageField $before[$theme].source 'options') | ConvertTo-Json -Compress))
                Reset-ChromeCasePage $chrome
            } else {
                Add-Blocked "A-STORE-2.fx.missingPixelEqual.$theme" 'exact legacy/default RGBA pixel equality' "Google Chrome unavailable at $chromeExe."
            }
            $evidence["legacy.$theme"] = $entry
        }
        [void] (Select-P2Look $designer 'Legacy card')
        $evidence.beforeFxMutation = Save-P2DesignerDiagnostics $run 'fx-card-before-mutation' @{ sourceId = 'fxst0007'; theme = 'card' }
        $reader = Start-SseReader 'store2-fx-source' 60 '/events?look=fxst0007&sample=paused'
        [void] (Wait-SseLook $reader { param($l) $l.id -eq 'fxst0007' } 15)
        foreach ($kind in @('override', 'null')) {
            $expected = if ($kind -eq 'override') { $customFx } else { $nullFx }
            foreach ($field in $script:p2FxFields) {
                if ($kind -eq 'null') { Invoke-Element (Assert-P2Control $designer "${field}ResetButton") }
                else { Set-P2Range $designer "${field}Slider" $expected[$field] }
            }
            $dirty = Get-P2DesignerHook $run; $start = Get-Qpc
            Invoke-Element (Assert-P2Control $designer 'SaveLookButton')
            $saved = Wait-For {
                $s = Get-P2DesignerHook $run
                if (-not $s.state.dirty -and (Test-P2FxEqual $s.state.options $expected)) { $s }
            } 8
            $event = Wait-SseLook $reader { param($l) $l.id -eq 'fxst0007' -and (Test-P2FxEqual $l.options $expected) } 8 $start
            $disk = @((Read-ObsLooksFile $run.Root).looks | Where-Object { $_.id -eq 'fxst0007' })[0]
            Close-P2Designer $designer; $designer = $null
            $savedHash = Get-Sha256 $file
            Send-ObsHookCommand $run.Root 'command-obs-looks-reload' | Out-Null
            $designer = Open-P2Designer $run
            [void] (Select-P2Look $designer 'Legacy card')
            $reopened = Get-P2DesignerHook $run
            $reopenedHash = Get-Sha256 $file
            Invoke-Element (Assert-P2Control $designer 'DuplicateLookButton')
            $duplicate = Get-P2DesignerHook $run
            Set-P2Value (Assert-P2Control $designer 'LookNameBox') "FX $kind copy"
            Invoke-Element (Assert-P2Control $designer 'SaveLookButton')
            $copySaved = Wait-For { $s = Get-P2DesignerHook $run; if (-not $s.state.dirty -and $s.state.sourceId -ne 'fxst0007') { $s } } 8
            $copyDisk = @((Read-ObsLooksFile $run.Root).looks | Where-Object { $_.name -eq "FX $kind copy" }) | Select-Object -First 1
            foreach ($field in $script:p2FxFields) {
                $different = if ($kind -eq 'null') { 0 } elseif ($field -eq 'BackgroundBlur') { 32 } else { 0 }
                Set-P2Range $designer "${field}Slider" $different
            }
            $copyDirty = Get-P2DesignerHook $run
            $reverted = Invoke-P2FxRevert $designer
            $entry = [ordered]@{ dirty = $dirty; saved = $saved; disk = $disk; event = $event; reopened = $reopened
                duplicate = $duplicate; copySaved = $copySaved; copyDisk = $copyDisk; copyDirty = $copyDirty; reverted = $reverted
                savedHash = $savedHash; reopenedHash = $reopenedHash }
            $evidence["roundTrip.$kind"] = $entry
            foreach ($field in $script:p2FxFields) {
                $exact = $dirty.state.dirty -and $saved -and $disk -and $copySaved -and $copyDisk -and $copyDirty.state.dirty -and
                    $saved.state.sourceId -eq 'fxst0007' -and -not $reopened.state.dirty -and $duplicate.state.dirty -and
                    $null -eq $duplicate.state.sourceId -and -not $reverted.state.dirty -and $reopenedHash -eq $savedHash -and
                    $copySaved.state.sourceId -match '^[a-z0-9]{8}$' -and $copySaved.state.sourceId -eq $copyDisk.id
                $key = $field.Substring(0, 1).ToLowerInvariant() + $field.Substring(1)
                $exact = $exact -and $null -ne $disk.options.PSObject.Properties[$key] -and $null -ne $copyDisk.options.PSObject.Properties[$key]
                foreach ($options in @($disk.options, $saved.state.options, $reopened.state.options, $duplicate.state.options, $copyDisk.options, $reverted.state.options)) {
                    $actual = Get-Prop $options $field
                    $exact = $exact -and $(if ($kind -eq 'null') { $null -eq $actual } else { $null -ne $actual -and $actual -eq $expected[$field] })
                }
                Add-Check "A-STORE-2.fx.roundTrip.$kind.$field" 'exact override/null survives Save, reopen, Duplicate Save and Revert; revisions/dirty states correct' $entry $exact
            }
            Add-Check "A-STORE-2.fx.sameIdEvent.$kind" 'effect-only Save notifies same id with all four new effect values' $entry (
                $event -and $event.data.id -eq 'fxst0007' -and (Test-P2FxEqual $event.data.options $expected))
            [void] (Select-P2Look $designer 'Legacy card')
        }
        # The save captures one FX revision, not whatever newer FX values exist when I/O finishes.
        Set-P2Range $designer 'BackgroundBlurSlider' 7
        Send-ObsHookCommand $run.Root 'command-obs-store-fault' 'slow 3000' | Out-Null
        Invoke-Element (Assert-P2Control $designer 'SaveLookButton')
        $saving = Wait-For { -not (Assert-P2Control $designer 'SaveLookButton').Current.IsEnabled } 2 50
        Set-P2Range $designer 'BackgroundBlurSlider' 9
        $settled = Wait-For {
            $d = @((Read-ObsLooksFile $run.Root).looks | Where-Object { $_.id -eq 'fxst0007' })[0]
            $s = Get-P2DesignerHook $run
            if ($d.options.backgroundBlur -eq 7 -and (Assert-P2Control $designer 'SaveLookButton').Current.IsEnabled) {
                [ordered]@{ disk = $d; designer = $s }
            }
        } 8
        $resolved = [ordered]@{ BackgroundBlur = 9; PlayedBrightness = 100; UnplayedBrightness = 100; BackgroundBrightness = 35 }
        $page = Wait-For { $p = Get-P2PreviewPageState $run; if (Test-P2ResolvedFx $p $resolved) { $p } } 8
        $evidence.slowSave = [ordered]@{ saving = $saving; settled = $settled; preview = $page }
        Add-Check 'A-STORE-2.fx.slowSaveNewerEdit' 'slow Save commits blur 7; newer blur 9 stays dirty in debounced preview' $evidence.slowSave (
            $saving -and $settled -and $settled.designer.state.options.BackgroundBlur -eq 9 -and $settled.designer.state.dirty -and
            $settled.designer.state.draftRev -gt $settled.designer.state.lastSavedRev -and $page)
        [void] (Invoke-P2FxRevert $designer)
        $beforeHash = Get-Sha256 $file
        $fresh = Start-SseReader 'store2-fx-failure-before' 60 '/events?look=fxst0007&sample=paused'
        try { $beforeSource = Wait-SseLook $fresh { param($l) $l.id -eq 'fxst0007' } 15 } finally { Stop-SseReader $fresh }
        $failureStart = Get-Qpc
        Set-P2Range $designer 'PlayedBrightnessSlider' 50
        Send-ObsHookCommand $run.Root 'command-obs-store-fault' 'replace' | Out-Null
        Invoke-Element (Assert-P2Control $designer 'SaveLookButton')
        $failure = Wait-For { $r = Get-P2Result $designer; if ($r -like '*Could not save*') { $r } } 8
        $after = Get-P2DesignerHook $run
        $events = @(Get-LookEvents (Read-Sse $reader) | Where-Object { $_.qpc -gt $failureStart })
        $fresh = Start-SseReader 'store2-fx-failure-after' 60 '/events?look=fxst0007&sample=paused'
        try { $afterSource = Wait-SseLook $fresh { param($l) $l.id -eq 'fxst0007' } 15 } finally { Stop-SseReader $fresh }
        $evidence.failedSave = [ordered]@{ before = $beforeHash; after = Get-Sha256 $file; result = $failure
            draft = $after; sourceBefore = $beforeSource; sourceAfter = $afterSource; events = $events }
        Add-Check 'A-STORE-2.fx.failedSaveIsolation' 'failed effect Save preserves exact file bytes, connected and fresh source effects, and dirty draft' $evidence.failedSave (
            $beforeHash -eq $evidence.failedSave.after -and $failure -like '*OBS sources are unchanged*' -and $after.state.dirty -and
            $after.state.options.PlayedBrightness -eq 50 -and $events.Count -eq 0 -and $beforeSource -and $afterSource -and
            ((Get-P2Fx $beforeSource.data.options) | ConvertTo-Json -Compress) -ceq ((Get-P2Fx $afterSource.data.options) | ConvertTo-Json -Compress) -and
            (($beforeSource.data.options | ConvertTo-Json -Compress) -ceq ($afterSource.data.options | ConvertTo-Json -Compress)) -and
            (($beforeSource.data.source | ConvertTo-Json -Compress) -ceq ($afterSource.data.source | ConvertTo-Json -Compress)) -and
            $beforeSource.data.id -eq $afterSource.data.id -and $beforeSource.data.theme -eq $afterSource.data.theme)
        [void] (Invoke-P2FxRevert $designer)
    } finally {
        [void] (Save-P2Evidence 'store2-fx' $evidence)
        Stop-SseReader $reader; Stop-Chrome $chrome; Close-P2Designer $designer -Cleanup; if ($run) { Stop-OverlayRun $run }
    }
}
function Test-AStore2 {
    $seed = @((New-ObsLook 'store001' 'Primary' (Get-ThemeDefaults 'matte')),
        (New-ObsLook 'store002' 'Secondary' (Get-ThemeDefaults 'card')))
    $run = $null; $designer = $null; $watcher = $null; $reader = $null; $evidence = [ordered]@{}
    try {
        $run = Start-OverlayRun 'A-STORE-2' @{} 'PlayingLong' -NoReader -LooksJson (ConvertTo-ObsLooksJson (New-ObsLooksDocument $seed))
        $designer = Open-P2Designer $run -Settings
        [void] (Select-P2Look $designer 'Primary')
        $save = Assert-P2Control $designer 'SaveLookButton'
        $evidence.initial = Get-P2DesignerSnapshot $designer
        Add-Check 'A-STORE-2.saveEnabled' 'Save enabled when no commit is in flight' (Describe $save) $save.Current.IsEnabled
        $evidence.shot = Save-WindowShot $designer.Hwnd 'designer-store-initial'
        $reader = Start-SseReader 'store2-primary' 20 '/events?look=store001&sample=playing'
        [void] (Wait-SseLook $reader { param($l) (Get-Prop $l 'id') -eq 'store001' } 15)
        $watcher = Watch-P2Writes $run.Root
        Send-ObsHookCommand $run.Root 'command-obs-store-fault' 'slow 3000' | Out-Null
        Set-P2Value (Assert-P2Control $designer 'LookNameBox') 'Rev 1'
        $start = Get-Qpc
        Invoke-Element $save
        $disabled = Wait-For { if (-not $save.Current.IsEnabled) { Get-P2DesignerSnapshot $designer } } 2 50
        $secondIgnored = $false
        try { Invoke-Element $save } catch { $secondIgnored = $true }
        $samples = [Collections.Generic.List[object]]::new()
        for ($i = 0; $i -lt 8; $i++) {
            $bytes = [IO.File]::ReadAllBytes((Join-Path $run.Root 'data/obs-looks.json'))
            $valid = try { $null -ne ([Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json -Depth 16).looks } catch { $false }
            $samples.Add([ordered]@{ utc = [DateTime]::UtcNow.ToString('o'); hash = Get-Sha256 (Join-Path $run.Root 'data/obs-looks.json'); valid = $valid })
            Start-Sleep -Milliseconds 250
        }
        $saved = Wait-For { if ((Read-ObsLooksFile $run.Root).looks[0].name -eq 'Rev 1') { Get-P2DesignerSnapshot $designer } } 8
        $streamEvent = Wait-SseLook $reader { param($l) (Get-Prop $l 'id') -eq 'store001' } 4 $start
        $writes = @(Stop-P2Writes $watcher); $watcher = $null
        $evidence.firstCommit = [ordered]@{ disabled = $disabled; secondIgnored = $secondIgnored; samples = $samples.ToArray()
            writes = $writes; saved = $saved; stream = $streamEvent; elapsed = Round3 (Get-Seconds $start (Get-Qpc)) }
        Add-Check 'A-STORE-2.singleWriter' 'disabled during 3 s commit; second click cannot cause another tmp/replace; always valid JSON' $evidence.firstCommit (
            $disabled -and $saved -and @($samples | Where-Object { -not $_.valid }).Count -eq 0 -and
            @($writes | Where-Object { $_.type -eq 'Created' -and $_.name -eq 'obs-looks.json.tmp' }).Count -eq 1 -and
            @($writes | Where-Object { $_.type -in @('Renamed', 'Created') -and $_.name -eq 'obs-looks.json' }).Count -le 1 -and
            @($writes | Where-Object { $_.name -eq 'obs-looks.json' -and $_.type -in @('Renamed', 'Changed', 'Created') }).Count -ge 1)
        Add-Check 'A-STORE-2.published' 'durable Save notifies the tagged stream and reports success' $evidence.firstCommit (
            $streamEvent -and $saved.result -like '*Look saved*')
        # Save captures rev 1; editing while the three-second write waits leaves rev 2 dirty in the preview.
        Send-ObsHookCommand $run.Root 'command-obs-store-fault' 'slow 3000' | Out-Null
        Set-P2Range $designer 'WidthSlider' 450
        Invoke-Element $save
        $mid = Wait-For { -not $save.Current.IsEnabled } 2 50
        Set-P2Range $designer 'WidthSlider' 460
        $settled = Wait-For { if ((Read-ObsLooksFile $run.Root).looks[0].options.width -eq 450) { Get-P2DesignerSnapshot $designer } } 7
        $evidence.editWhileSaving = [ordered]@{ mid = $mid; after = $settled; file = Read-ObsLooksFile $run.Root }
        Add-Check 'A-STORE-2.revision' 'width 450 on disk, 460 in dirty live preview after commit' $evidence.editWhileSaving (
            $mid -and $settled -and "$($settled.width)" -like '*460*' -and
            (Get-Prop (Get-Prop $settled.designer 'state') 'dirty') -eq $true -and
            (Get-Prop (Get-Prop $settled.designer 'state') 'draftRev') -gt (Get-Prop (Get-Prop $settled.designer 'state') 'lastSavedRev'))
        # Off/on while a save is pending must start the new server with the committed state, not a stale snapshot.
        Send-ObsHookCommand $run.Root 'command-obs-store-fault' 'slow 3000' | Out-Null
        Set-P2Range $designer 'WidthSlider' 470
        Invoke-Element $save
        [void] (Wait-For { -not $save.Current.IsEnabled } 2 50)
        Send-HookCommand $run.Root 'command-obs-off' | Out-Null
        $offPrompt = Invoke-P2DialogChoice $run 'The overlay was turned off.*' 'Cancel'
        $evidence.offPrompt = $offPrompt
        Send-HookCommand $run.Root 'command-obs-on' | Out-Null
        [void] (Wait-For { (Read-ObsLooksFile $run.Root).looks[0].options.width -eq 470 } 8)
        $fresh = Start-SseReader 'store2-restarted' 20 '/events?look=store001&sample=playing'
        try { $look = Wait-SseLook $fresh { param($l) (Get-Prop $l 'id') -eq 'store001' -and (Get-Prop (Get-Prop $l 'options') 'width') -eq 470 } 15
            $evidence.offOn = [ordered]@{ disk = Read-ObsLooksFile $run.Root; look = $look }
            Add-Check 'A-STORE-2.offOn' 'fresh server after off/on serves committed width 470' $evidence.offOn ($null -ne $look)
        } finally { Stop-SseReader $fresh }
        # Read-only state is not rewritten by Save; Reload returns the UI to writable after correction.
        Close-P2Designer $designer; $designer = $null
        $future = (New-ObsLooksDocument $seed @() 2)
        [void] (Write-ObsLooksFile $run.Root (ConvertTo-ObsLooksJson $future))
        $hash = Get-Sha256 (Join-Path $run.Root 'data/obs-looks.json')
        Send-ObsHookCommand $run.Root 'command-obs-looks-reload' | Out-Null
        $designer = Open-P2Designer $run
        [void] (Select-P2Look $designer 'Primary')
        $readonly = Get-P2DesignerSnapshot $designer
        $readonlyBanner = (Assert-P2Control $designer 'StoreStatusText').Current.Name
        $readonlySaveEnabled = (Assert-P2Control $designer 'SaveLookButton').Current.IsEnabled
        Invoke-Element (Assert-P2Control $designer 'SaveLookButton')
        $readonlyResult = Wait-For { $r = Get-P2Result $designer; if ($r -like '*Could not save*') { $r } } 5
        $evidence.readonly = [ordered]@{ banner = $readonlyBanner; saveEnabled = $readonlySaveEnabled; result = $readonlyResult; snapshot = $readonly }
        Add-Check 'A-STORE-2.readOnly' 'future version: banner, Save rejects without changing bytes' $evidence.readonly (
            $readonlyBanner -like '*newer Nativune*' -and $readonly.file -eq $hash -and $readonlySaveEnabled -and
            $readonlyResult -like '*Could not save*' -and (Get-Sha256 (Join-Path $run.Root 'data/obs-looks.json')) -eq $hash)
        [void] (Write-ObsLooksFile $run.Root (ConvertTo-ObsLooksJson (New-ObsLooksDocument $seed)))
        Invoke-Element (Assert-P2Control $designer 'ReloadLooksButton')
        $reload = Wait-For {
            $banner = (Assert-P2Control $designer 'StoreStatusText').Current.Name
            if ($banner -notlike '*newer Nativune*') { [ordered]@{ banner = $banner; snapshot = Get-P2DesignerSnapshot $designer } }
        } 10
        Add-Check 'A-STORE-2.reload' 'Reload looks file re-enables writes after repair' $reload (
            $reload -and (Assert-P2Control $designer 'SaveLookButton').Current.IsEnabled)
        # Fault before replace must preserve both bytes and published look.
        [void] (Select-P2Look $designer 'Primary')
        $before = Get-Sha256 (Join-Path $run.Root 'data/obs-looks.json')
        Set-P2Value (Assert-P2Control $designer 'LookNameBox') 'Failed commit'
        Send-ObsHookCommand $run.Root 'command-obs-store-fault' 'replace' | Out-Null
        Invoke-Element (Assert-P2Control $designer 'SaveLookButton')
        $failure = Wait-For { $r = Get-P2Result $designer; if ($r -like '*Could not save*') { $r } } 8
        $evidence.failedSave = [ordered]@{ before = $before; after = Get-Sha256 (Join-Path $run.Root 'data/obs-looks.json'); result = $failure; draft = Get-P2DesignerSnapshot $designer }
        Add-Check 'A-STORE-2.saveFailure' 'old file untouched, dirty draft intact, honest error' $evidence.failedSave (
            $before -eq $evidence.failedSave.after -and $failure -like '*OBS sources are unchanged*' -and $evidence.failedSave.draft.name -eq 'Failed commit')
        # 2026-10-02 owner decision: Delete targets only selected look; selecting another row exercises abandonment.
        # UI capacity is enforced on Save, not merely on file load.
        (Assert-P2Control $designer 'LookNameBox').SetFocus()
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.SendKeys]::SendWait('{ESC}')
        [void] (Invoke-P2DialogChoice $run 'Save changes*' 'Discard')
        Close-P2Designer $designer; $designer = $null
        $sixteen = @()
        for ($i = 0; $i -lt 16; $i++) { $sixteen += New-ObsLook ("limit{0:d3}" -f $i) ("Look $i") (Get-ThemeDefaults 'pill') }
        [void] (Write-ObsLooksFile $run.Root (ConvertTo-ObsLooksJson (New-ObsLooksDocument $sixteen)))
        Send-ObsHookCommand $run.Root 'command-obs-looks-reload' | Out-Null
        $designer = Open-P2Designer $run
        [void] (Select-P2Look $designer 'Look 0')
        $selectedKey = (Get-P2DesignerHook $run).state.draftKey
        Invoke-Element (Assert-P2Control $designer 'NewLookButton')
        $newDraft = Wait-P2EffectiveDraft $designer $null 0 'limit16-new-draft' $selectedKey
        $sixteenHash = Get-Sha256 (Join-Path $run.Root 'data/obs-looks.json')
        $capacityReader = Start-SseReader 'store2-limit-source' 60 '/events?look=limit000&sample=playing'
        try {
            $sourceBefore = Wait-SseLook $capacityReader { param($l) $l.id -eq 'limit000' -and -not $l.missing } 15
            if (-not $sourceBefore) { throw 'Capacity baseline source did not publish limit000.' }
            $saveStart = Get-Qpc
            Invoke-Element (Assert-P2Control $designer 'SaveLookButton')
            $lastLimit = @{ result = $null; status = $null }
            $limit = Wait-For {
                $lastLimit.result = Get-P2Result $designer
                $lastLimit.status = (Assert-P2Control $designer 'StoreStatusText').Current.Name
                if ($lastLimit.result -ceq 'Could not save; OBS sources are unchanged.' -and
                    $lastLimit.status -ceq 'You already have 16 looks; delete one first') {
                    [ordered]@{ result = $lastLimit.result; status = $lastLimit.status }
                }
            } 8 150
            $freshReader = Start-SseReader 'store2-limit-fresh' 20 '/events?look=limit000&sample=playing'
            try { $sourceAfter = Wait-SseLook $freshReader { param($l) $l.id -eq 'limit000' -and -not $l.missing } 15 }
            finally { Stop-SseReader $freshReader }
            $events = @(Get-LookEvents (Read-Sse $capacityReader) | Where-Object { $_.qpc -gt $saveStart })
            $evidence.limit = [ordered]@{ newDraft = $newDraft; result = $lastLimit.result; status = $lastLimit.status
                before = $sixteenHash; after = Get-Sha256 (Join-Path $run.Root 'data/obs-looks.json')
                sourceBefore = $sourceBefore; sourceAfter = $sourceAfter; events = $events
                diagnostics = Save-P2DesignerDiagnostics $run 'limit16-result' $lastLimit }
            Add-Check 'A-STORE-2.limit16' 'completed New; generic failure plus exact capacity status; bytes and publication unchanged' $evidence.limit (
                $newDraft -and $limit -and $sixteenHash -eq $evidence.limit.after -and $events.Count -eq 0 -and $sourceAfter -and
                ($sourceBefore.data.options | ConvertTo-Json -Compress) -ceq ($sourceAfter.data.options | ConvertTo-Json -Compress) -and
                ($sourceBefore.data.source | ConvertTo-Json -Compress) -ceq ($sourceAfter.data.source | ConvertTo-Json -Compress))
        } finally { Stop-SseReader $capacityReader }
    } finally {
        if ($watcher) { $evidence.writes = @(Stop-P2Writes $watcher) }
        [void] (Save-P2Evidence 'store2' $evidence)
        Close-P2Designer $designer -Cleanup; Stop-SseReader $reader; if ($run) { Stop-OverlayRun $run }
        $scenarioResults['A-STORE-2'] = $evidence
    }
    Test-P2LookFxStore
    Test-P2StoreAbandonment
    Test-P2StoreDelete
    Test-P2StoreCancellation
    Test-P2StoreShutdown
    Test-P2PromptSaveEditRace
    Test-P2OffActions
}
function Test-P2StoppedOverlay($Snapshot) {
    $overlay = Get-Prop $Snapshot 'overlay'
    $preview = Get-Prop $overlay 'previewNonces'
    $open = Get-Prop $preview 'open'
    # When Off destroys the server, previewNonces is absent/{} rather than a live {open:0} record.
    $null -ne $overlay -and (Get-Prop $overlay 'enabled') -eq $false -and
        (Get-Prop $overlay 'running') -eq $false -and (Get-Prop $overlay 'streams') -eq 0 -and
        ($null -eq $open -or $open -eq 0) -and $null -eq (Get-Prop $preview 'current') -and
        (Get-Prop $preview 'state') -ne 'Open'
}
function Test-P2HostRace {
    $run = $null; $designer = $null; $result = [ordered]@{}; $offSent = $false
    try {
        $hostDelayBefore = [Environment]::GetEnvironmentVariable('NATIVUNE_TEST_OBS_DESIGNER_HOST_DELAY_MS', 'Process')
        try {
            $run = Start-OverlayRun 'A-DESIGNER-host-race' @{} 'PlayingLong' -NoReader -Override @{
                NATIVUNE_TEST_OBS_DESIGNER_HOST_DELAY_MS = '4000'
            }
        } finally {
            # Start-App writes overrides into the parent environment on non-elevated launches.
            [Environment]::SetEnvironmentVariable('NATIVUNE_TEST_OBS_DESIGNER_HOST_DELAY_MS',
                $(if ($null -eq $hostDelayBefore) { [NullString]::Value } else { $hostDelayBefore }), 'Process')
        }
        $designer = Open-P2Designer $run
        $result.duringCreate = Get-P2DesignerHook $run
        Close-P2Designer $designer; $designer = $null
        Start-Sleep -Seconds 5
        $result.closed = [ordered]@{ hook = Get-P2DesignerHook $run; server = Get-P2PreviewState $run }
        Add-Check 'A-DESIGNER.closeDuringCreation' 'close while delayed host is creating; no orphaned preview/stream/nonce' $result.closed (
            $result.duringCreate.state.state -ne 'Open' -and
            -not $result.closed.hook.open -and (Get-Prop $result.closed.server 'open') -eq 0 -and
            $null -eq (Get-Prop $result.closed.server 'current'))
        $designer = Open-P2Designer $run
        $result.offDuringCreate = Get-P2DesignerHook $run
        $offSent = $true
        Send-HookCommand $run.Root 'command-obs-off' | Out-Null
        Start-Sleep -Seconds 5
        $offSnapshot = Get-State $run.Root 'host-race-off'
        $result.afterOff = [ordered]@{ hook = Get-P2DesignerHook $run; snapshot = $offSnapshot
            server = Get-Overlay $offSnapshot 'previewNonces'; dialogs = @(Get-P2ModalTitles $designer) }
        $offNative = $result.afterOff.hook.state
        Add-Check 'A-DESIGNER.offDuringCreation' 'overlay Off after host delay: no server stream, Core, navigation, visibility or nonce; required Off dialog retained' $result.afterOff (
            $result.offDuringCreate.state.state -ne 'Open' -and
            (Test-P2StoppedOverlay $offSnapshot) -and $result.afterOff.hook.open -eq $true -and
            $null -ne $offNative -and $offNative.state -ceq 'Stopped' -and
            $null -eq $offNative.nonce -and $null -eq $result.afterOff.hook.previewUrl -and
            $offNative.navigated -eq $false -and $offNative.visible -eq $false -and $offNative.hostVisible -eq $false -and
            $null -ne $offNative.navigation -and @($offNative.navigation).Count -eq 0 -and
            # SnapshotForHook populates these settings only when a Core exists.
            $null -ne $offNative.settings -and $null -eq $offNative.settings.hostObjects -and
            $null -eq $offNative.settings.webMessages -and
            $offNative.dialogActive -eq $true -and $offNative.dialogTitle -ceq 'The overlay was turned off.' -and
            'The overlay was turned off.' -cin $result.afterOff.dialogs)
    } finally {
        try {
            if ($offSent -and $designer) {
                $result.cleanup = [ordered]@{ choice = 'Discard'; prompt = $null; closed = $null; afterDelay = $null; error = $null }
                try {
                    $prompt = Get-P2DesignerHook $run
                    if (-not $prompt.open -or $prompt.state.dialogActive -ne $true -or
                        $prompt.state.dialogTitle -cne 'The overlay was turned off.') {
                        throw 'Expected Off dialog is unavailable for explicit host-race cleanup.'
                    }
                    $result.cleanup.prompt = Invoke-P2DialogChoice $run 'The overlay was turned off.*' 'Discard'
                    $result.cleanup.closed = Wait-For {
                        $h = Get-P2DesignerHook $run
                        if ($h.open -eq $false -and
                            [ObsE2E]::Find([uint32] $run.App.Id, 'Overlay designer') -eq [IntPtr]::Zero) { $h }
                    } 12 150
                    if (-not $result.cleanup.closed) { throw 'Explicit Off/Discard did not close the designer.' }
                    Start-Sleep -Seconds 5
                    $lateSnapshot = Get-State $run.Root 'host-race-off-cleanup'
                    $result.cleanup.afterDelay = [ordered]@{ hook = Get-P2DesignerHook $run; snapshot = $lateSnapshot
                        hwnd = [ObsE2E]::Find([uint32] $run.App.Id, 'Overlay designer').ToInt64() }
                    Add-Check 'A-DESIGNER.offDuringCreationCleanup' 'explicit Off/Discard closes designer; no late host or server after another host delay' $result.cleanup (
                        (Test-P2StoppedOverlay $lateSnapshot) -and $result.cleanup.afterDelay.hook.open -eq $false -and
                        $null -eq $result.cleanup.afterDelay.hook.state -and
                        $null -eq $result.cleanup.afterDelay.hook.previewUrl -and $result.cleanup.afterDelay.hwnd -eq 0)
                } catch {
                    $result.cleanup.error = $_.Exception.Message
                    Add-Check 'A-DESIGNER.offDuringCreationCleanup' 'explicit Off/Discard resolves prompt and leaves no late host/server' $result.cleanup $false
                }
            } else { Close-P2Designer $designer -Cleanup }
        } finally {
            [void] (Save-P2Evidence 'designer-host-race' $result)
            if ($run) { Stop-OverlayRun $run }
        }
    }
}
function Test-P2PreviewRenewal {
    $run = $null; $designer = $null; $result = [ordered]@{}
    try {
        $run = Start-OverlayRun 'A-DESIGNER-renewal' @{} 'PlayingLong' -NoReader
        $designer = Open-P2Designer $run
        $initial = Wait-For {
            $p = Get-P2PreviewState $run
            if ($p.open -eq 1 -and $p.state -eq 'Open') { $p }
        } 15
        $result.initial = $initial
        $start = Get-Qpc
        # Production stream lifetime is five minutes. Observe its reconnect, not a shortened test-only timer.
        $remaining = 285 - (Get-Seconds $start (Get-Qpc))
        if ($remaining -gt 0) { Start-Sleep -Seconds ([int] [Math]::Ceiling($remaining)) }
        $samples = [Collections.Generic.List[object]]::new()
        while ((Get-Seconds $start (Get-Qpc)) -lt 330) {
            $p = Get-P2PreviewState $run
            $samples.Add([ordered]@{ elapsed = Round3 (Get-Seconds $start (Get-Qpc)); open = $p.open
                state = $p.state; nonce = $p.current })
            if (@($samples | Where-Object { $_.open -eq 0 -and $_.nonce -eq $initial.current }).Count -gt 0 -and
                $p.open -eq 1 -and $p.state -eq 'Open') { break }
            Start-Sleep -Milliseconds 100
        }
        $result.samples = $samples.ToArray(); $result.final = Get-P2PreviewState $run
        $result.designer = Get-P2DesignerHook $run
        Add-Check 'A-DESIGNER.renewal' 'at real five-minute stream lifetime preview reconnects once without closing editor or rotating nonce' $result (
            $initial -and $result.final.open -eq 1 -and $result.final.state -eq 'Open' -and
            $result.final.current -eq $initial.current -and $result.designer.open -and
            @($samples | Where-Object { $_.open -eq 0 -and $_.nonce -eq $initial.current }).Count -gt 0)
    } finally {
        [void] (Save-P2Evidence 'designer-renewal' $result)
        Close-P2Designer $designer -Cleanup; if ($run) { Stop-OverlayRun $run }
    }
}
function Test-P2ThreeWindows {
    $package = Join-Path $repo '.tools/better-lyrics/2.4.1.2'
    if (-not (Test-Path -LiteralPath (Join-Path $package 'manifest.json') -PathType Leaf)) {
        Add-Blocked 'A-DESIGNER.threeWindows' 'Settings + Designer + Lyrics settings from a disposable profile' "Pinned lyrics fixture missing at $package"
        return
    }
    $run = $null; $settingsWindow = $null; $designer = $null; $observation = [ordered]@{}
    try {
        $root = New-Root 'A-DESIGNER-three-windows'
        Write-Settings $root @{ ObsOverlay = $true }
        $dest = Join-Path $root '.tools/better-lyrics'
        [IO.Directory]::CreateDirectory($dest) | Out-Null
        Copy-Item -LiteralPath $package -Destination $dest -Recurse
        $configPath = Join-Path $root 'data/settings.json'
        $config = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
        $config | Add-Member -NotePropertyName BetterLyricsEnabled -NotePropertyValue $true
        [IO.File]::WriteAllText($configPath, (ConvertTo-Json -InputObject $config -Depth 8), [Text.UTF8Encoding]::new($false))
        $app = Start-App $root @{ NATIVUNE_TEST_DISCORD_BENCH_PROFILE = 'PlayingLong'; NATIVUNE_TEST_DISCORD_BENCH_STATE = 'Full' }
        $run = [pscustomobject]@{ Name = 'A-DESIGNER-three-windows'; Root = $root; App = $app; Reader = $null }
        [void] (Wait-BenchReady $root)
        $designer = Open-P2Designer $run -Settings
        $settingsWindow = $designer.Settings
        $lyricsNav = Find-Element $settingsWindow.Dlg 'AutomationId' 'LyricsNavItem' 5
        (Get-Pattern $lyricsNav ([System.Windows.Automation.SelectionItemPattern])).Select()
        $lyricsButton = Wait-For {
            $b = Find-Element $settingsWindow.Dlg 'AutomationId' 'OpenLyricsSettingsButton' 1
            if ($b -and $b.Current.IsEnabled) { $b }
        } 45
        if (-not $lyricsButton) {
            Add-Blocked 'A-DESIGNER.threeWindows' 'three independent native windows' 'Pinned Lyrics extension did not install/enable on the disposable profile.'
            return
        }
        Invoke-Element $lyricsButton
        $lyricsHwnd = Wait-For { $h = [ObsE2E]::Find([uint32] $app.Id, 'Lyric settings'); if ($h -ne [IntPtr]::Zero) { $h } } 30
        $observation.open = [ordered]@{ settings = $settingsWindow.Hwnd.ToInt64(); designer = $designer.Hwnd.ToInt64()
            lyrics = if ($lyricsHwnd) { $lyricsHwnd.ToInt64() } else { 0 }; preview = Get-P2DesignerHook $run
            screenshot = Save-WindowShot $designer.Hwnd 'designer-with-lyrics-settings' }
        Add-Check 'A-DESIGNER.threeWindows' 'three separate owned native windows; designer preview still navigated' $observation.open (
            $lyricsHwnd -and $lyricsHwnd -ne $designer.Hwnd -and $settingsWindow.Hwnd -ne $designer.Hwnd -and
            $observation.open.preview.state.navigated)
        Close-Settings $settingsWindow 'CancelButton'; $settingsWindow = $null
        $observation.afterSettingsClose = Get-P2DesignerHook $run
        Add-Check 'A-DESIGNER.settingsClose' 'designer survives Settings closure; Lyrics settings remains open' $observation.afterSettingsClose (
            $observation.afterSettingsClose.open -and [ObsE2E]::Find([uint32] $app.Id, 'Lyric settings') -ne [IntPtr]::Zero)
    } finally {
        [void] (Save-P2Evidence 'three-windows' $observation)
        Close-P2Designer $designer -Cleanup
        if ($settingsWindow) { try { Close-Settings $settingsWindow 'CancelButton' } catch { } }
        if ($run) { Stop-OverlayRun $run }
    }
}
function Test-P2KeyboardNumbers($Designer) {
    Add-Type -AssemblyName System.Windows.Forms
    $observed = [Collections.Generic.List[object]]::new()
    foreach ($spec in @(
        @{ field = 'Width'; slider = 'WidthSlider'; box = 'WidthBox'; initial = 400; arrow = 410; page = 460; home = 320; end = 800 },
        @{ field = 'Scale'; slider = 'ScaleSlider'; box = 'ScaleBox'; initial = 100; arrow = 105; page = 130; home = 50; end = 200 }
    )) {
        Set-P2Range $Designer $spec.slider $spec.initial
        foreach ($step in @(
            @{ from = $spec.slider; key = '{RIGHT}'; value = $spec.arrow; label = 'arrow' },
            @{ from = $spec.slider; key = '{PGUP}'; value = $spec.page; label = 'page' },
            @{ from = $spec.slider; key = '{HOME}'; value = $spec.home; label = 'home' },
            @{ from = $spec.slider; key = '{END}'; value = $spec.end; label = 'end' },
            @{ from = $spec.box; key = '{DOWN}'; value = $spec.end - $(if ($spec.field -eq 'Width') { 10 } else { 5 }); label = 'pairedNumberBoxArrow' }
        )) {
            Set-P2Focus $Designer $step.from
            [System.Windows.Forms.SendKeys]::SendWait($step.key)
            $actual = Wait-For {
                $state = (Get-P2DesignerHook $Designer.Run).state
                if ($state.options.($spec.field) -eq $step.value) { $state.options.($spec.field) }
            } 3 100
            $pair = Get-P2Text $Designer $spec.box
            $entry = [ordered]@{ field = $spec.field; key = $step.label; input = $step.from
                expected = $step.value; actual = $actual; pairedNumberBox = $pair; focus = Get-P2Focus }
            $observed.Add($entry)
            Add-Check "A-DESIGNER.keyboard.$($spec.field).$($step.label)" 'native key adjusts snapped option, paired numeric value remains synchronized' $entry (
                $null -ne $actual -and $actual -eq $step.value -and "$pair" -match "(?<!\d)$($step.value)(?!\d)")
        }
        $typed = if ($spec.field -eq 'Width') { '451' } else { '101' }
        $snapped = if ($spec.field -eq 'Width') { 450 } else { 100 }
        Set-P2Focus $Designer $spec.box
        $typedFocus = Get-P2Focus
        [System.Windows.Forms.SendKeys]::SendWait("^a$typed{TAB}")
        $typedValue = Wait-For {
            $state = (Get-P2DesignerHook $Designer.Run).state
            if ($state.options.($spec.field) -eq $snapped) { $state.options.($spec.field) }
        } 3 100
        $typedEntry = [ordered]@{ field = $spec.field; input = $spec.box; typed = $typed; expected = $snapped
            actual = $typedValue; pairedNumberBox = Get-P2Text $Designer $spec.box; focus = $typedFocus }
        $observed.Add($typedEntry)
        Add-Check "A-DESIGNER.keyboard.$($spec.field).typed" 'NumberBox typed value commits, snaps to option step and synchronizes slider' $typedEntry (
            $null -ne $typedValue -and $typedValue -eq $snapped -and
            [int] (Get-Pattern (Assert-P2Control $Designer $spec.slider) ([System.Windows.Automation.RangeValuePattern])).Current.Value -eq $snapped)
        Set-P2Range $Designer $spec.slider $spec.initial
    }
    $observed.ToArray()
}
function Test-P2EntryRows {
    $run = $null; $settings = $null; $designer = $null; $held = $null; $result = [ordered]@{}
    try {
        $run = Start-OverlayRun 'A-DESIGNER-entry' @{} 'PlayingLong' -NoReader
        $settings = Open-ObsSettings $run.App
        $button = Get-ObsControl $settings 'ObsDesignerButton'
        $result.on = $button.Current.IsEnabled
        Send-HookCommand $run.Root 'command-obs-off' | Out-Null
        $result.off = Wait-For { if (-not $button.Current.IsEnabled) { Get-State $run.Root 'entry-off' } } 10
        Send-HookCommand $run.Root 'command-obs-on' | Out-Null
        $result.back = Wait-For { if ($button.Current.IsEnabled) { Get-State $run.Root 'entry-on' } } 10
        Add-Check 'A-DESIGNER.entryAvailability' 'Settings designer button follows server on/off/on state' $result (
            $result.on -and $result.off -and -not $result.off.overlay.running -and
            $result.back -and $result.back.overlay.running)
        Invoke-Element $button
        $designer = Get-P2Designer $run
        $designer | Add-Member -NotePropertyName Settings -NotePropertyValue $settings
        $opened = Get-P2DesignerHook $run
        Add-Check 'A-DESIGNER.entrySettings' 'Settings button opens owned designer window' $opened $opened.open
        Close-P2Designer $designer; $designer = $null
        $settings = $null
        $main = $AE::FromHandle([ObsE2E]::Find([uint32] $run.App.Id, $null))
        $toolbar = Find-Element $main 'AutomationId' 'ObsButton' 5
        $toolbar.SetFocus()
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.SendKeys]::SendWait('+{F10}')
        $menu = Wait-For { Find-MenuItem $run.App.Id 'Overlay designer…' } 5
        if (-not $menu) { throw 'Toolbar OBS context menu did not expose Overlay designer…' }
        $result.toolbar = Describe $menu
        Invoke-Element $menu
        $designer = Get-P2Designer $run
        $designer | Add-Member -NotePropertyName Settings -NotePropertyValue $null
        $opened = Get-P2DesignerHook $run
        Close-P2Designer $designer
        $focus = Wait-P2Focus $run 'ObsButton' 5 'toolbar-return'
        $result.toolbarFocus = $focus
        Add-Check 'A-DESIGNER.entryToolbar' 'toolbar context item opens designer and returns focus to OBS button' $result (
            $result.toolbar -and $opened.open -and $focus -and -not (Get-P2DesignerHook $run).open)
        $designer = $null
    } finally {
        [void] (Save-P2Evidence 'designer-entry' $result)
        Close-P2Designer $designer -Cleanup
        if ($settings) { try { Close-Settings $settings 'CancelButton' } catch { } }
        if ($run) { Stop-OverlayRun $run }
    }
    $run = $null; $settings = $null
    try {
        $held = Hold-Prefix
        $run = Start-OverlayRun 'A-DESIGNER-bind-failure' @{} 'PlayingLong' -NoReader
        $settings = Open-ObsSettings $run.App
        $button = Get-ObsControl $settings 'ObsDesignerButton'
        $snapshot = Wait-For {
            $s = Get-State $run.Root 'designer-bind-failure'
            if ($s.overlay.bindResult -like '*PrefixInUse*') { $s }
        } 10
        $result.bind = [ordered]@{ running = $snapshot.overlay.running; bindResult = $snapshot.overlay.bindResult
            enabled = $button.Current.IsEnabled }
        Add-Check 'A-DESIGNER.bindFailure' 'held localhost prefix prevents designer entry in Settings' $result.bind (
            -not $snapshot.overlay.running -and -not $button.Current.IsEnabled -and
            $snapshot.overlay.bindResult -like '*PrefixInUse*')
    } finally {
        if ($settings) { try { Close-Settings $settings 'CancelButton' } catch { } }
        if ($run) { Stop-OverlayRun $run }
        if ($held) { Release-Prefix $held }
        [void] (Save-P2Evidence 'designer-entry-bind' $result)
    }
}
function Test-ADesigner {
    $run = $null; $designer = $null; $recorder = $null; $reader = $null; $evidence = [ordered]@{}
    try {
        $run = Start-OverlayRun 'A-DESIGNER' @{} 'PlayingLong' -NoReader
        $designer = Open-P2Designer $run -Settings
        $evidence.shot = Save-WindowShot $designer.Hwnd 'designer-initial'
        $evidence.tree = @($designer.El.FindAll($Scope::Descendants, [System.Windows.Automation.Condition]::TrueCondition) | ForEach-Object { Describe $_ })
        $evidence.focus = Get-P2Focus
        $expected = @('NewLookButton', 'DuplicateLookButton', 'RenameLookButton', 'DeleteLookButton', 'LookNameBox',
            'ThemePicker', 'FontPicker', 'ScaleSlider', 'ScaleBox', 'WidthSlider', 'WidthBox', 'AlignPicker', 'ColoursPicker',
            'TextShadowToggle', 'ShowArtistToggle', 'ShowProgressToggle', 'PausedPicker', 'ShowAnimationPicker',
            'HideAnimationPicker') + $script:p2FxTabOrder + @('CopyLinkButton', 'SaveLookButton', 'RevertChangesButton',
            'PreviewSongSourcePicker', 'PreviewStatePicker', 'PreviewBackgroundPicker', 'OverlayPreviewEntry')
        $controls = [ordered]@{}
        foreach ($id in $expected) {
            $el = Get-P2Control $designer $id; $controls[$id] = Describe $el
            Add-Check "A-DESIGNER.uia.$id" 'named, described UIA control' $controls[$id] (
                $el -and $el.Current.Name -and $el.Current.HelpText)
        }
        $evidence.controls = $controls
        Add-Check 'A-DESIGNER.initialFocus' 'New look on empty store' $evidence.focus ((Get-Prop $evidence.focus 'AutomationId') -ceq 'NewLookButton')
        $hidden = @('ShowArtToggle', 'ShowTimesToggle', 'TextHexBox', 'BackgroundHexBox', 'AccentHexBox') |
            Where-Object { $_ -in $evidence.tree.AutomationId }
        Add-Check 'A-DESIGNER.hiddenOptions' 'unsupported Pill options absent from UIA tree' $hidden (@($hidden).Count -eq 0)
        $size = (Assert-P2Control $designer 'SourceSizeText').Current.Name
        Add-Check 'A-DESIGNER.defaultSize' 'Set OBS source size to 440 by 96 pixels.' $size ($size -like '*440 by 96*')
        Add-Check 'A-DESIGNER.copyBeforeSave' 'no link to copy from unsaved new look' (Describe (Assert-P2Control $designer 'CopyLinkButton')) (
            -not (Assert-P2Control $designer 'CopyLinkButton').Current.IsEnabled)
        $tabOrder = @(Get-P2TabOrder $designer $expected)
        $forward = @(Get-P2TabTrace $designer 'NewLookButton' $tabOrder.Count)
        $reverse = @(Get-P2TabTrace $designer 'OverlayPreviewEntry' $tabOrder.Count $true)
        $evidence.tabs = [ordered]@{ expected = $tabOrder; forward = $forward; reverse = $reverse }
        Add-Check 'A-DESIGNER.tabOrder' 'actual Tab and Shift+Tab focus equal §5, numeric boxes included' $evidence.tabs (
            (@($forward | ForEach-Object { Get-Prop $_ 'AutomationId' }) -join ',') -ceq ($tabOrder -join ',') -and
            (@($reverse | ForEach-Object { Get-Prop $_ 'AutomationId' }) -join ',') -ceq ((@($tabOrder[($tabOrder.Count - 1)..0])) -join ','))
        $evidence.keyboardNumbers = Test-P2KeyboardNumbers $designer
        Add-Type -AssemblyName System.Windows.Forms
        (Assert-P2Control $designer 'OverlayPreviewEntry').SetFocus()
        [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
        $previewDocument = Wait-For { $d = Find-Element $designer.El 'Name' 'Overlay preview — sample song' 1; if ($d) { Describe $d } } 6
        [System.Windows.Forms.SendKeys]::SendWait('{TAB}')
        $cycled = Wait-P2Focus $run 'SavedLooksList' 4 'preview-cycle'
        [System.Windows.Forms.SendKeys]::SendWait('+{TAB}')
        $reverseCycle = Get-P2Focus
        [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
        [System.Windows.Forms.SendKeys]::SendWait('{ESC}')
        $escapeFocus = Get-P2Focus
        $evidence.focusCycle = [ordered]@{ document = $previewDocument; next = $cycled; previous = $reverseCycle; escape = $escapeFocus }
        Add-Check 'A-DESIGNER.previewFocusCycle' 'Enter document; Tab cycles to saved looks; reverse/Escape returns to preview entry' $evidence.focusCycle (
            $previewDocument -and $cycled -and (Get-Prop $reverseCycle 'AutomationId') -ceq 'OverlayPreviewEntry' -and
            (Get-Prop $escapeFocus 'AutomationId') -ceq 'OverlayPreviewEntry')
        $nonce = Wait-For { $n = Get-P2Nonce $run; if ($n -match '^[a-z0-9]{8}$') { $n } } 20
        $previewPage = Get-P2Http "/?look=draft&preview=1&pv=$nonce&sample=playing"
        $ids = @(Get-ProcessTree $run.App.Id $run.Root)
        $tree = @($ids | ForEach-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue } | Select-Object -Property Id, ProcessName)
        $previewHost = Wait-For {
            $h = Get-P2DesignerHook $run
            if ($h.state.navigated -and $h.state.state -eq 'Open') { $h }
        } 15
        $initialUrl = "${overlayUrl}?look=draft&preview=1&pv=$nonce&sample=playing"
        $navigation = @($previewHost.state.navigation | Where-Object {
            $_.kind -eq 'navigation' -and $_.allowed -eq $true -and $_.uri -ceq $initialUrl })
        $evidence.previewInitial = [ordered]@{ nonce = $nonce; status = $previewPage.status; tree = $tree
            host = $previewHost; expectedUrl = $initialUrl; matchedNavigation = $navigation }
        Add-Check 'A-DESIGNER.previewInitial' 'sample preview URL/nonce, safe host settings, WebView2 child and open stream' $evidence.previewInitial (
            $previewPage.status -eq 200 -and $previewHost -and $previewHost.state.nonce -eq $nonce -and
            $previewHost.state.settings.hostObjects -eq $false -and $previewHost.state.settings.webMessages -eq $false -and
            $navigation.Count -gt 0 -and @($tree | Where-Object { $_.ProcessName -eq 'msedgewebview2' }).Count -gt 0)
        if ($liveRecorderSupported) { $recorder = [ObsLiveRecorder]::new(); $recorder.Attach($designer.El) }
        else { Add-Blocked 'A-DESIGNER.liveRegions' 'record UIA LiveRegionChanged' "$liveRecorderError" }
        Select-P2Item $designer 'ThemePicker' 'Card'
        $card = Get-P2DesignerSnapshot $designer
        Add-Check 'A-DESIGNER.cardDefault' 'Card width 280; source 320 by 400' $card (
            "$($card.width)" -like '*280*' -and $card.size -like '*320 by 400*')
        Set-P2Range $designer 'ScaleSlider' 200
        $card200 = Get-P2DesignerSnapshot $designer
        Add-Check 'A-DESIGNER.card200' 'Card k=2 clamps width 400, source 440 by 600; announced' $card200 (
            "$($card200.width)" -like '*400*' -and $card200.size -like '*440 by 600*' -and $card200.size -like '*Width set to 400*')
        Select-P2Item $designer 'ThemePicker' 'Matte'
        Set-P2Range $designer 'ScaleSlider' 200
        $matte = Get-P2DesignerSnapshot $designer
        Add-Check 'A-DESIGNER.matte200' 'Matte k=2 width 720 announced' $matte (
            "$($matte.width)" -like '*720*' -and $matte.size -like '*Width set to 720*')
        if ($recorder) {
            $before = @($recorder.Snapshot()).Count
            for ($i = 1; $i -le 5; $i++) { Set-P2Range $designer 'ScaleSlider' (200 - 5 * $i) }
            Start-Sleep -Milliseconds 500
            $announcements = @($recorder.Snapshot() | Select-Object -Skip $before | Where-Object { $_ -like '*Set OBS source size*' })
            $evidence.sizeAnnouncements = $announcements
            Add-Check 'A-DESIGNER.sizeDebounce' 'one or two polite size announcements after five rapid slider edits' $announcements (
                $announcements.Count -gt 0 -and $announcements.Count -le 2)
        }
        Set-P2Range $designer 'ScaleSlider' 100
        Select-P2Item $designer 'ColoursPicker' 'Custom'
        $customControls = @('TextHexBox', 'ChooseTextColourButton', 'BackgroundHexBox', 'ChooseBackgroundColourButton',
            'OpacitySlider', 'OpacityBox', 'AccentHexBox', 'ChooseAccentColourButton')
        $customTree = @($designer.El.FindAll($Scope::Descendants, [System.Windows.Automation.Condition]::TrueCondition) | ForEach-Object { Describe $_ })
        Add-Check 'A-DESIGNER.customTabStops' 'custom Matte hex, picker and opacity paired controls visible and focusable' $customTree (
            @($customControls | Where-Object { $_ -notin $customTree.AutomationId }).Count -eq 0)
        $customExpected = @('NewLookButton', 'DuplicateLookButton', 'RenameLookButton', 'DeleteLookButton',
            'LookNameBox', 'ThemePicker', 'FontPicker', 'ScaleSlider', 'ScaleBox', 'WidthSlider', 'WidthBox',
            'AlignPicker', 'ColoursPicker', 'TextHexBox', 'ChooseTextColourButton',
            'BackgroundHexBox', 'ChooseBackgroundColourButton', 'OpacitySlider', 'OpacityBox',
            'AccentHexBox', 'ChooseAccentColourButton', 'TextShadowToggle', 'ShowArtToggle',
            'ShowArtistToggle', 'ShowProgressToggle', 'ShowTimesToggle', 'PausedPicker',
            'ShowAnimationPicker', 'HideAnimationPicker') +
            @($script:p2FxTabOrder | Where-Object { $_ -match '^(Played|Unplayed)Brightness' }) + @('CopyLinkButton', 'SaveLookButton',
            'RevertChangesButton', 'PreviewSongSourcePicker', 'PreviewStatePicker',
            'PreviewBackgroundPicker', 'OverlayPreviewEntry')
        $customExpected = @(Get-P2TabOrder $designer $customExpected)
        $customForward = @(Get-P2TabTrace $designer 'NewLookButton' $customExpected.Count)
        $customReverse = @(Get-P2TabTrace $designer 'OverlayPreviewEntry' $customExpected.Count $true)
        $evidence.customTabs = [ordered]@{ expected = $customExpected; forward = $customForward; reverse = $customReverse }
        Add-Check 'A-DESIGNER.customTabOrder' 'Matte Custom forward/reverse §5 stops, including colours and paired NumberBoxes' $evidence.customTabs (
            (@($customForward | ForEach-Object { Get-Prop $_ 'AutomationId' }) -join ',') -ceq ($customExpected -join ',') -and
            (@($customReverse | ForEach-Object { Get-Prop $_ 'AutomationId' }) -join ',') -ceq ((@($customExpected[($customExpected.Count - 1)..0])) -join ','))
        $hex = Assert-P2Control $designer 'TextHexBox'
        Set-P2Value $hex '#1E90FF'
        $validPreview = Wait-For { $s = Get-P2DesignerHook $run; if ((Get-Prop (Get-Prop (Get-Prop $s 'state') 'options') 'Text') -eq '#1e90ff') { $s } } 5
        Add-Check 'A-DESIGNER.hexValid' '#1E90FF normalized to a valid live draft colour' ([ordered]@{ input = Get-P2Value $hex; preview = $validPreview }) (
            (Get-P2Value $hex) -eq '#1E90FF' -and $validPreview)
        $looksPath = Join-Path $run.Root 'data/obs-looks.json'
        $beforeExists = Test-Path -LiteralPath $looksPath
        $beforeHash = Get-Sha256 $looksPath
        Set-P2Value $hex '1E90FF'
        # Invalid typing is an edit even though the last valid preview options are retained.
        $beforeInvalidSave = Get-P2DesignerHook $run
        Invoke-Element (Assert-P2Control $designer 'SaveLookButton')
        $hexPoll = @{ last = $null; errors = [Collections.Generic.List[string]]::new() }
        $accessibleError = Wait-For {
            try {
                $focused = $AE::FocusedElement
                $hexPoll.last = [ordered]@{ focus = Describe $focused; description = @(); field = $null; hasFocus = $false }
                $designer.El = $AE::FromHandle($designer.Hwnd)
                $freshHex = Get-P2Control $designer 'TextHexBox'
                if (-not $freshHex) { throw 'TextHexBox peer unavailable during validation.' }
                $hexPoll.last.field = Describe $freshHex
                $hexPoll.last.hasFocus = $freshHex.Current.HasKeyboardFocus -and
                    [System.Windows.Automation.Automation]::Compare($freshHex, $focused)
                if ($hexPoll.last.hasFocus) {
                    $hexPoll.last.description = @(Get-P2DescribedByNames $freshHex.GetRuntimeId())
                    $hexPoll.last.hasFocus = $freshHex.Current.HasKeyboardFocus -and
                        [System.Windows.Automation.Automation]::Compare($freshHex, $AE::FocusedElement)
                    if ($hexPoll.last.hasFocus -and
                        @($hexPoll.last.description | Where-Object { $_ -like '*#RRGGBB*' }).Count -gt 0) { $hexPoll.last }
                }
            } catch { $hexPoll.errors.Add($_.Exception.Message) }
        } 8 100
        $describedBy = Get-Prop $hexPoll.last 'description'
        $invalidPreview = Get-P2DesignerHook $run
        $afterExists = Test-Path -LiteralPath $looksPath
        $afterHash = Get-Sha256 $looksPath
        $fileUnchanged = $beforeExists -eq $afterExists -and
            (-not $beforeExists -or ($null -ne $beforeHash -and $beforeHash -ceq $afterHash))
        $evidence.invalidHex = [ordered]@{ focus = Get-Prop $hexPoll.last 'focus'; description = $describedBy; before = $beforeHash
            after = $afterHash; beforeExists = $beforeExists; afterExists = $afterExists; fileUnchanged = $fileUnchanged
            validOptions = $validPreview.state.options; beforeSave = $beforeInvalidSave.state
            preview = $invalidPreview; peer = $hexPoll.last; errors = $hexPoll.errors
            diagnostics = Save-P2DesignerDiagnostics $run 'invalid-hex-validation'; shot = Save-WindowShot $designer.Hwnd 'designer-invalid-hex' }
        Add-Check 'A-DESIGNER.invalidHex' 'Save leaves file and last valid preview unchanged; focuses box with #RRGGBB description' $evidence.invalidHex (
            $accessibleError -and $evidence.invalidHex.peer.hasFocus -and (Get-Prop $evidence.invalidHex.focus 'AutomationId') -ceq 'TextHexBox' -and
            @($describedBy | Where-Object { $_ -like '*#RRGGBB*' }).Count -gt 0 -and
            (Get-Prop (Get-Prop (Get-Prop $invalidPreview 'state') 'options') 'Text') -eq '#1e90ff' -and
            (ConvertTo-Json -InputObject $invalidPreview.state.options -Compress) -ceq
                (ConvertTo-Json -InputObject $validPreview.state.options -Compress) -and
            (ConvertTo-Json -InputObject $beforeInvalidSave.state.options -Compress) -ceq
                (ConvertTo-Json -InputObject $validPreview.state.options -Compress) -and
            $invalidPreview.state.draftRev -eq $beforeInvalidSave.state.draftRev -and
            $invalidPreview.state.lastSavedRev -eq $validPreview.state.lastSavedRev -and
            (Get-P2Value (Assert-P2Control $designer 'TextHexBox')) -ceq '1E90FF' -and
            $fileUnchanged)
        $hex = Assert-P2Control $designer 'TextHexBox'
        Set-P2Value $hex '#1E90FF'
        Invoke-Element (Assert-P2Control $designer 'ChooseTextColourButton')
        $colourPicker = Get-P2PopupControl $designer 'ColourPicker'
        $pickerHex = Get-P2PickerHex $designer
        Set-P2Value $pickerHex '#00AA00'
        $colourCancel = Get-P2PopupControl $designer 'ColourCancelButton'
        if (-not $colourCancel) { throw 'Native ColorPicker Cancel colour button missing.' }
        Invoke-Element $colourCancel
        $cancelFocus = Wait-P2Focus $run 'ChooseTextColourButton' 5 'colour-cancel'
        $evidence.flyout = [ordered]@{ picker = Describe $colourPicker; pickerHex = Describe $pickerHex
            colour = Get-P2Value $hex; focus = $cancelFocus; draft = Get-P2DesignerHook $run }
        Add-Check 'A-DESIGNER.flyoutCancel' 'mutated native colour then Cancel restores old value/draft and focus' $evidence.flyout (
            $colourPicker -and $cancelFocus -and $evidence.flyout.colour -eq '#1E90FF' -and
            $evidence.flyout.draft.state.options.Text -eq '#1e90ff')
        Invoke-Element (Assert-P2Control $designer 'ChooseTextColourButton')
        Set-P2Value (Get-P2PickerHex $designer) '#00AA00'
        $colourApply = Get-P2PopupControl $designer 'ColourApplyButton'
        if (-not $colourApply) { throw 'Native ColorPicker Apply colour button missing.' }
        Invoke-Element $colourApply
        $applied = Wait-For { $s = Get-P2DesignerHook $run; if ($s.state.options.Text -eq '#00aa00') { $s } } 5
        $applyFocus = Wait-P2Focus $run 'ChooseTextColourButton' 5 'colour-apply'
        $evidence.flyoutApply = [ordered]@{ colour = Get-P2Value $hex; focus = $applyFocus; draft = $applied }
        Add-Check 'A-DESIGNER.flyoutApply' 'mutated native picker Apply changes draft/preview and returns focus' $evidence.flyoutApply (
            $applied -and $applyFocus -and $evidence.flyoutApply.colour -eq '#00aa00')
        Invoke-Element (Assert-P2Control $designer 'ChooseTextColourButton')
        $escapePickerHex = Get-P2PickerHex $designer
        Set-P2Value $escapePickerHex '#FF0033'
        $escapePickerHex.SetFocus()
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.SendKeys]::SendWait('{ESC}')
        $escapeColourFocus = Wait-P2Focus $run 'ChooseTextColourButton' 5 'colour-escape'
        $evidence.flyoutEscape = [ordered]@{ colour = Get-P2Value $hex; focus = $escapeColourFocus; draft = Get-P2DesignerHook $run }
        Add-Check 'A-DESIGNER.flyoutEscape' 'mutated native picker Escape restores pre-flyout colour and focus' $evidence.flyoutEscape (
            $escapeColourFocus -and $evidence.flyoutEscape.colour -eq '#00aa00' -and
            $evidence.flyoutEscape.draft.state.options.Text -eq '#00aa00')
        $contrast = [ordered]@{}
        foreach ($case in @(
            @{ key = 'boundaryPass'; text = '#767676'; bg = '#ffffff'; warning = $false; ratio = '4.5:1' }
            @{ key = 'boundaryFail'; text = '#777777'; bg = '#ffffff'; warning = $true; ratio = '4.5:1' }
            @{ key = 'darkFail'; text = '#6a6a6a'; bg = '#1c1c1e'; warning = $true; ratio = $null }
            @{ key = 'darkPass'; text = '#a0a0a0'; bg = '#1c1c1e'; warning = $false; ratio = $null }
        )) {
            Set-P2Value $hex $case.text; Set-P2Value (Assert-P2Control $designer 'BackgroundHexBox') $case.bg
            $actual = (Assert-P2Control $designer 'ContrastText').Current.Name
            $contrast[$case.key] = [ordered]@{ text = $case.text; background = $case.bg; actual = $actual }
            Add-Check "A-DESIGNER.contrast.$($case.key)" 'correct unrounded warning and ratio' $contrast[$case.key] (
                "$actual" -like $(if ($case.warning) { '*below 4.5:1*' } else { '*Contrast*' }) -and
                (-not $case.ratio -or "$actual" -like "*$($case.ratio)*") -and
                ($case.warning -or "$actual" -notlike '*below 4.5:1*'))
        }
        $evidence.contrast = $contrast
        Set-P2Value $hex '#a0a0a0'
        Set-P2Value (Assert-P2Control $designer 'BackgroundHexBox') '#1c1c1e'
        Set-P2Value (Assert-P2Control $designer 'AccentHexBox') '#123abc'
        Set-Toggle (Assert-P2Control $designer 'TextShadowToggle') $true
        Set-Toggle (Assert-P2Control $designer 'TextShadowToggle') $false
        Select-P2Item $designer 'ColoursPicker' 'Automatic'
        Select-P2Item $designer 'ColoursPicker' 'Custom'
        $palette = [ordered]@{ text = Get-P2Value $hex; background = Get-P2Text $designer 'BackgroundHexBox'
            accent = Get-P2Text $designer 'AccentHexBox'; shadow = Get-ToggleState (Assert-P2Control $designer 'TextShadowToggle') }
        Select-P2Item $designer 'ThemePicker' 'Standard'
        $switchPalette = [ordered]@{ text = Get-P2Value $hex; background = Get-P2Text $designer 'BackgroundHexBox'
            accent = Get-P2Text $designer 'AccentHexBox'; shadow = Get-ToggleState (Assert-P2Control $designer 'TextShadowToggle') }
        $evidence.palette = [ordered]@{ roundTrip = $palette; switched = $switchPalette }
        Add-Check 'A-DESIGNER.palette' 'custom colours and explicit shadow survive auto/custom and theme switch' $evidence.palette (
            $palette.text -eq '#a0a0a0' -and $palette.accent -eq '#123abc' -and $palette.shadow -eq 'Off' -and
            ($palette | ConvertTo-Json -Compress) -ceq ($switchPalette | ConvertTo-Json -Compress))
        Set-P2Range $designer 'OpacitySlider' 60
        Select-P2Item $designer 'PausedPicker' 'Dim'
        $dependence = (Assert-P2Control $designer 'ContrastText').Current.Name
        Add-Check 'A-DESIGNER.contrastDependence' 'art/opacity and dim dependence described; never silently change chosen colours' $dependence (
            "$dependence" -like '*depend*' -and (Get-P2Text $designer 'TextHexBox') -eq '#a0a0a0')
        Select-P2Item $designer 'ThemePicker' 'Simple'
        $simple = (Assert-P2Control $designer 'ContrastText').Current.Name
        Select-P2Item $designer 'ThemePicker' 'Pill'
        $pill = (Assert-P2Control $designer 'ContrastText').Current.Name
        $evidence.contrastThemes = [ordered]@{ simple = $simple; pill = $pill }
        Add-Check 'A-DESIGNER.contrastThemes' 'Simple has no ratio; Pill names artwork dependence' $evidence.contrastThemes (
            "$simple" -like '*No background*' -and "$simple" -notmatch '\\d+(?:\\.\\d+)?:1' -and
            "$pill" -like '*Depends on the artwork*')
        Select-P2Item $designer 'ThemePicker' 'Matte'
        Set-P2Value $hex '#1E90FF'; Set-P2Value (Assert-P2Control $designer 'LookNameBox') 'Designer fixture'
        Invoke-Element (Assert-P2Control $designer 'SaveLookButton')
        $doc = Wait-For { $p = Read-ObsLooksFile $run.Root; if (@($p.looks).Count -eq 1) { $p } } 10
        $id = [string] $doc.looks[0].id
        $reader = Start-SseReader 'designer-saved' 20 "/events?look=$id&sample=playing"
        [void] (Wait-SseLook $reader { param($l) (Get-Prop $l 'id') -eq $id } 12)
        $copy = Assert-P2Control $designer 'CopyLinkButton'
        Invoke-Element $copy; Invoke-Element $copy
        $evidence.saved = [ordered]@{ id = $id; file = $doc; clip = Get-Clipboard -Raw
            events = if ($recorder) { @($recorder.Snapshot() | Where-Object { $_ -eq 'Link copied.' }) } else { @() } }
        Add-Check 'A-DESIGNER.saveCopy' 'new durable look, exact link, repeated Link copied live events' $evidence.saved (
            $id -match '^[a-z0-9]{8}$' -and $evidence.saved.clip -eq "${overlayUrl}?look=$id" -and $evidence.saved.events.Count -ge 2)
        Set-P2Range $designer 'WidthSlider' 450
        $saveStart = Get-Qpc
        Invoke-Element (Assert-P2Control $designer 'SaveLookButton')
        $live = Wait-SseLook $reader { param($l) (Get-Prop $l 'id') -eq $id -and (Get-Prop (Get-Prop $l 'options') 'width') -eq 450 } 3 $saveStart
        $evidence.liveSave = [ordered]@{ look = $live; elapsed = if ($live) { Round3 (Get-Seconds $saveStart $live.qpc) } else { $null }; result = Get-P2Result $designer }
        Add-Check 'A-DESIGNER.liveSave' 'committed width update delivered within one second and success result' $evidence.liveSave (
            $live -and (Get-Seconds $saveStart $live.qpc) -le 1 -and $evidence.liveSave.result -like '*Look saved*')
        $evidence.nonce = Test-P2NonceTimeline $designer 'A-DESIGNER.nonce' 12
        Stop-SseReader $reader; $reader = $null
        [void] (Wait-For { (Get-Overlay (Get-State $run.Root 'preview-alone') 'streams') -eq 1 } 12)
        Select-P2Item $designer 'PreviewSongSourcePicker' 'Current song'
        $currentStart = Wait-For { $s = Get-State $run.Root 'preview-current'; if ((Get-Overlay $s 'realStreams') -eq 1) { $s } } 10
        Start-Sleep -Seconds 3
        $currentEnd = Get-State $run.Root 'preview-current-end'
        $currentReads = Get-ReadStats $currentStart $currentEnd
        $evidence.currentSong = [ordered]@{ start = $currentStart.overlay; end = $currentEnd.overlay; reads = $currentReads
            title = @( $designer.El.FindAll($Scope::Descendants, [System.Windows.Automation.Condition]::TrueCondition) |
                Where-Object { $_.Current.Name -eq 'Overlay preview — current song' } | ForEach-Object { Describe $_ } ) }
        Add-Check 'A-DESIGNER.currentSong' 'current preview RealStreams=1, overlay read demand, document title updated' $evidence.currentSong (
            $currentStart -and (Get-Overlay $currentEnd 'realStreams') -eq 1 -and $currentReads.overlay -ge 1 -and $evidence.currentSong.title.Count -gt 0)
        Select-P2Item $designer 'PreviewSongSourcePicker' 'Sample song'
        foreach ($sampleState in @('Paused', 'No artwork')) {
            $priorNonce = Get-P2Nonce $run
            Select-P2Item $designer 'PreviewStatePicker' $sampleState
            $updatedNonce = Wait-For { $n = Get-P2Nonce $run; if ($n -and $n -ne $priorNonce) { $n } } 10
            Add-Check "A-DESIGNER.sample$($sampleState -replace ' ', '')" 'state change renews sample preview nonce with zero real streams' ([ordered]@{
                prior = $priorNonce; current = $updatedNonce; state = Get-P2PreviewState $run }) (
                $updatedNonce -and (Get-Overlay (Get-State $run.Root 'sample-state') 'realStreams') -eq 0)
        }
        $seven = [Collections.Generic.List[object]]::new()
        try {
            [void] (Wait-For { (Get-Overlay (Get-State $run.Root 'nonce-before-cap') 'streams') -eq 1 } 12)
            for ($i = 0; $i -lt 7; $i++) { $seven.Add((Open-RawStream -Path "/events?look=$id")) }
            $ninth = Open-RawStream -Path '/events'
            try {
                $evidence.capacity = [ordered]@{ seven = @($seven | ForEach-Object { $_.Status }); ninth = $ninth.Status; state = Get-P2PreviewState $run }
                Add-Check 'A-DESIGNER.capacity8' '7 OBS + preview admitted, 9th 503' $evidence.capacity (
                    @($seven | Where-Object { $_.Status -eq 200 }).Count -eq 7 -and $ninth.Status -eq 503)
            } finally { Close-RawStream $ninth }
            $evidence.sevenSwitches = Test-P2NonceTimeline $designer 'A-DESIGNER.sevenSources' 10
        } finally { foreach ($s in $seven) { Close-RawStream $s } }
        $closingNonce = Get-P2Nonce $run
        $settingsInvoker = $designer.Settings
        Send-ObsHookCommand $run.Root 'command-obs-designer-close' | Out-Null
        $closedDesigner = Wait-For {
            $s = Get-P2DesignerHook $run
            if (-not $s.open -and [ObsE2E]::Find([uint32] $run.App.Id, 'Overlay designer') -eq [IntPtr]::Zero) { $s }
        } 8
        if (-not $closedDesigner) { $evidence.settingsCloseTimeout = Save-P2DesignerDiagnostics $run 'settings-close-timeout' }
        $focusBack = Wait-P2Focus $run 'ObsDesignerButton' 5 'settings-return'
        Add-Check 'A-DESIGNER.focusReturnSettings' 'closing designer returns keyboard focus to Settings invoker' ([ordered]@{ state = $closedDesigner; focus = $focusBack }) (
            $closedDesigner -and (Get-Prop $focusBack 'AutomationId') -ceq 'ObsDesignerButton')
        Close-Settings $settingsInvoker 'CancelButton'
        $designer = $null
        $closed = Get-P2Http "/events?look=draft&pv=$closingNonce"
        $closedState = Get-P2PreviewState $run
        Add-Check 'A-DESIGNER.closeNonce' 'closed preview: old nonce 410 and open count zero' ([ordered]@{ status = $closed.status; state = $closedState }) (
            $closed.status -eq 410 -and (Get-Prop $closedState 'open') -eq 0)
        $eight = [Collections.Generic.List[object]]::new()
        try {
            [void] (Wait-For { (Get-Overlay (Get-State $run.Root 'closed-cap') 'streams') -eq 0 } 12)
            for ($i = 0; $i -lt 8; $i++) { $eight.Add((Open-RawStream -Path "/events?look=$id")) }
            $designer = Open-P2Designer $run
            $refused = Wait-For { $s = Get-P2PreviewState $run; if ((Get-Prop $s 'refused503') -eq $true) { $s } } 12
            $refusedText = (Assert-P2Control $designer 'DesignerPreviewStatus').Current.Name
            Set-P2Range $designer 'WidthSlider' 460
            $editable = (Get-P2DesignerHook $run).state.options.width
            $evidence.fullCapacity = [ordered]@{ streams = @($eight | ForEach-Object { $_.Status }); state = $refused
                text = $refusedText; editableWidth = $editable }
            Add-Check 'A-DESIGNER.previewRefused503' '8 OBS sources refuse preview without disabling edit/Save/Copy' $evidence.fullCapacity (
                @($eight | Where-Object { $_.Status -eq 200 }).Count -eq 8 -and $refused -and
                "$refusedText" -like "*8 sources are already connected*" -and $editable -eq 460 -and
                (Assert-P2Control $designer 'SaveLookButton').Current.IsEnabled -and
                (Assert-P2Control $designer 'CopyLinkButton').Current.IsEnabled)
            Close-RawStream $eight[$eight.Count - 1]; $eight.RemoveAt($eight.Count - 1)
            [void] (Wait-For { (Get-Overlay (Get-State $run.Root 'capacity-release') 'streams') -eq 7 } 12)
            Invoke-Element (Assert-P2Control $designer 'RetryPreviewButton')
            $recovered = Wait-For { $s = Get-P2PreviewState $run; if ((Get-Prop $s 'open') -eq 1) { $s } } 12
            Add-Check 'A-DESIGNER.previewRetry' 'Retry with one slot free admits preview as eighth source' $recovered (
                $recovered -and (Get-Overlay (Get-State $run.Root 'capacity-recovered') 'streams') -eq 8)
            # Revert the unsaved width edit without changing the persisted OBS look.
            Invoke-Element (Assert-P2Control $designer 'RevertChangesButton')
            [void] (Invoke-P2DialogChoice $run 'Discard changes*' 'Discard')
        } finally { foreach ($s in $eight) { Close-RawStream $s } }
        $newNonce = Get-P2Nonce $run
        $old = Get-P2Http "/events?look=draft&pv=$($evidence.nonce.first)"
        Add-Check 'A-DESIGNER.reopenNonce' 'old nonce stays 410 after reopen; new nonce differs' ([ordered]@{ status = $old.status; current = $newNonce }) (
            $old.status -eq 410 -and $newNonce -ne $evidence.nonce.first)
        $beforeCrash = Get-P2Nonce $run
        Send-ObsHookCommand $run.Root 'command-obs-designer-process-failed' | Out-Null
        $stopped = Wait-For {
            $s = Get-P2DesignerHook $run
            $server = Get-P2PreviewState $run
            if ((Get-Prop (Get-Prop $s 'state') 'state') -eq 'Stopped' -and
                (Get-Prop $server 'state') -eq 'Stopped') { [ordered]@{ designer = $s; server = $server } }
        } 10
        if (-not $stopped) { $evidence.crashTimeout = Save-P2DesignerDiagnostics $run 'process-failed-timeout' }
        $stopText = (Assert-P2Control $designer 'DesignerPreviewStatus').Current.Name
        Add-Check 'A-DESIGNER.processFailed' 'CDP Page.crash stops server preview immediately, detaches stream and leaves editor available' ([ordered]@{
            state = $stopped; text = $stopText; editable = (Assert-P2Control $designer 'SaveLookButton').Current.IsEnabled }) (
            $stopped -and $stopped.server.state -eq 'Stopped' -and $stopped.server.open -eq 0 -and
            "$stopText" -like '*preview stopped*' -and (Assert-P2Control $designer 'SaveLookButton').Current.IsEnabled)
        Select-P2Item $designer 'PreviewSongSourcePicker' 'Current song'
        Select-P2Item $designer 'PreviewSongSourcePicker' 'Sample song'
        Select-P2Item $designer 'PreviewStatePicker' 'Paused'
        Select-P2Item $designer 'PreviewStatePicker' 'Playing'
        $deferred = [ordered]@{ designer = Get-P2DesignerHook $run; server = Get-P2PreviewState $run }
        $evidence.crashDeferred = $deferred
        Add-Check 'A-DESIGNER.crashDeferred' 'song/state edits while renderer failed preserve stopped nonce and demand until explicit Retry' $deferred (
            $deferred.designer.state.nonce -eq $beforeCrash -and
            $deferred.designer.state.state -eq 'Stopped' -and
            $deferred.server.current -eq $beforeCrash -and
            $deferred.server.state -eq 'Stopped' -and $deferred.server.open -eq 0)
        Invoke-Element (Assert-P2Control $designer 'RetryPreviewButton')
        $afterCrash = Wait-For { $n = Get-P2Nonce $run; if ($n -ne $beforeCrash -and (Get-Prop (Get-P2PreviewState $run) 'open') -eq 1) { $n } } 20
        $retiredCrash = Get-P2Http "/events?look=draft&pv=$beforeCrash"
        Add-Check 'A-DESIGNER.processRetry' 'Retry creates new connected host/nonce; crashed one stays 410' ([ordered]@{
            before = $beforeCrash; after = $afterCrash; oldStatus = $retiredCrash.status }) (
            $afterCrash -and $retiredCrash.status -eq 410)
        Close-P2Designer $designer; $designer = $null
        $afterRetryClose = Wait-For {
            $h = Get-P2DesignerHook $run
            $s = Get-State $run.Root 'crash-retry-close'
            if (-not $h.open -and $s.overlay.previewNonces.open -eq 0 -and $s.overlay.streams -eq 0) {
                [ordered]@{ hook = $h; server = $s.overlay }
            }
        } 15
        $closedRetryNonce = Get-P2Http "/events?look=draft&pv=$afterCrash"
        $evidence.crashRetryClose = [ordered]@{ state = $afterRetryClose; retired = $closedRetryNonce.status }
        Add-Check 'A-DESIGNER.crashRetryClose' 'after actual crash and Retry, close removes host/stream/nonce immediately' $evidence.crashRetryClose (
            $afterRetryClose -and $afterRetryClose.server.previewNonces.open -eq 0 -and
            $null -eq $afterRetryClose.server.previewNonces.current -and $closedRetryNonce.status -eq 410)
        $designer = Open-P2Designer $run
        [void] (Wait-For { $s = Get-P2PreviewState $run; if ($s.open -eq 1) { $s } } 15)
        $popup = Assert-P2Control $designer 'PreviewBackgroundPicker'
        $beforePopup = Get-P2DesignerHook $run
        $beforePage = Wait-For {
            $s = Get-P2PreviewPageState $run
            if ($s.connection -eq 'open' -and $s.state -eq 'playing' -and
                $s.options.showProgress -eq $true -and $s.fillTimer -gt 0) { $s }
        } 15
        (Get-Pattern $popup ([System.Windows.Automation.ExpandCollapsePattern])).Expand()
        $duringPopup = Get-P2DesignerHook $run
        $duringPage = Get-P2PreviewPageState $run
        Start-Sleep -Milliseconds 2300
        $laterPage = Get-P2PreviewPageState $run
        $duringStreams = (Get-State $run.Root 'popup-streams').overlay
        (Get-Pattern $popup ([System.Windows.Automation.ExpandCollapsePattern])).Collapse()
        $afterPopup = Get-P2DesignerHook $run
        $afterPage = Get-P2PreviewPageState $run
        $evidence.popup = [ordered]@{ before = $beforePopup; beforePage = $beforePage
            during = $duringPopup; duringPage = $duringPage; laterPage = $laterPage
            after = $afterPopup; afterPage = $afterPage; server = $duringStreams }
        Add-Check 'A-DESIGNER.popupOverlap' 'popup hides only HWND; sample playing fill timer keeps ticking with open preview stream' $evidence.popup (
            $beforePopup.state.hostVisible -and $beforePage -and $beforePage.fillTimer -gt 0 -and
            -not $duringPopup.state.hostVisible -and $duringPage.fillTimer -gt 0 -and
            $laterPage.fillTimer -gt 0 -and $laterPage.counters.ticks -gt $duringPage.counters.ticks -and
            $duringStreams.previewNonces.open -eq 1 -and $duringStreams.streams -eq 1 -and
            $afterPopup.state.hostVisible -and $afterPage.fillTimer -gt 0)
        $resize = [ordered]@{}
        try {
            (Get-Pattern $designer.El ([System.Windows.Automation.TransformPattern])).Resize(1100, 700)
            foreach ($id in @('LookNameBox', 'ThemePicker', 'TextShadowToggle', 'SaveLookButton', 'OverlayPreviewEntry')) {
                $resize[$id] = Get-P2SettledControl $designer $id
            }
        } catch { $resize['error'] = $_.Exception.Message }
        $evidence.resize = $resize
        Add-Check 'A-DESIGNER.resize' '1100x700 window: each control settled, finite, nonempty and unclipped at its own scroll position' $resize (
            -not $resize.Contains('error') -and $resize.Count -eq 5 -and
            @($resize.Values | Where-Object { -not $_.settled -or $_.errors.Count -gt 0 -or
                -not $_.geometry.inside -or $_.geometry.offscreen }).Count -eq 0)
        Add-Type -AssemblyName System.Windows.Forms
        $monitor = [System.Windows.Forms.Screen]::FromHandle($designer.Hwnd)
        $evidence.dpiBaseline = [ordered]@{
            dpi = (Get-P2DesignerHook $run).state.dpi
            monitor = $monitor.DeviceName
            bounds = $monitor.Bounds.ToString()
            monitors = @([System.Windows.Forms.Screen]::AllScreens | ForEach-Object {
                [ordered]@{ name = $_.DeviceName; bounds = $_.Bounds.ToString() } })
            controls = $resize
            screenshot = Save-WindowShot $designer.Hwnd 'designer-dpi-baseline'
        }
        Add-Blocked 'A-DESIGNER.physicalDpi' 'move actual designer window across monitors with different DPI; compare hook dpi, UIA bounds and screenshots before/after' (
            "Only baseline recorded: $($evidence.dpiBaseline.monitor), DPI $($evidence.dpiBaseline.dpi). No operator-observed physical transition or after-state was supplied.")
        $cycles = [Collections.Generic.List[object]]::new()
        for ($cycle = 0; $cycle -lt 5; $cycle++) {
            $oldNonce = Get-P2Nonce $run
            Close-P2Designer $designer; $designer = $null
            $closedCycle = Get-P2DesignerHook $run
            $retired = Get-P2Http "/events?look=draft&pv=$oldNonce"
            $designer = Open-P2Designer $run
            $openedCycle = Wait-For { $s = Get-P2DesignerHook $run; if ($s.open -and $s.state.state -eq 'Open') { $s } } 15
            $cycles.Add([ordered]@{ index = $cycle; old = $oldNonce; retired = $retired.status; closed = $closedCycle
                opened = $openedCycle; counts = Get-P2PreviewState $run })
            Add-Check "A-DESIGNER.cycle$cycle" 'close/reopen frees stream and nonce; new preview only' $cycles[$cycle] (
                $closedCycle.open -eq $false -and $retired.status -eq 410 -and $openedCycle -and
                $openedCycle.state.nonce -ne $oldNonce -and (Get-Prop $cycles[$cycle].counts 'open') -eq 1)
        }
        $evidence.cycles = $cycles.ToArray()
        Add-Blocked 'A-DESIGNER.narrator' 'manual §5 utterances in operator transcript' 'Operator-recorded Narrator transcript for this exact run (focus, names, save, validation, errors, close) not supplied; UIA cannot prove speech.'
        $textScale = try { [int] (Get-ItemPropertyValue -Path 'HKCU:\Software\Microsoft\Accessibility' -Name TextScaleFactor -ErrorAction Stop) } catch { 100 }
        $highContrast = try { Add-Type -AssemblyName PresentationFramework; [bool] [System.Windows.SystemParameters]::HighContrast } catch { $false }
        $accessibility = [ordered]@{ textScale = $textScale; highContrast = $highContrast; controls = [ordered]@{} }
        foreach ($id in @('LookNameBox', 'ThemePicker', 'TextShadowToggle', 'SaveLookButton', 'OverlayPreviewEntry')) {
            $accessibility.controls[$id] = Get-P2SettledControl $designer $id
        }
        $evidence.accessibility = $accessibility
        if ($textScale -lt 200) {
            Add-Blocked 'A-DESIGNER.textScaling' '200% Windows text scaling with visible, reachable controls' "Current user scale is $textScale%; operator must set 200% before this run (harness will not change global Windows settings)."
        } else {
            Add-Check 'A-DESIGNER.textScaling' 'actual 200% text scale; all sampled editor controls in UIA tree and reachable' $accessibility (
                @($accessibility.controls.Values | Where-Object { -not $_.settled -or $_.errors.Count -gt 0 -or
                    -not $_.geometry.inside -or $_.geometry.offscreen -or -not $_.geometry.enabled }).Count -eq 0)
        }
        if (-not $highContrast) {
            Add-Blocked 'A-DESIGNER.highContrast' 'native Windows high contrast with visible, reachable controls' 'Windows high contrast is off; operator must enable it before this run (harness will not change global Windows settings).'
        } else {
            Add-Check 'A-DESIGNER.highContrast' 'native high contrast enabled; editor controls in UIA tree' $accessibility (
                @($accessibility.controls.Values | Where-Object { -not $_.settled -or $_.errors.Count -gt 0 -or
                    -not $_.geometry.inside -or $_.geometry.offscreen -or -not $_.geometry.enabled }).Count -eq 0)
        }
    } finally {
        if ($recorder) { $recorder.Detach() }
        Stop-SseReader $reader
        [void] (Save-P2Evidence 'designer' $evidence)
        Close-P2Designer $designer -Cleanup; if ($run) { Stop-OverlayRun $run }
        $scenarioResults['A-DESIGNER'] = $evidence
    }
    Test-P2LookFxDesigner
    Test-P2EntryRows
    Test-P2HostRace
    Test-P2ThreeWindows
    Test-P2DuplicateName
    Test-P2PreviewRenewal
}
