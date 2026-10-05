# Dot-sourced after the existing sampler helpers. No top-level side effects.
function Send-ObsBenchPayload($Ctx,[string]$Command,[string]$Payload) {
    Assert-DesignerDeadline
    [IO.File]::WriteAllText((Join-Path (Get-BenchDirectory $Ctx.Root) $Command),$Payload,[Text.UTF8Encoding]::new($false))
}
function Test-ObsBenchA($Ctx,$Snapshot) {
    if (-not $Snapshot -or (Get-Overlay $Snapshot 'streams') -ne 1) {return $false}
    if ($Designer) {
        $d=Get-Overlay $Snapshot 'designer'; $p=Get-Overlay $Snapshot 'previewNonces'
        $real=if ($script:designerCondition.kind -eq 'current') {1} else {0}
        if ($real -eq 1 -and ((Get-Overlay $Snapshot 'latestState') -ne 'playing' -or [int](Get-Overlay $Snapshot 'fixtureArtServed') -lt 1)) {return $false}
        return (Get-Prop $d 'open') -eq $true -and (Get-Prop $d 'visible') -eq $true -and (Get-Prop $d 'navigated') -eq $true -and
            (Get-Prop $p 'state') -eq 'Open' -and (Get-Prop $p 'open') -eq 1 -and (Get-Prop $p 'current') -eq (Get-Prop $d 'nonce') -and
            (Get-Overlay $Snapshot 'realStreams') -eq $real -and (Get-Overlay $Snapshot 'sampleStreams') -eq (1-$real) -and
            (Get-Prop (Get-Overlay $Snapshot 'lyrics') 'open') -eq $script:designerCondition.lyrics
    }
    if ((Get-Overlay $Snapshot 'realStreams') -ne 1 -or (Get-Overlay $Snapshot 'latestState') -ne $Ctx.Workload.ToLowerInvariant()) {return $false}
    if ($AppOnly) {return $true}
    $counts=Get-Overlay $Snapshot 'streamsByLook'
    (Get-Prop $counts $Ctx.LookId) -eq 1 -and [int](Get-Overlay $Snapshot 'fixtureArtServed') -ge 1
}
function Test-ObsBenchB($Snapshot) {
    if (-not $Snapshot -or (Get-Overlay $Snapshot 'streams') -ne 0 -or (Get-Overlay $Snapshot 'realStreams') -ne 0 -or
        (Get-Overlay $Snapshot 'demand') -ne 'None') {return $false}
    if ($Designer) {
        return (Get-Prop (Get-Overlay $Snapshot 'designer') 'open') -eq $false -and
            (Get-Prop (Get-Overlay $Snapshot 'lyrics') 'open') -eq $script:designerCondition.lyrics
    }
    $true
}
function Get-ObsOffShape($Ctx) {
    $all=Get-AllProcesses; $tree=@(Get-ObsTree $Ctx.ObsProcess.Id $all)
    $shape=@($tree | Where-Object pid -ne $Ctx.ObsProcess.Id | Group-Object name | Sort-Object Name | ForEach-Object {"$($_.Name):$($_.Count)"}) -join '|'
    $pids=@($tree.pid)
    $renderers=@($all | Where-Object {$_.ProcessId -in $pids -and $_.CommandLine -match '(?:^|\s)--type=renderer(?:\s|$)'}).Count
    "$shape|renderers:$renderers"
}

