#requires -Version 7.2
[CmdletBinding()]
param([switch]$AsJson)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
# Read-only: no installers, registry/PATH edits, service starts or account queries.
$specs=@(
    @{name='pwsh';args=@('-NoProfile','-Command','$PSVersionTable.PSVersion.ToString()');pattern='(?m)^\d+\.\d+\.\d+(?:\.\d+)?\r?$';required=$true;url='https://learn.microsoft.com/en-us/powershell/scripting/install/install-powershell-on-windows'},
    @{name='terraform';args=@('version');pattern='Terraform v(\d+\.\d+\.\d+)';required=$true;url='https://developer.hashicorp.com/terraform/install'},
    @{name='oci';args=@('--version');pattern='(?m)^\d+\.\d+\.\d+\r?$';required=$true;url='https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm'},
    @{name='ssh';args=@('-V');pattern='OpenSSH[^\r\n]{0,120}';required=$true;url='https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh_install_firstuse'},
    @{name='mysql';args=@('--version');pattern='(?im)mysql[^\r\n]{0,160}';required=$false;url='https://dev.mysql.com/doc/refman/8.4/en/windows-installation.html'}
)
$checks=@()
foreach ($spec in $specs) {
    $paths=@(Get-Command $spec.name -CommandType Application -All -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -Unique)
    $selected=if ($spec.name -eq 'ssh' -and $IsWindows) { Join-Path $env:SystemRoot 'System32/OpenSSH/ssh.exe' } elseif ($paths.Count) { $paths[0] } else { $null }
    $row=[ordered]@{tool=$spec.name;required_for_infrastructure=$spec.required;status='MISSING';selected_path=$selected;path_candidates=$paths;version=$null;install_url=$spec.url;action='docs/TOOLS_WINDOWS.md에서 이 도구의 절차를 진행하세요. PASS 도구는 다시 설치하지 않습니다.'}
    if ($selected -and (Test-Path -LiteralPath $selected -PathType Leaf)) {
        $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=$selected;$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
        foreach ($item in $spec.args) { $start.ArgumentList.Add($item) }
        $process=[Diagnostics.Process]::new();$process.StartInfo=$start
        try {
            [void]$process.Start();$out=$process.StandardOutput.ReadToEndAsync();$err=$process.StandardError.ReadToEndAsync()
            if (-not $process.WaitForExit(10000)) { $process.Kill($true);$process.WaitForExit();$row.status='TIMEOUT';$row.action='버전 조회 10초 초과. 설치/실행 경로를 확인하세요.' }
            else {
                $raw=$out.GetAwaiter().GetResult()+"`n"+$err.GetAwaiter().GetResult()
                if ($process.ExitCode -eq 0 -and $raw -match $spec.pattern) {
                    $row.version=$Matches[0].Trim();$row.status='PASS';$row.action='정상'
                    if ($spec.name -eq 'terraform' -and ([version]$Matches[1] -lt [version]'1.9.0' -or [version]$Matches[1] -ge [version]'2.0.0')) { $row.status='UNSUPPORTED';$row.action='Terraform >=1.9,<2 필요. 기존 State/provider lock을 보존하고 버전을 선택하세요.' }
                    if ($spec.name -eq 'oci' -and $row.version -ne '3.94.0') { $row.status='UNSUPPORTED';$row.action='정상 빈 목록 계약을 검증한 OCI CLI 3.94.0이 필요합니다. 기존 설치를 보존하고 해당 버전을 별도 준비하세요.' }
                    if ($spec.name -eq 'pwsh' -and [version]$row.version -lt [version]'7.2.0') { $row.status='UNSUPPORTED';$row.action='PowerShell 7.2 이상 필요' }
                } else { $row.status='VERSION_UNCONFIRMED';$row.action='공식 실행 파일인지 확인하세요. 버전 조회 원문은 출력하지 않았습니다.' }
            }
        } catch { $row.status='EXECUTION_FAILED';$row.action='선택한 실행 파일의 접근/실행 권한을 확인하세요. 전체 예외는 출력하지 않았습니다.' }
        finally { $process.Dispose() }
        if ($paths.Count -gt 1) { $row.action+=' PATH에 여러 설치가 있습니다. selected_path와 path_candidates를 비교하세요.' }
        if ($spec.name -eq 'ssh' -and $paths.Count -and $paths[0] -ne $selected) { $row.action+=' PATH SSH와 Windows OpenSSH가 다릅니다. Verify는 위 Windows 경로를 사용합니다.' }
    }
    $checks+=[pscustomobject]$row
}
$summary=[ordered]@{kind='ACTUAL_LOCAL_READ_ONLY';checked_at=[datetimeoffset]::UtcNow.ToString('o');infrastructure_ready=(@($checks | Where-Object { $_.required_for_infrastructure -and $_.status -ne 'PASS' }).Count -eq 0);database_client_ready=(@($checks | Where-Object { $_.tool -eq 'mysql' -and $_.status -eq 'PASS' }).Count -eq 1);checks=$checks;live_account='NOT_RUN';installation_changes='NONE'}
if ($AsJson) { $summary | ConvertTo-Json -Depth 8 } else {
    $checks | Format-Table tool,status,version,selected_path -AutoSize
    foreach ($check in $checks) { Write-Host "$($check.tool): $($check.action)"; if ($check.status -ne 'PASS') { Write-Host $check.install_url } }
    Write-Host ('설치 안내: ' + [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../docs/TOOLS_WINDOWS.md')))
    Write-Host '설치/PATH/서비스/키/OCI 설정 변경 없음. mysql은 DB 단계 전 필요. PATH 변경 후 새 창을 열고 재검사하세요.'
}
