Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-TaskContext {
    param([string]$Environment = 'dev')
    if ($Environment -notmatch '^[a-z][a-z0-9-]{0,30}$') { throw 'Environment: 소문자/숫자/하이픈만 허용합니다.' }
    $root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    $directory = Join-Path $root ".local/$Environment"
    [pscustomobject]@{ Root=$root; Directory=$directory; Environment=$Environment; Config=(Join-Path $directory 'config.json'); Review=(Join-Path $directory 'console-review.json') }
}

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "필요한 파일이 없습니다: $Path" }
    Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json -AsHashtable -Depth 100
}

function Write-PrivateJson {
    param([string]$Path, $Value)
    $Value | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $Path -Encoding utf8
}

function Protect-EnvironmentDirectory {
    param([string]$Path)
    [void][IO.Directory]::CreateDirectory($Path)
    if ($IsWindows) {
        $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User
        $directory=[IO.DirectoryInfo]::new($Path)
        $current=[IO.FileSystemAclExtensions]::GetAccessControl($directory,([Security.AccessControl.AccessControlSections]::Access -bor [Security.AccessControl.AccessControlSections]::Owner))
        $rules=@($current.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
        $owner=$current.GetOwner([Security.Principal.SecurityIdentifier])
        if ($owner -eq $sid -and $current.AreAccessRulesProtected -and $rules.Count -eq 1 -and $rules[0].IdentityReference -eq $sid -and $rules[0].AccessControlType -eq 'Allow' -and ($rules[0].FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -eq [Security.AccessControl.FileSystemRights]::FullControl) { return }
        $acl=[Security.AccessControl.DirectorySecurity]::new()
        $acl.SetAccessRuleProtection($true,$false)
        if ($owner -ne $sid) { $acl.SetOwner($sid) }
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow'))
        # Never request SACL privileges. Existing current-user ownership is left unchanged.
        [IO.FileSystemAclExtensions]::SetAccessControl($directory,$acl)
    } else { [IO.File]::SetUnixFileMode($Path,[IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute) }
}

function Assert-EnvironmentTarget {
    param($Context,[string]$Tenancy,[string]$Region,[string]$Compartment)
    Assert-Condition (@(Get-ChildItem -LiteralPath $Context.Root -Filter '*.tfstate*' -File).Count -eq 0) '저장소 루트에 기존 State가 있습니다. 신규 환경 생성 대신 원본 백업과 승인된 State 이행 계획을 먼저 준비하세요.'
    $path=Join-Path $Context.Directory 'target.json'
    $target=@{tenancy_ocid=$Tenancy;region=$Region;compartment_ocid=$Compartment;environment=$Context.Environment}
    if (Test-Path -LiteralPath $path) {
        $previous=Read-JsonFile $path
        foreach ($key in $target.Keys) { Assert-Condition ($previous[$key] -ceq $target[$key]) '환경이 다른 tenancy/region/compartment에 이미 묶여 있습니다. 기존 State를 보존하고 별도 환경 이름을 사용하세요.' }
    } else {
        Assert-Condition (-not (Test-Path -LiteralPath (Join-Path $Context.Directory 'terraform.tfstate'))) '대상 기록 없이 State가 존재합니다. 복구/이행 확인이 먼저 필요합니다.'
        Write-PrivateJson $path $target
    }
}

function Assert-Condition {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Get-SafeNativeDiagnostic {
    param([string]$Stdout,[string]$Stderr,[int]$ExitCode,[string]$Tool='native',[string]$Operation='native',[hashtable]$Scope=@{},[switch]$TimedOut)
    # Never return message/detail/arguments/SQL/body. Only recognize fixed error classes.
    $messages=@{
        NotAuthenticated='API profile, 등록한 공개키, 개인키 경로와 PC 시계를 확인하세요.'
        NotAuthorized='IAM 사용자 그룹 및 대상 compartment 권한을 확인하세요. 자동 권한 확대는 하지 않습니다.'
        NotAuthorizedOrNotFound='OCID/리전/compartment와 읽기 권한을 함께 확인하세요. 404를 빈 사용량으로 처리하지 않습니다.'
        RelatedResourceNotAuthorizedOrNotFound='연결할 subnet/NSG와 MySQL resource principal의 권한을 확인하세요.'
        InvalidParameter='선택한 리전의 값과 provider schema/설정 형식을 확인하세요.'
        MissingParameter='가이드의 필수 입력과 config.json 키를 확인하세요.'
        CannotParseRequest='요청 형식과 OCI CLI 버전을 확인하세요.'
        LimitExceeded='기존 사용량과 OCI limit를 확인하세요. 유료 전환/기존 리소스 삭제를 자동 수행하지 않습니다.'
        QuotaExceeded='대상 compartment quota와 기존 사용량을 확인하세요.'
        NotAllowed='요청 리전이 home region인지 확인하세요.'
        Conflict='현재 상태와 기존 리소스를 읽기 조회한 뒤 새 plan을 검토하세요.'
        IncorrectState='서비스 상태를 읽기 조회하세요. 자동 재적용하지 않습니다.'
        ResourceLocked='잠금 소유자와 실행 중인 작업을 확인하세요. 잠금을 자동 해제하지 않습니다.'
        TooManyRequests='요청 제한입니다. 잠시 후 읽기 조회부터 수동 재시도하세요.'
        InternalServerError='OCI 서비스 장애 여부와 request ID를 확인하세요. Apply를 자동 재실행하지 않습니다.'
        ServiceUnavailable='OCI 서비스 가용 상태를 확인하세요.'
        ExternalServerTimeout='OCI 연관 서비스 응답 지연입니다. 현재 상태를 먼저 조회하세요.'
        OutOfHostCapacity='해당 무료 shape/AD의 물리 capacity가 부족합니다. 유료/ARM 대안 없이 중단합니다.'
        SSH_HOST_KEY_MISMATCH='SSH host key를 OCI의 독립 경로에서 재확인하세요. known_hosts 삭제나 StrictHostKeyChecking 해제로 우회하지 마세요.'
        SSH_HOST_KEY_UNKNOWN='독립 확인한 host key를 known_hosts에 먼저 등록하세요.'
        SSH_PUBLICKEY='일치하는 Windows ssh-agent에 해당 키를 ssh-add로 등록하고 fingerprint를 확인하세요.'
        SSH_AGENT_UNAVAILABLE='Windows ssh-agent 서비스 상태와 ssh.exe/ssh-add.exe 경로 일치를 확인하세요.'
        CONNECTION_TIMEOUT='네트워크, 관리 공인 IP, NSG/방화벽과 서비스 상태를 확인하세요.'
        CONNECTION_REFUSED='대상 IP/포트와 서비스 준비 상태를 확인하세요.'
        DNS_FAILURE='대상 hostname, VPN/DNS와 OCI 리전을 확인하세요.'
        TLS_VERIFICATION='신뢰 CA·인증서 hostname·만료일을 확인하세요. 인증서 검증을 끄지 마세요.'
        TF_STATE_LOCK='진행 중인 Terraform 작업과 State 잠금을 확인하세요. 자동 unlock하지 않습니다.'
        TF_STALE_PLAN='State/설정 변경이 있습니다. 새 Plan과 새 승인이 필요합니다.'
        TF_PREVENT_DESTROY='삭제 보호가 삭제/교체를 차단했습니다. 보호 해제와 삭제는 별도 계획·승인이 필요합니다.'
        TF_BACKEND='올바른 환경으로 Plan.ps1을 실행하여 backend를 준비하세요. 기존 State를 지우지 마세요.'
        TF_LOCKFILE='고정 provider와 lockfile을 확인하세요. 버전을 임의 갱신하지 마세요.'
        TF_REGISTRY='공식 Terraform registry 연결·프록시·TLS·네트워크 접근 권한을 확인하세요. provider lock은 유지합니다.'
        TOOL_ARGUMENT='설치한 도구 버전과 지원 인자를 확인하세요.'
        CERT_VM_TOOL_MISSING='인증서 수집 VM에 timeout/OpenSSL 명령이 없습니다. VM의 도구 경로·설치를 확인하세요. 자동 설치나 TLS fallback은 하지 않습니다.'
        TIMEOUT='읽기/접속 검사 제한 시간이 지났습니다. 네트워크·권한을 확인한 뒤 수동 재시도하세요.'
        UNKNOWN='허용된 오류 분류를 찾지 못했습니다. 작업명·종료 코드로 진단하세요. 원문 전체를 공유하지 마세요.'
    }
    $combined=$Stderr+"`n"+$Stdout
    $code='UNKNOWN'
    $ociCodes=@('NotAuthenticated','NotAuthorized','NotAuthorizedOrNotFound','RelatedResourceNotAuthorizedOrNotFound','InvalidParameter','MissingParameter','CannotParseRequest','LimitExceeded','QuotaExceeded','NotAllowed','Conflict','IncorrectState','ResourceLocked','TooManyRequests','InternalServerError','ServiceUnavailable','ExternalServerTimeout','OutOfHostCapacity')
    foreach ($candidate in $ociCodes) {
        if ($combined -match ('(?im)(?:["'']code["'']\s*:\s*["'']|\b(?:Error:\s*)?[45]\d\d[- ,]+)'+[regex]::Escape($candidate)+'\b')) { $code=$candidate;break }
    }
    if ($code -eq 'UNKNOWN') {
        $patterns=[ordered]@{
            SSH_HOST_KEY_MISMATCH='REMOTE HOST IDENTIFICATION HAS CHANGED|Offending .* key in'
            SSH_HOST_KEY_UNKNOWN='Host key verification failed|No .* host key is known'
            SSH_PUBLICKEY='Permission denied \(publickey|sign_and_send_pubkey: signing failed'
            SSH_AGENT_UNAVAILABLE='Could not open a connection to your authentication agent|Error connecting to agent'
            CONNECTION_TIMEOUT='Connection timed out|connect timeout|ReadTimeout|ConnectTimeout'
            CONNECTION_REFUSED='Connection refused'
            DNS_FAILURE='Could not resolve hostname|Name or service not known|No such host is known'
            TLS_VERIFICATION='CERTIFICATE_VERIFY_FAILED|certificate verify failed|SSL certificate problem'
            TF_STATE_LOCK='Error acquiring the state lock'
            TF_STALE_PLAN='Saved plan is stale|Saved plan does not match'
            TF_PREVENT_DESTROY='prevent_destroy|Instance cannot be destroyed'
            TF_BACKEND='Backend initialization required'
            TF_LOCKFILE='Inconsistent dependency lock file|locked provider.*does not match'
            TF_REGISTRY='Failed to query available provider packages|Could not retrieve the list of available versions|Failed to install provider'
            OutOfHostCapacity='Out of host capacity|Out of capacity'
            TOOL_ARGUMENT='unrecognized arguments|No such option|flag provided but not defined|Unknown option|Invalid -starttls|Value must be one of'
        }
        foreach ($candidate in $patterns.Keys) { if ($combined -match $patterns[$candidate]) { $code=$candidate;break } }
    }
    if ($Operation -eq 'certificate-read' -and $ExitCode -eq 126) { $code='CERT_VM_TOOL_MISSING' }
    if ($TimedOut -or ($Operation -eq 'certificate-read' -and $ExitCode -eq 124)) { $code='TIMEOUT' }
    $http=$null;$requestId=$null
    if ($combined -match '(?im)["''](?:status|status_code|statusCode)["'']\s*:\s*([45]\d\d)\b') { $http=[int]$Matches[1] }
    elseif ($combined -match '(?im)\bError:\s*([45]\d\d)[-, ]') { $http=[int]$Matches[1] }
    # OCI request IDs have several formats. Show only this strict hex trace form;
    # unknown formats are withheld instead of accepting arbitrary response strings.
    if ($combined -match '(?im)(?:["'']opc-request-id["'']\s*:\s*["'']|\bopc request id:\s*)([A-Fa-f0-9]{32}/[A-Fa-f0-9]{32}/[A-Fa-f0-9]{32})(?:["''\s]|$)') { $requestId=$Matches[1] }
    $safeScope=@{}
    if ($Scope.ContainsKey('region') -and $Scope.region -cmatch '^[a-z]{2,3}-[a-z0-9-]+-[1-9][0-9]*$') { $safeScope.region=$Scope.region }
    if ($Scope.ContainsKey('compartment_id') -and $Scope.compartment_id -cmatch '^ocid1\.(compartment|tenancy)\.oc1\.[a-z0-9.]{1,160}$') { $safeScope.compartment_id=$Scope.compartment_id }
    if ($Operation -notin @('native','oci-read','ssh-check','ssh-verify','certificate-read','terraform-init','terraform-plan','terraform-apply','terraform-output','offline-test','tool-version')) { $Operation='native' }
    if ($Tool -notin @('oci','terraform','ssh','ssh-add','ssh-keygen','pwsh','python','python3','mysql')) { $Tool='native' }
    [pscustomobject]@{tool=$Tool;operation=$Operation;exit_code=$ExitCode;code=$code;http_status=$http;request_id=$requestId;scope=$safeScope;action=$messages[$code];raw_output='WITHHELD'}
}

function Invoke-NativeTool {
    param([string]$FilePath, [string[]]$Arguments, [int[]]$AcceptedExitCodes = @(0), [string]$WorkingDirectory,
        [ValidateRange(0,86400)][int]$TimeoutSeconds=0,[string]$Operation='native',[hashtable]$DiagnosticScope=@{})
    $command = Get-Command $FilePath -ErrorAction Stop
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $command.Source
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    if ($WorkingDirectory) { $start.WorkingDirectory = $WorkingDirectory }
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    $started=$false
    $isApply=([IO.Path]::GetFileNameWithoutExtension($start.FileName) -eq 'terraform' -and $Arguments.Count -gt 0 -and $Arguments[0] -in @('apply','destroy'))
    if ($isApply -and $TimeoutSeconds -ne 0) { throw 'Apply/Destroy에 짧은 공통 timeout을 적용할 수 없습니다. 승인된 장기 작업은 자동 종료/재적용하지 않습니다.' }
    try {
        $started=$process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $timedOut=$false
        if ($TimeoutSeconds -gt 0) {
            if (-not $process.WaitForExit($TimeoutSeconds*1000)) { $timedOut=$true;$process.Kill($true);$process.WaitForExit() }
        } else { $process.WaitForExit() }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        if ($timedOut -or $process.ExitCode -notin $AcceptedExitCodes) {
            $diagnostic=Get-SafeNativeDiagnostic -Stdout $stdout -Stderr $stderr -ExitCode $process.ExitCode -Tool ([IO.Path]::GetFileNameWithoutExtension($start.FileName)) -Operation $Operation -Scope $DiagnosticScope -TimedOut:$timedOut
            $message="$($diagnostic.tool) 실패 (exit=$($diagnostic.exit_code)); operation=$($diagnostic.operation); code=$($diagnostic.code)"
            if ($null -ne $diagnostic.http_status) { $message+="; http=$($diagnostic.http_status)" }
            if ($diagnostic.request_id) { $message+="; request_id=$($diagnostic.request_id)" }
            foreach ($key in $diagnostic.scope.Keys) { $message+="; $key=$($diagnostic.scope[$key])" }
            $exception=[InvalidOperationException]::new($message+". "+$diagnostic.action+' 원문 stdout/stderr/SQL/State는 출력하지 않았습니다.')
            $exception.Data['SafeDiagnostic']=$diagnostic
            throw $exception
        }
        [pscustomobject]@{ ExitCode=$process.ExitCode; Stdout=$stdout; Stderr=$stderr }
    } finally {
        # Timed reads are killed above. Never kill/reapply Terraform mutations in cleanup.
        if ($started -and -not $process.HasExited -and $TimeoutSeconds -gt 0 -and -not $isApply) { $process.Kill($true);$process.WaitForExit() }
        $process.Dispose()
    }
}

function Get-ProfileIdentity {
    param([string]$Profile)
    Assert-Condition ($Profile -match '^[A-Za-z0-9_-]+$') 'OCI profile 이름이 올바르지 않습니다.'
    $path = Join-Path $HOME '.oci/config'
    if (-not (Test-Path -LiteralPath $path)) { throw 'OCI API profile이 없습니다. ~/.oci/config에 전용 profile을 먼저 등록하세요.' }
    $section = ''; $values = @{}
    foreach ($line in Get-Content -LiteralPath $path) {
        if ($line -match '^\s*\[([^\]]+)\]\s*$') { $section = $Matches[1]; continue }
        if ($section -ceq $Profile -and $line -match '^\s*([^#;=]+?)\s*=\s*(.*?)\s*$') { $values[$Matches[1]]=$Matches[2] }
    }
    foreach ($key in @('tenancy','user','fingerprint','key_file')) { Assert-Condition ($values.ContainsKey($key) -and $values[$key] -notmatch 'REPLACE') "OCI profile의 $key 값이 필요합니다." }
    Assert-Condition ($values.tenancy -match '^ocid1\.tenancy\.oc1\.\.') 'Commercial realm(oc1) tenancy만 지원합니다.'
    [pscustomobject]@{ Tenancy=$values.tenancy; ConfigPath=$path; Profile=$Profile }
}

function Invoke-OciJson {
    param($Identity, [string]$Region, [string[]]$Arguments, [switch]$List)
    if ($List) {
        Assert-Condition ($Arguments.Count -ge 4 -and $Arguments[2] -ceq 'list' -and @($Arguments | Where-Object { $_ -ceq '--all' }).Count -eq 1) 'OCI 목록 명령과 --all이 필요합니다.'
        # OCI CLI v3.94.0 omits data=[] in its JSON renderer. A user RC file,
        # ambient CLI override or query could turn a nonempty list into silence.
        # The empty-output exception below is valid only under this fixed contract.
        Assert-Condition (@($Arguments | Where-Object { $_ -in @('--query','--raw-output','--output','--cli-rc-file','--endpoint','--page','--limit','--debug') }).Count -eq 0) 'OCI_LIST_OPTIONS_UNSAFE: 목록 출력/페이지 옵션을 변경할 수 없습니다.'
        Assert-Condition (@(Get-ChildItem Env: | Where-Object { $_.Name -like 'OCI_CLI_*' }).Count -eq 0) 'OCI_CLI_ENV_OVERRIDE: 별도 PowerShell 세션에서 OCI_CLI_* 환경 설정을 확인하세요. 값은 출력하지 않습니다.'
    }
    $rcPath=Join-Path $PSScriptRoot '../oci-cli-empty-rc.ini'
    Assert-Condition (Test-Path -LiteralPath $rcPath -PathType Leaf) 'OCI_CLI_RC_MISSING: 고정 CLI 설정 파일이 없습니다.'
    $rcText=Get-Content -LiteralPath $rcPath -Raw
    Assert-Condition ($rcText -match '^# OCI CLI defaults are intentionally disabled\.\r?\n?$') 'OCI_CLI_RC_CHANGED: 고정 CLI 설정 파일을 검토하세요.'
    $argumentsAll = @('--config-file',$Identity.ConfigPath,'--profile',$Identity.Profile,'--auth','api_key','--region',$Region,'--output','json','--cli-rc-file',$rcPath) + $Arguments
    $scope=@{region=$Region}
    $index=[Array]::IndexOf($Arguments,'--compartment-id')
    if ($index -ge 0 -and $index+1 -lt $Arguments.Count) { $scope.compartment_id=$Arguments[$index+1] }
    try { $result = Invoke-NativeTool -FilePath 'oci' -Arguments $argumentsAll -TimeoutSeconds 120 -Operation 'oci-read' -DiagnosticScope $scope }
    catch {
        # Unexpected launch/configuration errors can also carry secrets. Never append
        # arbitrary Exception.Message; propagate only our allowlisted diagnostic.
        $diagnostic=$_.Exception.Data['SafeDiagnostic']
        if ($null -eq $diagnostic) { $diagnostic=Get-SafeNativeDiagnostic -ExitCode -1 -Tool oci -Operation oci-read -Scope $scope }
        $message="OCI 읽기 조회 실패; code=$($diagnostic.code); exit=$($diagnostic.exit_code)"
        if ($null -ne $diagnostic.http_status) { $message+="; http=$($diagnostic.http_status)" }
        if ($diagnostic.request_id) { $message+="; request_id=$($diagnostic.request_id)" }
        foreach ($key in $diagnostic.scope.Keys) { $message+="; $key=$($diagnostic.scope[$key])" }
        $exception=[InvalidOperationException]::new($message+'. '+$diagnostic.action+' 전체 사용량 확인 불가로 중단합니다. 원문은 출력하지 않습니다.')
        $exception.Data['SafeDiagnostic']=$diagnostic
        throw $exception
    }
    Assert-Condition ($result.ExitCode -is [int] -and $result.ExitCode -eq 0) 'OCI_NATIVE_EXIT_INVALID: 종료 코드 0을 확인하지 못했습니다. 0건으로 처리하지 않습니다.'
    $candidate=$false
    if ($List -and ($result.Stdout -ceq '' -or $result.Stdout -match '^\s*\{')) {
        # For a candidate omission, require the exact renderer version and no
        # stderr (including pagination/query notices). Never log raw streams.
        $headerCandidate=$null
        $candidate=$result.Stdout -ceq ''
        if (-not $candidate) {
            try { $headerCandidate=$result.Stdout | ConvertFrom-Json -AsHashtable -Depth 100 } catch { $headerCandidate=$null }
            $candidate=($headerCandidate -is [hashtable] -and -not $headerCandidate.ContainsKey('data'))
        }
        if ($candidate) {
            if ($null -ne $headerCandidate) { Assert-Condition (-not $headerCandidate.ContainsKey('opc-next-page') -and -not $headerCandidate.ContainsKey('opc-next-cursor')) 'OCI pagination이 완료되지 않았습니다.' }
            Assert-Condition ([string]::IsNullOrEmpty($result.Stderr)) 'OCI_LIST_STDERR_UNCONFIRMED: 빈 목록의 경고/오류 출력을 확인해야 합니다. 원문은 출력하지 않습니다.'
            $version=Invoke-NativeTool -FilePath 'oci' -Arguments @('--version') -TimeoutSeconds 20 -Operation tool-version
            Assert-Condition ($version.ExitCode -is [int] -and $version.ExitCode -eq 0 -and $version.Stdout.Trim() -ceq '3.94.0' -and [string]::IsNullOrEmpty($version.Stderr)) 'OCI_CLI_VERSION_UNSUPPORTED: 빈 목록은 검증한 OCI CLI 3.94.0에서만 판정합니다.'
            if ($result.Stdout -ceq '') { return @() }
        }
    }
    try { $parsed = $result.Stdout | ConvertFrom-Json -AsHashtable -Depth 100 } catch { throw 'OCI_JSON_INVALID: 응답이 JSON이 아닙니다. 원문은 비밀 보호를 위해 출력하지 않습니다. CLI 버전을 확인하세요.' }
    Assert-Condition ($parsed -is [hashtable] -and $parsed.ContainsKey('data') -and $null -ne $parsed.data -or ($List -and $candidate -and $parsed -is [hashtable])) 'OCI 응답 data 누락: 검증 중단.'
    if ($List) {
        Assert-Condition (-not $parsed.ContainsKey('opc-next-page') -and -not $parsed.ContainsKey('opc-next-cursor')) 'OCI pagination이 완료되지 않았습니다.'
        if (-not $parsed.ContainsKey('data')) {
            Assert-Condition (@($parsed.Keys | Where-Object { $_ -notin @('etag','opc-total-items') }).Count -eq 0 -and $parsed.Count -gt 0) 'OCI_LIST_HEADERS_INVALID: 빈 목록을 증명하지 못했습니다.'
            if ($parsed.ContainsKey('opc-total-items')) { Assert-Condition ($parsed['opc-total-items'] -ceq '0' -or (($parsed['opc-total-items'] -is [int] -or $parsed['opc-total-items'] -is [long]) -and $parsed['opc-total-items'] -eq 0)) 'OCI_LIST_COUNT_INVALID: 총건수가 0으로 확인되지 않았습니다.' }
            return @()
        }
        Assert-Condition ($parsed.data -is [array]) 'OCI 목록 응답이 배열이 아닙니다.'
        if ($parsed.data.Count -eq 0 -and $parsed.ContainsKey('opc-total-items')) { Assert-Condition ($parsed['opc-total-items'] -ceq '0' -or (($parsed['opc-total-items'] -is [int] -or $parsed['opc-total-items'] -is [long]) -and $parsed['opc-total-items'] -eq 0)) 'OCI_LIST_COUNT_INVALID: 총건수가 0으로 확인되지 않았습니다.' }
    } else {
        Assert-Condition ($parsed.data -is [hashtable]) 'OCI_GET_DATA_INVALID: 상세조회가 단일 객체를 반환하지 않았습니다.'
    }
    return $parsed.data
}

function Set-TerraformContext {
    param($Context)
    $env:TF_DATA_DIR = Join-Path $Context.Directory '.terraform'
    $env:TF_IN_AUTOMATION = 'true'
    # Ambient CLI flags must not inject a different var-file, target, state or refresh=false.
    foreach ($item in Get-ChildItem Env: | Where-Object { $_.Name -like 'TF_CLI_ARGS*' -or $_.Name -like 'TF_VAR_*' -or $_.Name -eq 'TF_WORKSPACE' }) { Remove-Item -LiteralPath "Env:$($item.Name)" }
}

function Initialize-Terraform {
    param($Context)
    Set-TerraformContext $Context
    $statePath = Join-Path $Context.Directory 'terraform.tfstate'
    $result = Invoke-NativeTool -FilePath 'terraform' -WorkingDirectory $Context.Root -Arguments @('init','-input=false','-reconfigure','-lockfile=readonly',"-backend-config=path=$statePath") -Operation 'terraform-init'
    Write-Host 'Terraform init: PASS (환경별 local backend)'
}

function Get-SourceFingerprint {
    param($Context)
    $files = @(Get-ChildItem -LiteralPath $Context.Root -File -Filter '*.tf')
    $files += Get-Item -LiteralPath (Join-Path $Context.Root '.terraform.lock.hcl'),$Context.Config,$Context.Review,(Join-Path $Context.Directory 'target.json')
    foreach ($folder in @('cloud-init','scripts')) {
        $path = Join-Path $Context.Root $folder
        if (Test-Path -LiteralPath $path) { $files += Get-ChildItem -LiteralPath $path -File -Recurse }
    }
    $lines = @($files | Sort-Object FullName | ForEach-Object { $_.FullName + ':' + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash })
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($lines -join "`n"))))
}

Export-ModuleMember -Function *