function Get-ObsRendererInventory($Ctx,$All=$null) {
    if ($null -eq $All) {$All=Get-AllProcesses}
    $tree=@(Get-ObsTree $Ctx.ObsProcess.Id $All);$byPid=@{}
    foreach ($p in $All) {$byPid[[int]$p.ProcessId]=$p}
    @($tree | Where-Object {$byPid[$_.pid].CommandLine -match '(?:^|\s)--type=renderer(?:\s|$)'} |
        ForEach-Object {@{pid=$_.pid;created=$_.created;key=$_.key;role='renderer'}})
}
function Get-ObsBenchUrlRole([string]$Url) {
    $uri=$null
    if ([Uri]::TryCreate($Url,[UriKind]::Absolute,[ref]$uri) -and $uri.Scheme -eq 'http' -and
        $uri.Host -eq 'localhost' -and $uri.Port -eq 47813) {'overlay'} else {'unowned'}
}
function Get-ObsBenchLookId([string]$Url) {
    if ((Get-ObsBenchUrlRole $Url) -ne 'overlay') {return $null}
    $query=([Uri]$Url).Query
    $match=[regex]::Match($query,'(?:^\?|&)look=([a-z0-9]{8})(?:&|$)')
    if ($match.Success) {$match.Groups[1].Value} else {$null}
}
function Get-ObsCefBaselineState($OwnedTree) {
    if (@($OwnedTree | Where-Object name -eq 'obs-browser-page.exe').Count) {'cef-processes-present'}
    else {'cef-not-started'}
}
function Get-ObsPreSceneAttribution($Ctx) {
    $tree=@(Get-ObsTree $Ctx.ObsProcess.Id)
    $Ctx.CefBaselinePending=$true
    $Ctx.Record['obsAttribution'].Add(@{phase='pre-scene';utc=[DateTime]::UtcNow.ToString('o')
        state=Get-ObsCefBaselineState $tree;complete=$true;cdpCertified=$false;processes=$tree
        basis='owned OS inventory only (cef-not-started means zero browser children); independent target/frame-empty certification deferred until first source activation'})
}
function Initialize-ObsLazyAttribution($Ctx) {
    # CEF may open seven/eight initially disabled pages. Every input must receive
    # a real show/hide, with all live pages mapped before hide; no exact-one demand
    # assumption is valid until the entire bootstrap has completed.
    $start=Get-Qpc;$requested=$Ctx.ActiveTheme
    $visits=[Collections.Generic.List[object]]::new();$Ctx.Record['bootstrapVisits']=$visits
    foreach ($theme in $allThemes) {
        if (-not (Test-TimeFits 0)) {throw 'Time box reached during CEF bootstrap.'}
        Assert-DesignerDeadline
        $Ctx.ActiveTheme=$theme;$Ctx.LookId=$Ctx.Items[$theme].lookId
        $showUtc=[DateTime]::UtcNow.ToString('o')
        Set-ObsOverlayEightSource $Ctx.Session $Ctx.Items $theme
        $ready=Wait-For {
            $s=Get-State $Ctx.Root 'cefbootstrapactive'
            if ((Get-Prop (Get-Overlay $s 'streamsByLook') $Ctx.LookId) -eq 1 -and
                (Get-Overlay $s 'latestState') -eq $Ctx.Workload.ToLowerInvariant() -and
                [int](Get-Overlay $s 'fixtureArtServed') -ge 1) {$s}
        } 15
        if (-not $ready) {throw "CEF bootstrap look $theme failed to connect."}
        $mapped=Wait-For {
            if (-not (Test-TimeFits 0)) {throw 'Time box reached during CEF bootstrap attribution.'}
            try {
                $row=Get-ObsAttribution $Ctx "bootstrap-active-$theme"
                if (@($row.frames | Where-Object {$_.role -eq 'overlay' -and $_.look -eq $Ctx.LookId}).Count) {$row}
            } catch {
                # Startup churn remains recorded, never certified; retry only
                # within this bounded setup interval before hiding any live page.
            }
        } 15
        if (-not $mapped) {throw "CEF bootstrap look $theme lacks complete page-bound attribution."}
        Set-ObsOverlayEightSource $Ctx.Session $Ctx.Items $null
        $visits.Add(@{theme=$theme;look=$Ctx.LookId;showUtc=$showUtc;hideUtc=[DateTime]::UtcNow.ToString('o');attributionPhase=$mapped.phase})
    }
    $Ctx.ItemEnabled=$false
    $zero=Wait-For {$s=Get-State $Ctx.Root 'cefbootstrapzero';if (Test-ObsBenchB $s) {$s}} 10
    if (-not $zero) {throw 'CEF bootstrap did not release all overlay demand.'}
    Wait-ObsOverlayTeardown $Ctx
    $off=Get-ObsAttribution $Ctx 'bootstrap-off'
    if (@($off.targets).Count -or @($off.frames).Count -or @($off.traceFrames).Count -or
        @($off.renderers | Where-Object {$Ctx.OverlayRenderers.ContainsKey($_.key)}).Count) {
        throw 'off retention: CEF bootstrap target/frame or mapped renderer survives.'
    }
    $Ctx.Record['bootstrap']=@{seconds=Round3 (Get-Seconds $start (Get-Qpc));allSourcesTransitioned=$visits.Count -eq 8;offAttributionPhase=$off.phase}
    $Ctx.CefBaselinePending=$false
    $Ctx.ActiveTheme=$requested;$Ctx.LookId=$Ctx.Items[$requested].lookId
    Set-ObsOverlayEightSource $Ctx.Session $Ctx.Items $requested
    if (-not (Wait-For {$s=Get-State $Ctx.Root 'cefstartupactive';if (Test-ObsBenchA $Ctx $s) {$s}} 15)) {
        throw 'Look failed to reactivate after all-eight CEF bootstrap.'
    }
    [void](Get-ObsAttribution $Ctx "bootstrap-restored-$requested")
    $Ctx.ItemEnabled=$true
}
function Get-ObsAttribution($Ctx,[string]$Phase,[switch]$BeforeScene) {
    $cdp=$null;$tracing=$false;$traceSession=''
    $row=@{phase=$Phase;utc=[DateTime]::UtcNow.ToString('o');complete=$false;targets=@();frames=@();traceFrames=@();renderers=@();lifecycle=@();traceScopes=[Collections.Generic.List[object]]::new()}
    $Ctx.Record['obsAttribution'].Add($row)
    $row['processes']=@(Get-ObsTree $Ctx.ObsProcess.Id)
    try {
        $before=@(Get-ObsRendererInventory $Ctx)
        $row['renderersBefore']=$before
        $cdp=Connect-ObsBenchCdp $Ctx.Obs
        $row['listener']=$Ctx.Obs.DebugListener
        $Ctx.Record['cdpListener']=$Ctx.Obs.DebugListener
        [void](Invoke-ObsBenchCdp $cdp 'Target.setDiscoverTargets' @{discover=$true})
        $processInfo=Invoke-ObsBenchCdp $cdp 'SystemInfo.getProcessInfo'
        $targetInfo=Invoke-ObsBenchCdp $cdp 'Target.getTargets'
        if ($targetInfo['targetInfos'] -isnot [array] -or $processInfo['processInfo'] -isnot [array]) {
            throw 'CDP target/process census schema unavailable; attribution BLOCKED.'
        }
        $targets=[Collections.Generic.List[object]]::new()
        $frames=[Collections.Generic.List[object]]::new()
        $row.targets=$targets;$row.frames=$frames
        $addFrames={
            param($Node,[string]$TargetId)
            $frame=$Node['frame'];$role=Get-ObsBenchUrlRole ([string]$frame['url'])
            if ($frame -isnot [Collections.IDictionary] -or -not $frame['id']) {throw 'CDP page frame census incomplete; attribution BLOCKED.'}
            $frames.Add(@{id=$frame['id'];target=$TargetId;role=$role;look=Get-ObsBenchLookId ([string]$frame['url']);url=$(if ($role -eq 'overlay') {'<overlay>'} else {'<unowned>'})})
            foreach ($child in @($Node['childFrames'])) {if ($child) {& $addFrames $child $TargetId}}
        }
        foreach ($target in @($targetInfo['targetInfos'])) {
            if (-not $target) {continue}
            $role=Get-ObsBenchUrlRole ([string]$target['url'])
            $targets.Add(@{id=$target['targetId'];type=$target['type'];role=$role;look=Get-ObsBenchLookId ([string]$target['url']);url=$(if ($role -eq 'overlay') {'<overlay>'} else {'<unowned>'})})
            if ($role -eq 'overlay') {$Ctx.OverlayTargets[[string]$target['targetId']]=$true}
            if ($target['type'] -ne 'page' -and $role -ne 'overlay') {continue}
            $attached=Invoke-ObsBenchCdp $cdp 'Target.attachToTarget' @{targetId=$target['targetId'];flatten=$true}
            try {
                $traceSession=[string]$attached.sessionId
                $offset=$cdp.Events.Count
                $scope=@{target=$target['targetId'];session=$traceSession;startedUtc=[DateTime]::UtcNow.ToString('o');drained=$false}
                $row.traceScopes.Add($scope)
                # Chromium 127 EmitFrameTree requires a WebContents: the owned
                # browser target intentionally emits an empty marker.
                [void](Invoke-ObsBenchCdp $cdp 'Tracing.start' @{categories='-*,disabled-by-default-devtools.timeline';transferMode='ReportEvents'} $traceSession)
                $tracing=$true
                $frameTree=Invoke-ObsBenchCdp $cdp 'Page.getFrameTree' @{} $traceSession
                & $addFrames $frameTree['frameTree'] ([string]$target['targetId'])
                [void](Invoke-ObsBenchCdp $cdp 'Tracing.end' @{} $traceSession);$tracing=$false
                $until=[DateTime]::UtcNow.AddSeconds(5)
                do {
                    [void](Invoke-ObsBenchCdp $cdp 'Browser.getVersion')
                    $complete=@($cdp.Events | Select-Object -Skip $offset | Where-Object {
                        $_['method'] -eq 'Tracing.tracingComplete' -and $_['sessionId'] -eq $traceSession
                    })
                    if ($complete.Count) {break}
                    Start-Sleep -Milliseconds 50
                } while ([DateTime]::UtcNow -lt $until)
                if (-not $complete.Count) {throw 'Page attribution trace did not drain before window.'}
                $scope.drained=$true;$scope['endedUtc']=[DateTime]::UtcNow.ToString('o')
            } finally {
                if ($tracing) {try {[void](Invoke-ObsBenchCdp $cdp 'Tracing.end' @{} $traceSession)} catch {}; $tracing=$false}
                [void](Invoke-ObsBenchCdp $cdp 'Target.detachFromTarget' @{sessionId=$attached.sessionId})
            }
        }
        $finalTargetInfo=Invoke-ObsBenchCdp $cdp 'Target.getTargets'
        $finalProcessInfo=Invoke-ObsBenchCdp $cdp 'SystemInfo.getProcessInfo'
        if ($finalProcessInfo['processInfo'] -isnot [array]) {throw 'CDP after-process census schema unavailable; attribution BLOCKED.'}
        if ($finalTargetInfo['targetInfos'] -isnot [array]) {throw 'CDP after-target census schema unavailable; attribution BLOCKED.'}
        $row['targetCensusBefore']=@($targetInfo['targetInfos'] | ForEach-Object {$_['targetId']})
        $row['targetCensusAfter']=@($finalTargetInfo['targetInfos'] | ForEach-Object {$_['targetId']})
        $after=@(Get-ObsRendererInventory $Ctx)
        $row.renderers=$after
        $identities=@{}
        foreach ($p in @($before)+@($after)) {
            if (-not $p.created -or ($identities.ContainsKey($p.pid) -and $identities[$p.pid].key -ne $p.key)) {
                throw 'Renderer birth identity missing or changed during attribution.'
            }
            $identities[$p.pid]=$p
        }
        $traceFrames=[Collections.Generic.List[object]]::new();$markerTargets=[Collections.Generic.HashSet[string]]::new()
        $row.traceFrames=$traceFrames
        foreach ($event in $cdp.Events) {
            if ($event['method'] -like 'Target.*') {
                $info=$event.params['targetInfo']
                $role=if ($info) {Get-ObsBenchUrlRole ([string]$info['url'])} else {'unknown'}
                $row.lifecycle+=@{event=$event.method;target=$(if ($info) {$info['targetId']} else {$event.params['targetId']});role=$role;observedUtc=[DateTime]::UtcNow.ToString('o')}
                $targetId=if ($info) {[string]$info['targetId']} else {[string]$event.params['targetId']}
                if (($event.method -eq 'Target.targetCreated' -and $targetId -notin $row.targetCensusBefore) -or
                    $event.method -eq 'Target.targetDestroyed') {
                    $row['censusChangedDuringCapture']=$true
                }
                if ($role -eq 'overlay') {$Ctx.OverlayTargets[[string]$info['targetId']]=$true}
            }
            if ($event['method'] -ne 'Tracing.dataCollected') {continue}
            foreach ($entry in @($event.params['value'])) {
                $argsData=$entry['args'];$data=if ($argsData) {$argsData['data']} else {$null}
                if ($entry['name'] -eq 'TracingStartedInBrowser') {
                    if ($data -isnot [Collections.IDictionary] -or -not $data.ContainsKey('frames')) {continue}
                    $scope=@($row.traceScopes | Where-Object session -eq $event['sessionId'])
                    if ($scope.Count -ne 1) {throw 'Frame inventory marker has ambiguous page scope.'}
                    [void]$markerTargets.Add([string]$scope[0].target)
                    $entries=@($data['frames'])
                } elseif ($entry['name'] -eq 'FrameCommittedInBrowser') {$entries=@($data)}
                else {continue}
                foreach ($frame in $entries) {
                    if (-not $frame) {continue}
                    $frameId=[string]$frame['frame'];$role=Get-ObsBenchUrlRole ([string]$frame['url'])
                    $osPid=[int]$frame['processId']
                    $identity=$identities[$osPid]
                    if ($role -eq 'overlay' -and -not $identity) {throw 'Overlay frame renderer PID@creation could not be mapped.'}
                    $look=Get-ObsBenchLookId ([string]$frame['url'])
                    $traceFrames.Add(@{id=$frameId;role=$role;look=$look;pid=$osPid;key=$(if ($identity) {$identity.key} else {$null});traceTimestamp=$entry['ts']})
                    if ($role -eq 'overlay') {$Ctx.OverlayRenderers[$identity.key]=@{pid=$osPid;created=$identity.created;role='renderer';owner='overlay';look=$look;phase=$Phase;utc=$row.utc}}
                }
            }
        }
        $row['census']=@{before=$row.targetCensusBefore;after=$row.targetCensusAfter
            tracedTargets=@($row.traceScopes | ForEach-Object target);markerTargets=@($markerTargets)
            changedDuringCapture=[bool]$row['censusChangedDuringCapture']}
        $censusReasons=@(Get-ObsTargetCensusReasons $row.census)
        if ($censusReasons.Count) {throw ($censusReasons -join '; ')}
        if ($Phase.StartsWith('active-') -and -not @($frames | Where-Object {$_.role -eq 'overlay' -and $_.look -eq $Ctx.LookId}).Count) {
            throw 'Enabled look missing from live target/frame inventory.'
        }
        foreach ($frame in $frames) {
            if ($frame.role -eq 'overlay' -and -not @($traceFrames | Where-Object {$_.id -eq $frame.id -and $_.role -eq 'overlay' -and $_.key}).Count) {
                throw 'Live overlay frame missing trace renderer attribution.'
            }
        }
        $row.targets=@($targets);$row.frames=@($frames);$row.traceFrames=@($traceFrames);$row.renderers=$after
        $row['cdpRenderersBefore']=@($processInfo['processInfo'] | Where-Object {$_['type'] -eq 'renderer'} | ForEach-Object {[int]$_['id']})
        $row['cdpRenderers']=@($finalProcessInfo['processInfo'] | Where-Object {$_['type'] -eq 'renderer'} | ForEach-Object {[int]$_['id']})
        if ($BeforeScene) {
            if ($targets.Count -or $frames.Count -or $traceFrames.Count) {
                if (@($targets | Where-Object role -eq overlay).Count -or @($frames | Where-Object role -eq overlay).Count -or
                    @($traceFrames | Where-Object role -eq overlay).Count) {
                    throw 'off retention: surviving overlay target/frame prevents infrastructure certification.'
                }
                throw 'Infrastructure inventory has unknown target/frame; attribution BLOCKED.'
            }
            foreach ($p in $after) {
                if ($Ctx.OverlayRenderers.ContainsKey($p.key)) {
                    throw 'off retention: previously overlay-mapped renderer cannot become startup infrastructure.'
                }
                if ($p.pid -notin $row.cdpRenderers) {throw 'Pre-scene renderer absent from independent CDP process inventory.'}
                $Ctx.InfrastructureRenderers[$p.key]=@{pid=$p.pid;created=$p.created;key=$p.key;slot=$p.key;generation=0;role='renderer';owner='independently inventoried targetless infrastructure';evidence=$Phase}
            }
        }
        $row.complete=$true
        # Only a positively consumed certified spare creates a replacement
        # candidate. Targetlessness/count coincidence alone never establishes it.
        if ($Phase.StartsWith('active-') -and $Ctx.RendererActivation -and -not @(Get-ObsRendererCensusReasons $row).Count) {
            $consumed=@($after | Where-Object {$Ctx.InfrastructureRenderers.ContainsKey($_.key) -and
                $Ctx.OverlayRenderers.ContainsKey($_.key) -and
                $_.key -in @($traceFrames | Where-Object role -eq overlay | ForEach-Object key)})
            $candidates=@($after | Where-Object {-not $Ctx.InfrastructureRenderers.ContainsKey($_.key) -and
                -not $Ctx.OverlayRenderers.ContainsKey($_.key) -and $_.key -notin $Ctx.RendererActivation.beforeKeys})
            if ($consumed.Count -eq 1 -and $candidates.Count -eq 1 -and -not $Ctx.RendererGenerations.ContainsKey($candidates[0].key)) {
                $old=$Ctx.InfrastructureRenderers[$consumed[0].key]
                $Ctx.RendererGenerations[$candidates[0].key]=@{consumed=$old;candidate=$candidates[0]
                    mapping=@{key=$consumed[0].key;overlay=$Ctx.OverlayRenderers[$consumed[0].key];phase=$Phase}
                    active=$row;activationStartUtc=$Ctx.RendererActivation.startUtc
                    activationEndUtc=[DateTime]::UtcNow.ToString('o');beforeKeys=$Ctx.RendererActivation.beforeKeys}
            }
        }
        $row
    } catch {
        $row['error']=$_.Exception.Message
        $row['listenerDiagnostics']=$Ctx.Obs.DebugDiagnostics
        $row.targets=@($row.targets);$row.frames=@($row.frames);$row.traceFrames=@($row.traceFrames)
        throw
    }
    finally {
        if ($tracing -and $cdp) {try {[void](Invoke-ObsBenchCdp $cdp 'Tracing.end' @{} $traceSession)} catch {}}
        Close-ObsBenchCdp $cdp
    }
}
function Get-ObsCertifiedOff($Ctx,$Snapshot,[string]$Phase) {
    $attribution=Get-ObsAttribution $Ctx $Phase
    $items=@((Invoke-ObsRequest $Ctx.Session 'GetSceneItemList' @{sceneName=$script:ObsPortableSceneName}).sceneItems)
    $ids=@($Ctx.Items.Values | ForEach-Object itemId)
    $off=$items.Count -eq 8 -and @($items | Where-Object {$_.sceneItemId -notin $ids -or $_.sceneItemEnabled -ne $false}).Count -eq 0
    $evidence=@{complete=$attribution.complete;itemsOff=$off;streams=Get-Overlay $Snapshot 'streams'
        realStreams=Get-Overlay $Snapshot 'realStreams';demand=Get-Overlay $Snapshot 'demand'
        overlayTargets=@($attribution.targets | Where-Object {$_.role -eq 'overlay' -or $Ctx.OverlayTargets.ContainsKey($_.id)})
        overlayFrames=@($attribution.frames | Where-Object role -eq overlay)+@($attribution.traceFrames | Where-Object role -eq overlay)
        mappedSurvivors=@($attribution.renderers | Where-Object {$Ctx.OverlayRenderers.ContainsKey($_.key)})
        infrastructureRenderers=@($attribution.renderers | Where-Object {$Ctx.InfrastructureRenderers.ContainsKey($_.key)} | ForEach-Object {$Ctx.InfrastructureRenderers[$_.key]})
        unknownRenderers=@($attribution.renderers | Where-Object {-not $Ctx.OverlayRenderers.ContainsKey($_.key) -and -not $Ctx.InfrastructureRenderers.ContainsKey($_.key)})
        unknownTargets=@($attribution.targets | Where-Object {$_.role -ne 'overlay' -and -not $Ctx.OverlayTargets.ContainsKey($_.id)})
        unknownFrames=@($attribution.frames | Where-Object role -ne overlay)+@($attribution.traceFrames | Where-Object role -ne overlay)
        shape=Get-ObsOffShape $Ctx;attributionPhase=$Phase}
    $evidence['expectedShape']=if ($Ctx.Shape0) {$Ctx.Shape0} else {$evidence.shape}
    # Promote a recorded slot generation only at an otherwise valid off state.
    # The mapped registry always wins over former infrastructure membership.
    $guard=$evidence.Clone();$guard.unknownRenderers=@()
    if ($Ctx.Shape0 -and -not @(Get-ObsOffCertificationReasons $guard).Count) {
        foreach ($p in @($evidence.unknownRenderers)) {
            $generation=$Ctx.RendererGenerations[$p.key]
            $reasons=@(Get-ObsRendererGenerationReasons $generation $attribution @($Ctx.OverlayRenderers.Keys) $Ctx.InfrastructureSlotCount)
            if ($reasons.Count) {continue}
            $old=$generation.consumed
            $certificate=@{pid=$p.pid;created=$p.created;key=$p.key;slot=$old.slot;generation=([int]$old.generation+1)
                role='renderer';owner='certified consumed-spare replacement';evidence=$generation;certifiedOffPhase=$Phase
                consumedExitObservedUtc=[DateTime]::UtcNow.ToString('o')}
            $Ctx.InfrastructureRenderers[$p.key]=$certificate
            $Ctx.Record['rendererGenerations'].Add($certificate)
        }
        $evidence.infrastructureRenderers=@($attribution.renderers | Where-Object {-not $Ctx.OverlayRenderers.ContainsKey($_.key) -and $Ctx.InfrastructureRenderers.ContainsKey($_.key)} |
            ForEach-Object {$Ctx.InfrastructureRenderers[$_.key]})
        $evidence.unknownRenderers=@($attribution.renderers | Where-Object {-not $Ctx.OverlayRenderers.ContainsKey($_.key) -and -not $Ctx.InfrastructureRenderers.ContainsKey($_.key)})
    }
    $evidence['reasons']=@(Get-ObsOffCertificationReasons $evidence)
    $evidence['certified']=$evidence.reasons.Count -eq 0
    $evidence
}
function Wait-ObsOverlayTeardown($Ctx) {
    $deadline=(Get-Qpc)+10*$freq
    $cdp=Connect-ObsBenchCdp $Ctx.Obs
    try {
        do {
            $renderers=@(Get-ObsRendererInventory $Ctx | Where-Object {$Ctx.OverlayRenderers.ContainsKey($_.key)})
            $inventory=Invoke-ObsBenchCdp $cdp 'Target.getTargets'
            $targets=@($inventory['targetInfos'] | Where-Object {(Get-ObsBenchUrlRole ([string]$_['url'])) -eq 'overlay' -or $Ctx.OverlayTargets.ContainsKey([string]$_['targetId'])})
            if (-not $renderers.Count -and -not $targets.Count) {return}
            Start-Sleep -Milliseconds 250
        } while ((Get-Qpc) -lt $deadline)
        # Do not kill or forgive survivors; the next certified-off check records
        # identities and invalidates this arm using the unchanged retry policy.
    } finally {Close-ObsBenchCdp $cdp}
}

