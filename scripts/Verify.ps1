#requires -Version 7.2
[CmdletBinding()]
param([string]$Environment='dev',[string]$SshPrivateKeyPath,[string]$KnownHostsPath=(Join-Path $HOME '.ssh/known_hosts'),[switch]$CheckExternalPorts)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/Common.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/Ssh.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/Verification.psm1') -Force -DisableNameChecking
$context=Get-TaskContext $Environment
Assert-Condition (Test-Path -LiteralPath $context.Directory -PathType Container) 'Init-Config.ps1로 환경을 먼저 준비하세요.'
$report=@{status='NOT_RUN';checked_at=[datetimeoffset]::UtcNow.ToString('o');target=@{};checks=@();mysql=@{status='NOT_RUN'};autonomous=@{status='NOT_RUN';wallet='NOT_RUN';database_connection='NOT_RUN';resources=@()};database_tls_and_grants='NOT_RUN';second_plan='NOT_RUN';billing='NOT_RUN';failure_stage=$null}
$stage='configuration'; $currentCheck=$null
function Test-TcpReachable([string]$Address,[int]$Port) {
    $client=[Net.Sockets.TcpClient]::new()
    try { $task=$client.ConnectAsync($Address,$Port);return ($task.Wait(3000) -and $client.Connected) } catch { return $false } finally { $client.Dispose() }
}
try {
    $settings=Read-JsonFile $context.Config
    $identity=Get-ProfileIdentity $settings.oci_profile
    $report.target=@{tenancy_ocid=$identity.Tenancy;region=$settings.region;compartment_ocid=$settings.compartment_ocid}
    $report.autonomous=New-AutonomousVerification $settings.autonomous_databases @{} $identity.Tenancy $settings.region $settings.compartment_ocid
    $stage='terraform-output'
    Initialize-Terraform $context
    $result=Invoke-NativeTool -FilePath terraform -WorkingDirectory $context.Root -Arguments @('output','-json') -TimeoutSeconds 120
    $outputs=$result.Stdout | ConvertFrom-Json -AsHashtable -Depth 100
    $deployment=$outputs.deployment.value
    $stage='deployment-target'
    Assert-Condition ($deployment.tenancy_ocid -eq $identity.Tenancy -and $deployment.region -eq $settings.region -and $deployment.compartment_ocid -eq $settings.compartment_ocid) 'State의 계정/리전/compartment가 현재 설정과 다릅니다.'
    $report.target=$deployment
    $adbOutputs=@{}
    if ($outputs.ContainsKey('autonomous_databases') -and $null -ne $outputs.autonomous_databases.value) { $adbOutputs=$outputs.autonomous_databases.value }
    $report.autonomous=New-AutonomousVerification $settings.autonomous_databases $adbOutputs $identity.Tenancy $settings.region $settings.compartment_ocid
    $stage='autonomous-output-set'
    Assert-AutonomousOutputSet $settings.autonomous_databases $adbOutputs
    # Query the enabled option before SSH, even when the local agent is unready.
    foreach ($entry in $report.autonomous.resources) {
        $stage="autonomous-api:$($entry.name)"; $currentCheck=$entry
        $entry.api_query='FAIL'; $entry.status='FAIL'
        $db=$adbOutputs[$entry.name]
        $entry.id=$db.id
        $live=Invoke-OciJson -Identity $identity -Region $settings.region -Arguments @('db','autonomous-database','get','--autonomous-database-id',$db.id)
        $entry.api_query='PASS'
        $checked=Test-AutonomousLiveResponse $live $settings.autonomous_databases[$entry.name] $db.id $settings.compartment_ocid
        foreach ($field in $checked.Keys) { $entry[$field]=$checked[$field] }
        Assert-Condition ($entry.status -eq 'PASS') "Autonomous 무료/대상/보안 조회 검증 실패. verification.json failed_checks를 확인하세요: $($entry.name)"
        $currentCheck=$null
    }
    if ($report.autonomous.resources.Count -gt 0) { $report.autonomous.status='PASS' }
    foreach ($key in $outputs.servers.value.Keys) {
        $server=$outputs.servers.value[$key]
        $finding=@{server=$key;status='NOT_RUN';api_query='NOT_RUN';ssh_agent='NOT_RUN';ssh_connection='NOT_RUN';ssh_cloud_init_docker='NOT_RUN';firewall_and_listeners='NOT_RUN';external_ports='NOT_RUN'}
        $report.checks+=,$finding; $currentCheck=$finding; $stage="vm-api:$key"
        $finding.api_query='FAIL'
        $live=Invoke-OciJson -Identity $identity -Region $settings.region -Arguments @('compute','instance','get','--instance-id',$server.id)
        Assert-Condition ($live.id -eq $server.id -and $live['compartment-id'] -eq $settings.compartment_ocid -and $live.shape -eq 'VM.Standard.E2.1.Micro' -and $live['lifecycle-state'] -eq 'RUNNING') 'VM 대상/무료 shape/RUNNING 확인 실패.'
        $finding.api_query='PASS'
        Write-Host "$key $($server.id) public=$($server.public_ip) private=$($server.private_ip)"
        if ($SshPrivateKeyPath) {
            $stage="ssh-readiness:$key"; $finding.ssh_connection='FAIL'
            $ready=Test-SshReadiness -SshPrivateKeyPath $SshPrivateKeyPath -ExpectedPublicKeyPath $settings.ssh_public_key_path -Address $server.public_ip -KnownHostsPath $KnownHostsPath
            $finding.ssh_agent=$ready.local_agent; $finding.ssh_connection=$ready.connection
            $stage="ssh-os-docker:$key"; $finding.ssh_cloud_init_docker='FAIL'
            $tools=Get-WindowsSshToolchain
            $command='cloud-init status --wait && sudo -n test -f /var/lib/oci-free-template/bootstrap-complete && systemctl is-enabled docker && systemctl is-active docker && sudo -n docker version --format ''{{.Server.Version}}'' && sudo -n docker compose version && sudo -n iptables -S && sudo -n iptables -S DOCKER-USER && sudo -n ss -lnt'
            $arguments=Get-SshStrictArguments $tools $ready.public_key_path $KnownHostsPath $server.public_ip $command
            $ssh=Invoke-NativeTool -FilePath $tools.Ssh -Arguments $arguments -TimeoutSeconds 300
            Write-Host $ssh.Stdout
            $finding.ssh_cloud_init_docker='PASS'; $finding.firewall_and_listeners='REVIEW_OUTPUT'
        }
        if ($CheckExternalPorts) {
            $stage="external-ports:$key"; $finding.external_ports='FAIL'
            Assert-Condition (Test-TcpReachable $server.public_ip 22) '공인 IP의 SSH 22 기준 접속을 확인할 수 없어 외부 포트 비노출 검증을 판정하지 않습니다.'
            foreach ($port in @(3306,6379,8080,8000)) { Assert-Condition (-not (Test-TcpReachable $server.public_ip $port)) "인터넷에서 $key 의 $port 포트로 연결되었습니다. 노출 검증 실패." }
            $finding.external_ports='PASS: observer could reach SSH22 but not TCP3306/6379/8080/8000; review NSG/OS/Docker rules too'
        }
        $finding.status='PASS'; $currentCheck=$null
    }
    $stage='mysql-api'; $currentCheck=$report.mysql
    if ($outputs.ContainsKey('mysql') -and $null -ne $outputs.mysql.value) {
        $db=$outputs.mysql.value; $report.mysql.status='FAIL'
        $live=Invoke-OciJson -Identity $identity -Region $settings.region -Arguments @('mysql','db-system','get','--db-system-id',$db.id)
        Assert-Condition ($live.id -eq $db.id -and $live['compartment-id'] -eq $settings.compartment_ocid -and $live['shape-name'] -eq 'MySQL.Free' -and $live['lifecycle-state'] -eq 'ACTIVE') 'MySQL 대상/MySQL.Free/ACTIVE 확인 실패.'
        $connection=@{environment=$Environment;tenancy_ocid=$identity.Tenancy;region=$settings.region;mysql_db_system_ocid=$db.id;mysql_hostname=$db.hostname;mysql_port=3306;admin_username=$db.admin_user;observed_mysql_version=$live['mysql-version']}
        $target=Join-Path $context.Directory 'connection.json'
        if (-not (Test-Path -LiteralPath $target)) { Write-PrivateJson $target $connection } else { Write-PrivateJson (Join-Path $context.Directory 'connection.observed.json') $connection }
        $report.mysql=@{status='PASS';id=$db.id;observed_mysql_version=$live['mysql-version']}
        Write-Host "MySQL private=$($db.private_ip) hostname=$($db.hostname) version=$($live['mysql-version'])"
    } else { $report.mysql.status='NOT_APPLICABLE' }
    $currentCheck=$null; $report.status='PASS'
} catch {
    $report.status='FAIL'; $report.failure_stage=$stage
    if ($null -ne $currentCheck) { $currentCheck.status='FAIL' }
    if ($stage -like 'autonomous-*') { $report.autonomous.status='FAIL' }
    # Persist structured checks, never native exception text or complete responses.
    throw
} finally {
    $report.checked_at=[datetimeoffset]::UtcNow.ToString('o')
    Write-PrivateJson (Join-Path $context.Directory 'verification.json') $report
}
Write-Host '읽기 전용 인프라 조회 완료. verification.json의 NOT_RUN/REVIEW_OUTPUT은 미검증입니다. TLS/서비스별 권한, Autonomous wallet/접속, 두 번째 plan, 청구는 별도로 확인하세요.'
