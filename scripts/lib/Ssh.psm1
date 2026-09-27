Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -DisableNameChecking

function Assert-WindowsSshAgentState {
    param([string]$Directory,$Service,[string]$Socket)
    Assert-Condition ((-not $Socket) -or $Socket.Replace('\','/') -eq '//./pipe/openssh-ssh-agent') 'SSH_AGENT_MIXED: SSH_AUTH_SOCK가 다른 agent를 가리킵니다. Git Bash와 분리한 Windows PowerShell에서 Windows agent를 사용하세요. 현재 세션 변수와 PATH를 확인하세요.'
    Assert-Condition ($null -ne $Service) 'SSH_AGENT_ABSENT: Windows OpenSSH Client와 ssh-agent 서비스를 확인하세요.'
    $expected=Join-Path $Directory 'ssh-agent.exe'
    $actual=([Environment]::ExpandEnvironmentVariables([string]$Service.PathName)).Trim().Trim('"')
    Assert-Condition ([IO.Path]::GetFullPath($actual) -ieq [IO.Path]::GetFullPath($expected)) 'SSH_AGENT_MIXED: Windows ssh-agent 서비스 실행 경로가 선택한 OpenSSH 디렉터리와 다릅니다. 관리자가 설치 경로를 확인해야 합니다.'
    Assert-Condition ($Service.State -eq 'Running') 'SSH_AGENT_STOPPED: 관리자 PowerShell에서 Get-Service ssh-agent | Set-Service -StartupType Automatic; Start-Service ssh-agent 를 검토해 직접 실행한 뒤 일반 사용자로 ssh-add를 실행하세요. 스크립트는 서비스를 변경하지 않습니다.'
}

function Get-WindowsSshToolchain {
    # Select all three binaries explicitly. PATH may resolve Git's client, which
    # does not necessarily use the Windows service's agent.
    Assert-Condition $IsWindows 'SSH_WINDOWS_REQUIRED: 이 자동 경로는 Windows OpenSSH용입니다.'
    $directory = Join-Path $env:SystemRoot 'System32/OpenSSH'
    $tools = @{ Directory=$directory; Ssh=(Join-Path $directory 'ssh.exe'); Add=(Join-Path $directory 'ssh-add.exe'); Keygen=(Join-Path $directory 'ssh-keygen.exe'); Agent='//./pipe/openssh-ssh-agent'; PathClient='NOT_FOUND' }
    foreach ($name in @('Ssh','Add','Keygen')) { Assert-Condition (Test-Path -LiteralPath $tools[$name] -PathType Leaf) 'SSH_TOOL_MISSING: Windows 설정 > 시스템 > 선택적 기능에서 OpenSSH Client 설치를 확인하세요.' }
    $pathClient = Get-Command ssh.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pathClient) { $tools.PathClient=$pathClient.Source }
    try { $service=Get-CimInstance -ClassName Win32_Service -Filter "Name='ssh-agent'" -ErrorAction Stop } catch { throw 'SSH_AGENT_SERVICE_UNVERIFIED: ssh-agent 서비스 경로/상태를 조회할 수 없습니다. 서비스 읽기 권한을 확인하세요.' }
    Assert-WindowsSshAgentState $directory $service $env:SSH_AUTH_SOCK
    return $tools
}

function Get-SshFingerprint {
    param([string]$Text)
    $matchesFound=[regex]::Matches($Text,'(?m)^\s*\d+\s+(SHA256:[A-Za-z0-9+/]{20,}={0,2})(?:\s|$)')
    foreach ($match in $matchesFound) { $match.Groups[1].Value }
}

function Get-SshFailureCode {
    param([string]$Stderr)
    # No free-text stderr is returned: it may contain local paths or secrets.
    if ($Stderr -match 'REMOTE HOST IDENTIFICATION HAS CHANGED|Host key verification failed|No .* host key is known') { return 'SSH_HOST_KEY_MISMATCH_OR_UNKNOWN' }
    if ($Stderr -match 'Permission denied|sign_and_send_pubkey|agent refused operation') { return 'SSH_AUTHENTICATION_FAILED' }
    if ($Stderr -match 'Connection timed out|Operation timed out') { return 'SSH_CONNECT_TIMEOUT' }
    if ($Stderr -match 'Connection refused|No route to host|Network is unreachable') { return 'SSH_NETWORK_UNREACHABLE' }
    return 'SSH_CONNECTION_FAILED'
}

function Get-SshStrictArguments {
    param($Tools,[string]$PublicKeyPath,[string]$KnownHostsPath,[string]$Address,[string]$Command='true')
    $ip=$null
    Assert-Condition ([Net.IPAddress]::TryParse($Address,[ref]$ip) -and $ip.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork) 'SSH_ADDRESS_INVALID: Terraform output의 IPv4 주소를 사용하세요.'
    $known=[IO.Path]::GetFullPath($KnownHostsPath).Replace('\','/')
    Assert-Condition ($known -notmatch '["\r\n%$]') 'SSH_KNOWN_HOSTS_PATH_INVALID: 따옴표/개행/SSH 치환 문자가 없는 known_hosts 경로를 사용하세요.'
    # -F none excludes ambient ProxyCommand/IdentityAgent/LocalCommand settings.
    # The public key selects only its corresponding agent identity; the private
    # key/passphrase is never passed to a subprocess or copied into a report.
    return @('-F','none','-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','-o','IdentitiesOnly=yes','-o',"IdentityAgent=$($Tools.Agent)",'-o','PasswordAuthentication=no','-o','KbdInteractiveAuthentication=no','-o','PreferredAuthentications=publickey','-o','ConnectTimeout=15','-o','ConnectionAttempts=1','-o','ServerAliveInterval=15','-o','ServerAliveCountMax=2','-o','UpdateHostKeys=no','-o','GlobalKnownHostsFile=none','-o',('UserKnownHostsFile="'+$known+'"'),'-i',[IO.Path]::GetFullPath($PublicKeyPath),"ubuntu@$Address",$Command)
}

function Test-SshReadiness {
    param([Parameter(Mandatory)][string]$SshPrivateKeyPath,[string]$ExpectedPublicKeyPath,[string]$Address,[string]$KnownHostsPath=(Join-Path $HOME '.ssh/known_hosts'))
    $tools=Get-WindowsSshToolchain
    Assert-Condition (Test-Path -LiteralPath $SshPrivateKeyPath -PathType Leaf) 'SSH_KEY_MISSING: 지정한 개인키가 없습니다. 키를 새로 덮어쓰지 말고 원래 키 경로를 확인하세요.'
    $publicPath="$SshPrivateKeyPath.pub"
    Assert-Condition (Test-Path -LiteralPath $publicPath -PathType Leaf) 'SSH_PUBLIC_KEY_MISSING: 개인키 옆의 .pub 파일이 필요합니다. 기존 공개키와 경로를 확인하세요.'
    $fingerprintResult=Invoke-NativeTool -FilePath $tools.Keygen -Arguments @('-l','-E','sha256','-f',$publicPath) -TimeoutSeconds 30
    $fingerprints=@(Get-SshFingerprint $fingerprintResult.Stdout)
    Assert-Condition ($fingerprints.Count -eq 1) 'SSH_PUBLIC_KEY_INVALID: 공개키 지문을 하나로 확인할 수 없습니다.'
    $fingerprint=$fingerprints[0]
    if ($ExpectedPublicKeyPath) {
        $expected=Invoke-NativeTool -FilePath $tools.Keygen -Arguments @('-l','-E','sha256','-f',$ExpectedPublicKeyPath) -TimeoutSeconds 30
        $expectedFingerprints=@(Get-SshFingerprint $expected.Stdout)
        Assert-Condition ($expectedFingerprints.Count -eq 1 -and $expectedFingerprints[0] -ceq $fingerprint) 'SSH_CONFIG_KEY_MISMATCH: config.json의 ssh_public_key_path와 선택한 키의 지문이 다릅니다.'
    }
    $agent=Invoke-NativeTool -FilePath $tools.Add -Arguments @('-l','-E','sha256') -AcceptedExitCodes @(0,1,2) -TimeoutSeconds 30
    Assert-Condition ($agent.ExitCode -ne 2) 'SSH_AGENT_UNREACHABLE: 동일 Windows OpenSSH의 ssh-add가 agent에 연결할 수 없습니다. 서비스와 현재 사용자/세션을 확인하세요.'
    Assert-Condition ($agent.ExitCode -eq 0) 'SSH_AGENT_NO_KEYS: 일반 사용자 PowerShell에서 Windows OpenSSH ssh-add.exe에 개인키를 직접 등록하고 passphrase를 대화형 입력하세요.'
    Assert-Condition ($fingerprint -cin @(Get-SshFingerprint $agent.Stdout)) 'SSH_AGENT_KEY_MISSING: 선택한 공개키의 지문이 ssh-add -l에 없습니다. 동일 사용자로 해당 개인키를 등록하세요.'
    $result=@{status='PASS';local_agent='PASS';connection='NOT_RUN';client=$tools.Ssh;path_client=$tools.PathClient;agent='Windows ssh-agent service';fingerprint=$fingerprint;public_key_path=[IO.Path]::GetFullPath($publicPath);known_hosts_path=[IO.Path]::GetFullPath($KnownHostsPath)}
    if ($Address) {
        Assert-Condition (Test-Path -LiteralPath $KnownHostsPath -PathType Leaf) 'SSH_KNOWN_HOSTS_MISSING: OCI 콘솔/serial console에서 서버 지문을 독립 확인한 뒤 known_hosts에 등록하세요.'
        $known=Invoke-NativeTool -FilePath $tools.Keygen -Arguments @('-F',$Address,'-f',$KnownHostsPath) -AcceptedExitCodes @(0,1) -TimeoutSeconds 30
        Assert-Condition ($known.ExitCode -eq 0) 'SSH_HOST_KEY_UNKNOWN: 이 IP의 신뢰한 host key가 known_hosts에 없습니다. 독립 확인 후 등록해야 합니다.'
        $arguments=Get-SshStrictArguments $tools $publicPath $KnownHostsPath $Address 'true'
        $connection=Invoke-NativeTool -FilePath $tools.Ssh -Arguments $arguments -AcceptedExitCodes @(0,255) -TimeoutSeconds 30
        if ($connection.ExitCode -ne 0) { throw "$(Get-SshFailureCode $connection.Stderr): known_hosts 독립 대조, agent의 키, ubuntu 사용자, 현재 공인 IP/NSG를 확인하세요. 기존 키를 삭제하거나 StrictHostKeyChecking을 끄지 마세요." }
        $result.connection='PASS'
    }
    return $result
}

Export-ModuleMember -Function Assert-WindowsSshAgentState,Get-WindowsSshToolchain,Get-SshFingerprint,Get-SshFailureCode,Get-SshStrictArguments,Test-SshReadiness