function Get-DesignerProcessInventory($Ctx) {
    $all=Get-AllProcesses;$entries=@(Get-AppTree $Ctx.App.Id $Ctx.Root $all);$roles=@{}
    Add-ProcessRoles $roles $entries $all
    @($entries | ForEach-Object {@{pid=$_.pid;created=$_.created;key=$_.key;name=$_.name;role=$roles[$_.key].label}})
}
function Wait-DesignerPreviewTeardown($Ctx) {
    if (-not $Ctx.PreviewCandidates.Count) {return}
    $deadline=(Get-Qpc)+10*$freq
    do {
        Assert-DesignerDeadline
        $live=@(Get-DesignerProcessInventory $Ctx)
        $remaining=@($Ctx.PreviewCandidates | Where-Object {$_.key -in @($live.key)})
        if (-not $remaining.Count) {
            $Ctx.Record['designerLifecycle'].Add(@{event='teardown-confirmed';utc=[DateTime]::UtcNow.ToString('o');qpc=Get-Qpc
                processes=@($Ctx.PreviewCandidates | ForEach-Object {@{pid=$_.pid;created=$_.created;key=$_.key;role=$_.role
                    owner=$(if ($_.key -in $Ctx.PreviewCloseKeys) {'designer preview transition'} else {'unknown: exited before close; never exempt'})}})})
            $Ctx.PreviewCandidates=@();return
        }
        Start-Sleep -Milliseconds 250
    } while ((Get-Qpc) -lt $deadline)
    $Ctx.Record['designerLifecycle'].Add(@{event='teardown-timeout';utc=[DateTime]::UtcNow.ToString('o');processes=$remaining})
    throw 'Prior preview renderer teardown not confirmed within 10s. Ownership seam needed if shared: hook CoreWebView2Environment.GetProcessInfos and preview AssociatedRenderFrameInfos.'
}
# Trace all starts/stops during a window, including descendants born and gone between 1-second samples.
# Source identifiers are private to this arm; teardown occurs before switching pages.
function Start-ObsArmTrace($Ctx) {
    $prefix='obs-arm-'+[guid]::NewGuid().ToString('N')
    $all=Get-AllProcesses
    $initial=@(Get-AppTree $Ctx.App.Id $Ctx.Root $all)
    if (-not $AppOnly) {$initial+=@(Get-ObsTree $Ctx.ObsProcess.Id $all)}
    $ids=[Collections.Generic.HashSet[int]]::new();foreach ($p in $initial) {[void]$ids.Add($p.pid)}
    $identities=@{};$roles=@{};Add-ProcessRoles $roles $initial $all
    foreach ($p in $initial) {$identities[$p.pid]=@{pid=$p.pid;key=$p.key;created=$p.created;role=$roles[$p.key].label;owner=$(if ($Designer -and $p.key -in @($Ctx.PreviewCandidates | ForEach-Object key)) {'designer preview candidate'} else {'owned tree; preview ownership unknown/shared'})}}
    $observed=@{};foreach ($identity in $identities.Values) {$observed[$identity.key]=$identity}
    try {
        [void](Register-CimIndicationEvent -Query 'SELECT * FROM Win32_ProcessStartTrace' -SourceIdentifier "$prefix-start")
        [void](Register-CimIndicationEvent -Query 'SELECT * FROM Win32_ProcessStopTrace' -SourceIdentifier "$prefix-stop")
    } catch {
        foreach ($suffix in @('start','stop')) {Unregister-Event -SourceIdentifier "$prefix-$suffix" -ErrorAction SilentlyContinue}
        throw 'Arm blocked: full-tree process start/stop tracing unavailable.'
    }
    $log=Join-Path $Ctx.Root 'data/nativune.log'
    $failures=if (Test-Path $log) {@(Select-String -LiteralPath $log -Pattern 'process-failed').Count} else {0}
    @{prefix=$prefix;ids=$ids;identities=$identities;observed=$observed;initial=$initial;startQpc=(Get-Qpc);startUtc=[DateTime]::UtcNow;measureStartUtc=$null;failureCountBefore=$failures}
}
function Stop-ObsArmTrace($Trace,[datetime]$EndUtc=[DateTime]::UtcNow) {
    $exits=[Collections.Generic.List[object]]::new()
    $active=$Trace.identities.Clone()
    try {
        Start-Sleep -Milliseconds 250
        $events=@(Get-Event | Where-Object {$_.SourceIdentifier -like "$($Trace.prefix)-*"} | Sort-Object { [long]$_.SourceEventArgs.NewEvent.TIME_CREATED })
        foreach ($traceEvent in $events) {
            $e=$traceEvent.SourceEventArgs.NewEvent
            $time=[DateTime]::FromFileTimeUtc([long]$e.TIME_CREATED)
            if ($time -lt $Trace.startUtc -or $time -gt $endUtc) {continue}
            if ($traceEvent.SourceIdentifier -eq "$($Trace.prefix)-start") {
                if ($Trace.ids.Contains([int]$e.ParentProcessID)) {
                    [void]$Trace.ids.Add([int]$e.ProcessID)
                    $matches=@($Trace.observed.Values | Where-Object {$_.pid -eq [int]$e.ProcessID -and $_.created -and
                        [Math]::Abs(($time-[datetime]$_.created).TotalSeconds) -lt 1})
                    $active[[int]$e.ProcessID]=if ($matches.Count -eq 1) {$matches[0]} else {
                        @{pid=[int]$e.ProcessID;key=$null;created=$null;traceBirthUtc=$time.ToString('o')
                            role='unknown (trace-only birth)';owner='owned descendant; preview ownership unknown'}
                    }
                }
            } elseif ($Trace.ids.Contains([int]$e.ProcessID)) {
                $identity=$active[[int]$e.ProcessID]
                $exits.Add(@{pid=[int]$e.ProcessID;name=[string]$e.ProcessName;time=$time.ToString('o');identity=$identity
                    phase=$(if ($Trace.measureStartUtc -and $time -ge $Trace.measureStartUtc) {'measurement'} else {'settle'})})
                $active.Remove([int]$e.ProcessID)
            }
        }
        @($exits)
    } finally {
        foreach ($suffix in @('start','stop')) {
            Unregister-Event -SourceIdentifier "$($Trace.prefix)-$suffix" -ErrorAction SilentlyContinue
            Get-Event -SourceIdentifier "$($Trace.prefix)-$suffix" -ErrorAction SilentlyContinue | Remove-Event -ErrorAction SilentlyContinue
        }
    }
}
function Start-DesignerPreview($Ctx) {
    Assert-DesignerDeadline 60
    Wait-DesignerPreviewTeardown $Ctx
    $Ctx.PreviewBefore=@(Get-DesignerProcessInventory $Ctx)
    $Ctx.PreviewOpenUtc=[DateTime]::UtcNow
    $Ctx.Record['designerLifecycle'].Add(@{event='pre-open';utc=$Ctx.PreviewOpenUtc.ToString('o');qpc=Get-Qpc;processes=$Ctx.PreviewBefore})
    Send-HookCommand $Ctx.Root 'command-obs-designer-open'
    $open=Wait-For {
        $s=Get-State $Ctx.Root 'designeropen'; $d=Get-Overlay $s 'designer'
        if ((Get-Prop $d 'open') -eq $true -and (Get-Prop $d 'visible') -eq $true -and (Get-Prop $d 'navigated') -eq $true -and (Get-Prop (Get-Overlay $s 'previewNonces') 'state') -eq 'Open') {$s}
    } 40
    if (-not $open) {throw 'Designer did not open.'}
    $Ctx.Reader=$true
    $Ctx.Record['designerLifecycle'].Add(@{event='open-hook';utc=[DateTime]::UtcNow.ToString('o');qpc=$open.qpc;designer=Get-Overlay $open 'designer';processes=Get-DesignerProcessInventory $Ctx})
    $options=if ($script:designerCondition.worst) {$worstData.worst.options} else {New-ObsBenchOptions 'pill'}
    $nonce=Get-Prop (Get-Overlay $open 'designer') 'nonce'
    Send-ObsBenchPayload $Ctx 'command-obs-draft-look' (@{look=@{id='draft';name='Bench draft';options=$options};backdrop='checker'} | ConvertTo-Json -Depth 8 -Compress)
    if (-not (Wait-For {-not (Test-Path -LiteralPath (Join-Path (Get-BenchDirectory $Ctx.Root) 'command-obs-draft-look'))} 10)) {throw 'Worst draft command was not consumed.'}
    $url="http://localhost:47813/?look=draft&preview=1&pv=$nonce"
    if ($script:designerCondition.kind -ne 'current') {$url+='&sample='+$script:designerCondition.sample}
    Send-ObsBenchPayload $Ctx 'command-obs-designer-navigate' $url
    $Ctx.Reader=$true
    if (-not (Wait-For {
        if (Test-Path -LiteralPath (Join-Path (Get-BenchDirectory $Ctx.Root) 'command-obs-designer-navigate')) {return $false}
        $s=Get-State $Ctx.Root 'designernavigated'
        $decisions=@(Get-Prop (Get-Overlay $s 'designer') 'navigation')
        if ((Test-ObsBenchA $Ctx $s) -and @($decisions | Where-Object {
            (Get-Prop $_ 'kind') -eq 'navigation' -and (Get-Prop $_ 'uri') -eq $url -and (Get-Prop $_ 'allowed') -eq $true
        }).Count) {$s}
    } 20)) {throw 'Designer navigation/readiness not acknowledged before protected window.'}
    if ($script:designerCalibration) {
        if (-not (Wait-For {$s=Get-State $Ctx.Root 'calibrationready';if (Test-ObsBenchA $Ctx $s) {$s}} 20)) {throw 'Calibration preview did not become ready.'}
        $ack=Set-DesignerCalibrationLoad $Ctx $script:designerCalibration
        $Ctx.Record['calibrationStart']=$ack
    }
    $inventory=@(Get-DesignerProcessInventory $Ctx)
    $beforeKeys=@($Ctx.PreviewBefore | ForEach-Object key)
    $Ctx.PreviewBirths=@($inventory | Where-Object {$_.key -notin $beforeKeys -and
        $_.created -and [datetime]$_.created -ge $Ctx.PreviewOpenUtc})
    $Ctx.PreviewCandidates=@($Ctx.PreviewBirths | Where-Object role -eq renderer)
    $Ctx.Record['designerLifecycle'].Add(@{event='navigated';utc=[DateTime]::UtcNow.ToString('o');qpc=Get-Qpc
        processes=$inventory;previewCandidates=$Ctx.PreviewCandidates;ownershipBasis='birth after open, absent pre-open; confirmed only after close/exit'})
}
function Stop-DesignerPreview($Ctx) {
    Assert-DesignerDeadline
    try {
        if ($script:designerCalibration) {
            $Ctx.Record['calibrationOff']=Set-DesignerCalibrationLoad $Ctx @{off=$true}
        }
    } finally {
        $inventory=@(Get-DesignerProcessInventory $Ctx)
        $Ctx.PreviewCloseKeys=@($inventory | ForEach-Object key)
        $beforeKeys=@($Ctx.PreviewBefore | ForEach-Object key)
        $newBirths=@($inventory | Where-Object {$_.key -notin $beforeKeys -and
            $_.created -and [datetime]$_.created -ge $Ctx.PreviewOpenUtc})
        $Ctx.PreviewBirths=@(@($Ctx.PreviewBirths)+$newBirths | Sort-Object key -Unique)
        $Ctx.PreviewCandidates=@(@($Ctx.PreviewCandidates)+@($Ctx.PreviewBirths | Where-Object role -eq renderer) | Sort-Object key -Unique)
        $Ctx.Record['designerLifecycle'].Add(@{event='pre-close';utc=[DateTime]::UtcNow.ToString('o');qpc=Get-Qpc;processes=$inventory;previewCandidates=$Ctx.PreviewCandidates})
        Send-HookCommand $Ctx.Root 'command-obs-designer-close'
        $closed=Wait-For {$s=Get-State $Ctx.Root 'designerclosed'; if (Test-ObsBenchB $s) {$s}} 20
        if (-not $closed) {throw 'Designer close did not release the preview stream.'}
        $Ctx.Reader=$null
        $Ctx.Record['designerLifecycle'].Add(@{event='closed-hook';utc=[DateTime]::UtcNow.ToString('o');qpc=$closed.qpc;designer=Get-Overlay $closed 'designer';processes=Get-DesignerProcessInventory $Ctx})
        Wait-DesignerPreviewTeardown $Ctx
        $post=@(Get-DesignerProcessInventory $Ctx);$postKeys=@($post | ForEach-Object key)
        $ownership=@($Ctx.PreviewBirths | ForEach-Object {
            @{pid=$_.pid;created=$_.created;key=$_.key;role=$_.role
                owner=$(if ($_.key -notin $postKeys -and $_.key -in $Ctx.PreviewCloseKeys) {'designer preview transition (open birth/close exit)'} else {'shared/unknown; not exempt'})
                presentBeforeClose=$_.key -in $Ctx.PreviewCloseKeys;survivedClose=$_.key -in $postKeys}
        })
        $Ctx.Record['designerLifecycle'].Add(@{event='post-teardown';utc=[DateTime]::UtcNow.ToString('o');qpc=Get-Qpc;processes=$post;ownership=$ownership})
    }
}
function Invoke-SharedBench {
    $ctx=$null;$records=@{};$blocked=$null
    try {
        $ctx=Start-Launch 'Playing' 1; Invoke-Warmup $ctx
        foreach ($spec in $schedule) {
            $ctx.ActiveTheme=if ($spec.theme) {$spec.theme} else {$ctx.ActiveTheme}
            $ctx.LookId=$ctx.Items[$ctx.ActiveTheme].lookId
            $ctx.ItemId=$ctx.Items[$ctx.ActiveTheme].itemId
            $retention=$false;$arm=$null
            for ($attempt=1;$attempt -le 2;$attempt++) {
                if (-not (Test-TimeFits $armSeconds)) {$script:timeBoxHit=$true;throw 'time box reached'}
                if (-not (Test-AgeFits $ctx)) {throw 'PlayingLong age guard: entire unfinished batch blocked; no reset inside a window.'}
                $arm=Invoke-Arm $ctx $spec.pair $spec.condition $attempt
                $arm['id']=$spec.id;$arm['theme']=$spec.theme
                if ($arm.reasons -match 'shape|retention') {$retention=$true}
                if ($arm.valid) {break}
            }
            if (-not $arm.valid) {throw "Arm $($spec.id) invalid twice: $($arm.reasons -join '; ')"}
            $arm['retention']=$retention;$records[$spec.id]=$arm
        }
        $scores=Get-ObsSharedScore $schedule $records $budgets
        $workloadResults['Playing']=$scores
        foreach ($theme in $scores.Keys) {
            $s=$scores[$theme]
            if ($s.status -eq 'fresh-block-required') {Add-Blocked "G3.Playing.$theme" 'fresh separately approved Standard four-pair block' (@{triggers=$s.triggers;command="-Workload Playing -Look $theme -FallbackFrom <this bench-report.json> -FramesFrom $FramesFrom -StillsReport $StillsReport -TimeBoxMinutes 30"}|ConvertTo-Json -Compress)}
            else {Add-Check "G3.Playing.$theme" 'every largest conservative delta <= budget' $s ($s.status -eq 'pass')}
        }
    } catch {$blocked=$_.Exception.Message;Add-Blocked 'G3.Playing.SharedBaseline' "all $($schedule.Count) valid arms" $blocked;Add-RunError 'shared' 'Playing' 1 $script:launchIndex $_}
    finally {Stop-Launch $ctx}
}
function Get-DesignerCalibrationAck($Ctx, $Load) {
    $path=Join-Path (Get-BenchDirectory $Ctx.Root) 'designer-calibration-load.json'
    if (-not (Test-Path -LiteralPath $path)) {return $null}
    $ack=Get-Content -Raw -LiteralPath $path | ConvertFrom-Json -AsHashtable
    if ($ack['active'] -isnot [bool]) {return $null}
    foreach ($field in @('cpuPp','memMiB','retainedBytes')) {
        if ($ack[$field] -isnot [ValueType] -or $ack[$field] -is [bool] -or -not [double]::IsFinite([double]$ack[$field])) {return $null}
    }
    if ($Load.ContainsKey('off')) {
        if ($ack['active'] -ceq $false -and $ack['cpuPp'] -eq 0 -and $ack['memMiB'] -eq 0 -and $ack['retainedBytes'] -eq 0 -and $null -eq $ack['startedAtUtc']) {return $ack}
    } elseif ($ack['active'] -ceq $true -and $ack['cpuPp'] -eq $Load.cpuPp -and $ack['memMiB'] -eq $Load.memMiB -and
        $ack['retainedBytes'] -eq [Math]::Ceiling($Load.memMiB*1MB) -and $ack['startedAtUtc']) {
        return $ack
    }
    $null
}
function Set-DesignerCalibrationLoad($Ctx, $Load) {
    Assert-DesignerDeadline
    $path=Join-Path (Get-BenchDirectory $Ctx.Root) 'designer-calibration-load.json'
    Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue
    Send-ObsBenchPayload $Ctx 'command-obs-designer-calibration-load' ($Load | ConvertTo-Json -Compress)
    $ack=Wait-For {Get-DesignerCalibrationAck $Ctx $Load} 10 100
    if (-not $ack) {throw 'Calibration load acknowledgement missing or mismatched.'}
    $ack
}
function Get-DesignerPreviewDump($Ctx) {
    Assert-DesignerDeadline
    $path=Join-Path (Get-BenchDirectory $Ctx.Root) 'preview-state.json'
    Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue
    Send-HookCommand $Ctx.Root 'command-obs-preview-state-dump'
    if (-not (Wait-For {Test-Path -LiteralPath $path} 10 100)) {throw 'Preview-state-dump unavailable.'}
    $dump=Get-Content -Raw -LiteralPath $path | ConvertFrom-Json -AsHashtable -Depth 16
    if (-not $dump -or $dump.ContainsKey('error')) {throw 'Preview-state-dump failed.'}
    $dump
}
function Test-DesignerPausedDump($Before, $After) {
    foreach ($dump in @($Before,$After)) {
        if (-not $dump -or $dump['fillTimer'] -isnot [ValueType] -or $dump['fillTimer'] -is [bool] -or $dump['fillTimer'] -ne 0 -or
            $dump['runningAnimations'] -isnot [ValueType] -or $dump['runningAnimations'] -is [bool] -or $dump['runningAnimations'] -ne 0 -or
            $dump['cadenceLogSequence'] -isnot [ValueType] -or $dump['cadenceLogSequence'] -is [bool] -or
            $dump['pageNow'] -isnot [ValueType] -or $dump['pageNow'] -is [bool] -or -not [double]::IsFinite([double]$dump['pageNow']) -or
            $dump['counters'] -isnot [Collections.IDictionary] -or $dump['counters'].Count -eq 0) {return $false}
    }
    if ($Before.counters.Count -ne $After.counters.Count) {return $false}
    foreach ($key in $Before.counters.Keys) {
        if ($Before.counters[$key] -isnot [ValueType] -or $Before.counters[$key] -is [bool] -or
            -not [double]::IsFinite([double]$Before.counters[$key]) -or -not $After.counters.Contains($key) -or
            $After.counters[$key] -isnot [ValueType] -or $After.counters[$key] -is [bool] -or $Before.counters[$key] -ne $After.counters[$key]) {return $false}
    }
    $Before['cadenceLogSequence'] -eq $After['cadenceLogSequence'] -and $After['pageNow']-$Before['pageNow'] -ge 5000
}
function Invoke-DesignerPausedProbe($Ctx) {
    $id='sample-paused-structural';$saved=$script:designerCondition
    try {
        if (-not (Test-TimeFits 60)) {throw 'deadline: structural probe and cleanup cannot fit'}
        if ($Ctx.Reader) {Stop-DesignerPreview $Ctx}
        $script:designerCondition=@{name='sample-paused';kind='sample';sample='paused';worst=$false;lyrics=$false}
        Start-DesignerPreview $Ctx
        if (-not (Wait-For {$s=Get-State $Ctx.Root 'pausedstructural';if (Test-ObsBenchA $Ctx $s) {$s}} 20)) {throw 'Paused structural preview not ready.'}
        $before=Wait-For {$d=Get-DesignerPreviewDump $Ctx;if ($d['fillTimer'] -eq 0 -and $d['runningAnimations'] -eq 0) {$d}} 10 250
        if (-not $before) {throw 'Paused structural preview did not become idle.'}
        $start=Get-Qpc
        Wait-UntilQpc ($start+5*$freq)
        $after=Get-DesignerPreviewDump $Ctx
        $ok=Test-DesignerPausedDump $before $after
        $row=@{kind='structural';status=$(if ($ok) {'pass'} else {'fail'});seconds=Get-Seconds $start (Get-Qpc);before=$before;after=$after;resourceQualified=$false}
        $script:designerProfileRows[$id]=$row
        Add-Check "Designer.$id" 'fillTimer=0; no running animations; all counters and cadence stable over >=5s; NOT resource qualification' $row $ok
    } catch {
        $script:designerProfileRows[$id]=@{kind='structural';status='blocked';reason=$_.Exception.Message;resourceQualified=$false}
        Add-Blocked "Designer.$id" '5s structural idle probe, not a resource pass' $_.Exception.Message
    } finally {
        try {if ($Ctx.Reader) {Stop-DesignerPreview $Ctx}} catch {Add-Blocked "Designer.$id.cleanup" 'preview closed' $_.Exception.Message}
        $script:designerCondition=$saved
    }
}
function Invoke-DesignerGrossCalibration($Ctx) {
    foreach ($spec in @(
        @{id='gross-cpu';metric='app.cpuPp';cpuPp=1.0;memMiB=0.0},
        @{id='gross-memory';metric='app.privateMiB';cpuPp=0.0;memMiB=120.0})) {
        $id=$spec.id
        try {
            if (-not (Test-TimeFits (2*$armSeconds+60))) {throw 'deadline: full calibration AB pair and cleanup cannot fit'}
            $script:designerCalibration=@{cpuPp=$spec.cpuPp;memMiB=$spec.memMiB}
            $pair=@{}
            foreach ($condition in @('A','B')) {
                $arm=$null
                for ($attempt=1;$attempt -le 2;$attempt++) {
                    $remaining=if ($condition -eq 'A') {2*$armSeconds+60} else {$armSeconds+60}
                    if (-not (Test-TimeFits $remaining)) {throw 'deadline: calibration windows and cleanup cannot fit'}
                    if (-not (Test-AgeFits $Ctx)) {throw 'Calibration fixture-age guard reached.'}
                    $arm=Invoke-Arm $Ctx $(if ($id -eq 'gross-cpu') {3} else {4}) $condition $attempt
                    $arm['calibration']=$id
                    if ($arm.valid) {break}
                }
                if (-not $arm.valid) {throw "Calibration arm invalid twice: $($arm.reasons -join '; ')"}
                $pair[$condition]=$arm
            }
            $delta=Round3 ([double]$pair.A.metrics[$spec.metric]-[double]$pair.B.metrics[$spec.metric])
            $v=Get-Verdict @($delta) $budgets[$spec.metric]
            $detected=$v.verdict -eq 'fail'
            $row=@{kind='calibration';label='gross attribution check; not near-ceiling sensitivity';status=$(if ($detected) {'pass'} else {'fail'})
                verdict=$(if ($detected) {'calibration detected'} else {'calibration NOT detected'});metric=$spec.metric;budget=$budgets[$spec.metric]
                injected=$script:designerCalibration;delta=$delta;metricVerdict=$v.verdict;a=$pair.A.id;b=$pair.B.id;ack=$pair.A.calibrationAck;offAck=$Ctx.Record['calibrationOff']}
            $script:designerProfileRows[$id]=$row
            Add-Check "Designer.$id" "A-only gross load: $($spec.metric) MUST FAIL unchanged budget (calibration detected)" $row $detected
        } catch {
            $script:designerProfileRows[$id]=@{kind='calibration';status='blocked';reason=$_.Exception.Message}
            Add-Blocked "Designer.$id" 'full valid AB pair; gross attribution check detects metric violation' $_.Exception.Message
        } finally {
            try {if ($Ctx.Reader) {Stop-DesignerPreview $Ctx}} catch {Add-Blocked "Designer.$id.cleanup" 'load off and preview closed' $_.Exception.Message}
            $script:designerCalibration=$null
        }
    }
}
function Invoke-DesignerBench {
    $conditions=@(Get-ObsDesignerConditions $Profile)
    if ($Profile -eq 'Fast-v1') {
        foreach ($c in $conditions) {$script:designerProfileRows["$($c.name)-lyrics-$($c.lyrics)"]=@{kind='measured';status='blocked';reason='not run'}}
        foreach ($id in @('sample-paused-structural','gross-cpu','gross-memory')) {$script:designerProfileRows[$id]=@{kind=$(if ($id -eq 'sample-paused-structural') {'structural'} else {'calibration'});status='blocked';reason='not run'}}
    }
    for ($i=0;$i -lt $conditions.Count;$i++) {
        $c=$conditions[$i];$script:designerCondition=$c
        $name="$($c.name)-lyrics-$($c.lyrics)"
        if ($script:timeBoxHit) {Add-Blocked "Designer.$name" 'complete full-length block' 'time box reached';continue}
        $b=Invoke-Block 'Playing' 1 -ProbeAfter:($Profile -eq 'Fast-v1' -and $i -eq 0) -CalibrationAfter:($Profile -eq 'Fast-v1' -and $i -eq $conditions.Count-1)
        $workloadResults[$name]=$b
        if ($b.blocked) {
            $script:designerProfileRows[$name]=@{kind='measured';status='blocked';reason=$b.blocked;pairs=$b.pairs}
            Add-Blocked "Designer.$name" "$Pairs valid balanced AB/BA pairs" $b.blocked;continue
        }
        $metrics=[ordered]@{}
        foreach ($m in $budgets.Keys) {
            $v=Get-Verdict @($b.pairs | ForEach-Object {$_.delta[$m]}) $budgets[$m];$metrics[$m]=$v
            if ($Profile -eq 'Fast-v1' -and $v.verdict -in @('between','blocked')) {Add-Blocked "Designer.$name.$m" "every pair <= $($budgets[$m])" (Get-ObsPairedDiagnostic $v)}
            else {Add-Check "Designer.$name.$m" "every pair <= $($budgets[$m])" $v ($v.verdict -eq 'pass')}
        }
        $script:designerProfileRows[$name]=@{kind='measured';status=$(if (@($metrics.Values | Where-Object {$_.verdict -in @('between','blocked')}).Count) {'blocked'} elseif (@($metrics.Values | Where-Object {$_.verdict -eq 'fail'}).Count) {'fail'} else {'pass'});metrics=$metrics;pairs=$b.pairs}
    }
    if ($Profile -eq 'Fast-v1') {
        foreach ($id in @('sample-paused-structural','gross-cpu','gross-memory')) {
            if ($script:designerProfileRows[$id].status -eq 'blocked' -and $script:designerProfileRows[$id].reason -eq 'not run') {
                Add-Blocked "Designer.$id" 'required fast diagnostic row' 'not run before deadline or anchor failure'
            }
        }
    }
}
