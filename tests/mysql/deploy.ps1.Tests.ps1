﻿Param (
    [switch]$Batch
)

if ($PSScriptRoot) { $commandName = $MyInvocation.MyCommand.Name.Replace(".Tests.ps1", ""); $here = $PSScriptRoot }
else { $commandName = "_ManualExecution"; $here = (Get-Item . ).FullName }
$testRoot = (Get-Item $here\.. ).FullName

if (!$Batch) {
    # Is not a part of the global batch => import module
    #Explicitly import the module for testing
    Import-Module "$testRoot\..\dbops.psd1" -Force; Get-DBOModuleFileList -Type internal | ForEach-Object { . $_.FullName }
}
else {
    # Is a part of a batch, output some eye-catching happiness
    Write-Host "Running $commandName tests" -ForegroundColor Cyan
}

. "$testRoot\constants.ps1"

$workFolder = Join-PSFPath -Normalize "$testRoot\etc" "$commandName.Tests.dbops"
$unpackedFolder = Join-PSFPath -Normalize $workFolder 'unpacked'
$logTable = "testdeploymenthistory"
$cleanupScript = Join-PSFPath -Normalize "$testRoot\etc\mysql-tests\Cleanup.sql"
$v1scripts = Join-PSFPath -Normalize "$testRoot\etc\mysql-tests\success\1.sql"
$v1Journal = Get-Item $v1scripts | ForEach-Object { '1.0\' + $_.Name }
$verificationScript = Join-PSFPath -Normalize "$testRoot\etc\mysql-tests\verification\select.sql"
$packageName = Join-PSFPath -Normalize $workFolder 'TempDeployment.zip'
$newDbName = "test_dbops_deployps1"

Describe "deploy.ps1 integration tests" -Tag $commandName, IntegrationTests {
    BeforeAll {
        if ((Test-Path $workFolder) -and $workFolder -like '*.Tests.dbops') { Remove-Item $workFolder -Recurse }
        $null = New-Item $workFolder -ItemType Directory -Force
        $null = New-Item $unpackedFolder -ItemType Directory -Force
        $packageName = New-DBOPackage -Path $packageName -ScriptPath $v1scripts -Build 1.0 -Force
        $null = Expand-Archive -Path $packageName -DestinationPath $workFolder -Force
        $dropDatabaseScript = 'DROP DATABASE IF EXISTS `{0}`' -f $newDbName
        $createDatabaseScript = 'CREATE DATABASE IF NOT EXISTS `{0}`' -f $newDbName
        $null = Invoke-DBOQuery -Type MySQL -SqlInstance $script:mysqlInstance -Silent -Credential $script:mysqlCredential -Database mysql -Query $dropDatabaseScript, $createDatabaseScript
    }
    AfterAll {
        $null = Invoke-DBOQuery -Type MySQL -SqlInstance $script:mysqlInstance -Silent -Credential $script:mysqlCredential -Database mysql -Query $dropDatabaseScript
        if ((Test-Path $workFolder) -and $workFolder -like '*.Tests.dbops') { Remove-Item $workFolder -Recurse }
    }
    Context "testing deployment of extracted package" {
        BeforeEach {
            $null = Invoke-DBOQuery -Type MySQL -SqlInstance $script:mysqlInstance -Silent -Credential $script:mysqlCredential -Database mysql -Query $dropDatabaseScript, $createDatabaseScript
        }
        It "should deploy with a -Configuration parameter" {
            $deploymentConfig = @{
                SqlInstance        = $script:mysqlInstance
                Credential         = $script:mysqlCredential
                Database           = $newDbName
                SchemaVersionTable = $logTable
                Silent             = $true
                DeploymentMethod   = 'NoTransaction'
            }
            $testResults = & $workFolder\deploy.ps1 -Type MySQL -Configuration $deploymentConfig
            $testResults.Successful | Should Be $true
            $testResults.Scripts.Name | Should Be $v1Journal
            $testResults.SqlInstance | Should Be $script:mysqlInstance
            $testResults.Database | Should Be $newDbName
            $testResults.SourcePath | Should Be $workFolder
            $testResults.ConnectionType | Should Be 'MySQL'
            $testResults.Configuration.SchemaVersionTable | Should Be $logTable
            $testResults.Error | Should BeNullOrEmpty
            $testResults.Duration.TotalMilliseconds | Should -BeGreaterOrEqual 0
            $testResults.StartTime | Should Not BeNullOrEmpty
            $testResults.EndTime | Should Not BeNullOrEmpty
            $testResults.EndTime | Should -BeGreaterOrEqual $testResults.StartTime
            'Upgrade successful' | Should BeIn $testResults.DeploymentLog

            #Verifying objects
            $testResults = Invoke-DBOQuery -Type MySQL -SqlInstance $script:mysqlInstance -Silent -Credential $script:mysqlCredential -Database $newDbName -InputFile $verificationScript
            $logTable | Should BeIn $testResults.name
            'a' | Should BeIn $testResults.name
            'b' | Should BeIn $testResults.name
            'c' | Should Not BeIn $testResults.name
            'd' | Should Not BeIn $testResults.name
        }
        It "should deploy with a set of parameters" {
            $testResults = & $workFolder\deploy.ps1 -Type MySQL -SqlInstance $script:mysqlInstance -Credential $script:mysqlCredential -Database $newDbName -SchemaVersionTable $logTable -OutputFile "$workFolder\log.txt" -Silent
            $testResults.Successful | Should Be $true
            $testResults.Scripts.Name | Should Be $v1Journal
            $testResults.SqlInstance | Should Be $script:mysqlInstance
            $testResults.Database | Should Be $newDbName
            $testResults.SourcePath | Should Be $workFolder
            $testResults.ConnectionType | Should Be 'MySQL'
            $testResults.Configuration.SchemaVersionTable | Should Be $logTable
            $testResults.Error | Should BeNullOrEmpty
            $testResults.Duration.TotalMilliseconds | Should -BeGreaterOrEqual 0
            $testResults.StartTime | Should Not BeNullOrEmpty
            $testResults.EndTime | Should Not BeNullOrEmpty
            $testResults.EndTime | Should -BeGreaterOrEqual $testResults.StartTime
            'Upgrade successful' | Should BeIn $testResults.DeploymentLog

            #Verifying objects
            $testResults = Invoke-DBOQuery -Type MySQL -SqlInstance $script:mysqlInstance -Silent -Credential $script:mysqlCredential -Database $newDbName -InputFile $verificationScript
            $logTable | Should BeIn $testResults.name
            'a' | Should BeIn $testResults.name
            'b' | Should BeIn $testResults.name
            'c' | Should Not BeIn $testResults.name
            'd' | Should Not BeIn $testResults.name
        }
    }
    Context  "$commandName whatif tests" {
        BeforeAll {
            $null = Invoke-DBOQuery -Type MySQL -SqlInstance $script:mysqlInstance -Silent -Credential $script:mysqlCredential -Database mysql -Query $dropDatabaseScript, $createDatabaseScript
        }
        AfterAll {
        }
        It "should deploy nothing" {
            $testResults = & $workFolder\deploy.ps1 -Type MySQL -SqlInstance $script:mysqlInstance -Credential $script:mysqlCredential -Database $newDbName -SchemaVersionTable $logTable -OutputFile "$workFolder\log.txt" -Silent -WhatIf
            $testResults.Successful | Should Be $true
            $testResults.Scripts.Name | Should Be $v1Journal
            $testResults.SqlInstance | Should Be $script:mysqlInstance
            $testResults.Database | Should Be $newDbName
            $testResults.SourcePath | Should Be $workFolder
            $testResults.ConnectionType | Should Be 'MySQL'
            $testResults.Configuration.SchemaVersionTable | Should Be $logTable
            $testResults.Error | Should BeNullOrEmpty
            $testResults.Duration.TotalMilliseconds | Should -BeGreaterOrEqual 0
            $testResults.StartTime | Should Not BeNullOrEmpty
            $testResults.EndTime | Should Not BeNullOrEmpty
            $testResults.EndTime | Should -BeGreaterOrEqual $testResults.StartTime
            "No deployment performed - WhatIf mode." | Should BeIn $testResults.DeploymentLog
            $v1Journal | ForEach-Object { "$_ would have been executed - WhatIf mode." } | Should BeIn $testResults.DeploymentLog

            #Verifying objects
            $testResults = Invoke-DBOQuery -Type MySQL -SqlInstance $script:mysqlInstance -Silent -Credential $script:mysqlCredential -Database $newDbName -InputFile $verificationScript
            $logTable | Should Not BeIn $testResults.name
            'a' | Should Not BeIn $testResults.name
            'b' | Should Not BeIn $testResults.name
            'c' | Should Not BeIn $testResults.name
            'd' | Should Not BeIn $testResults.name
        }
    }
}
