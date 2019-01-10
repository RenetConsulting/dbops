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
    Write-Host "Running MySQL $commandName tests" -ForegroundColor Cyan
}

. "$testRoot\constants.ps1"

$workFolder = Join-PSFPath -Normalize "$testRoot\etc" "$commandName.Tests.dbops"
$logTable = "testdeploymenthistory"
$cleanupScript = Join-PSFPath -Normalize "$testRoot\etc\mysql-tests\Cleanup.sql"
$v1scripts = Join-PSFPath -Normalize "$testRoot\etc\mysql-tests\success\1.sql"
$v1Journal = Get-Item $v1scripts | ForEach-Object { '1.0\' + $_.Name }
$v2scripts = Join-PSFPath -Normalize "$testRoot\etc\mysql-tests\success\2.sql"
$v2Journal = Get-Item $v2scripts | ForEach-Object { '2.0\' + $_.Name }
$verificationScript = Join-PSFPath -Normalize "$testRoot\etc\mysql-tests\verification\select.sql"

$newDbName = "test_dbops_RegisterDBOPackage"
$dropDatabaseScript = 'DROP DATABASE IF EXISTS `{0}`' -f $newDbName
$createDatabaseScript = 'CREATE DATABASE IF NOT EXISTS `{0}`' -f $newDbName

Describe "Register-DBOPackage MySQL integration tests" -Tag $commandName, IntegrationTests {
    BeforeAll {
        if ((Test-Path $workFolder) -and $workFolder -like '*.Tests.dbops') { Remove-Item $workFolder -Recurse }
        $null = New-Item $workFolder -ItemType Directory -Force
        $null = Invoke-DBOQuery -Type MySQL -SqlInstance $script:mysqlInstance -Silent -Credential $script:mysqlCredential -Database mysql -Query $dropDatabaseScript, $createDatabaseScript
    }
    AfterAll {
        if ((Test-Path $workFolder) -and $workFolder -like '*.Tests.dbops') { Remove-Item $workFolder -Recurse }
        $null = Invoke-DBOQuery -Type MySQL -SqlInstance $script:mysqlInstance -Silent -Credential $script:mysqlCredential -Database mysql -Query $dropDatabaseScript
    }
    Context "testing registration with CreateDatabase specified" {
        BeforeAll {
            $p1 = New-DBOPackage -ScriptPath $v1scripts -Name "$workFolder\pv1" -Build 1.0 -Force
            $p1 = Add-DBOBuild -ScriptPath $v2scripts -Package $p1 -Build 2.0
            $null = Invoke-DBOQuery -Type MySQL -SqlInstance $script:mysqlInstance -Silent -Credential $script:mysqlCredential -Database mysql -Query $dropDatabaseScript
        }
        It "should register version 1.0 in a new database using -CreateDatabase switch" {
            $testResults = Register-DBOPackage -Type MySQL $p1 -CreateDatabase -SqlInstance $script:mysqlInstance -Credential $script:mysqlCredential -Database $newDbName -SchemaVersionTable $logTable -Silent
            $testResults.Successful | Should Be $true
            $testResults.Scripts.Name | Should Be (@($v1Journal) + @($v2Journal))
            $testResults.SqlInstance | Should Be $script:mysqlInstance
            $testResults.Database | Should Be $newDbName
            $testResults.SourcePath | Should Be (Join-PSFPath -Normalize "$workFolder\pv1.zip")
            $testResults.ConnectionType | Should Be 'MySQL'
            $testResults.Configuration.SchemaVersionTable | Should Be $logTable
            $testResults.Configuration.CreateDatabase | Should Be $true
            $testResults.Error | Should BeNullOrEmpty
            $testResults.Duration.TotalMilliseconds | Should -BeGreaterOrEqual 0
            $testResults.StartTime | Should Not BeNullOrEmpty
            $testResults.EndTime | Should Not BeNullOrEmpty
            $testResults.EndTime | Should -BeGreaterOrEqual $testResults.StartTime
            $v1Journal | ForEach-Object { "$_ was registered in table $logtable" } | Should BeIn $testResults.DeploymentLog
            $v2Journal | ForEach-Object { "$_ was registered in table $logtable" } | Should BeIn $testResults.DeploymentLog
            "Created database $newDbName" | Should BeIn $testResults.DeploymentLog

            #Verifying objects
            $testResults = Invoke-DBOQuery -Type MySQL -SqlInstance $script:mysqlInstance -Silent -Credential $script:mysqlCredential -Database $newDbName -InputFile $verificationScript
            $logTable | Should BeIn $testResults.name
            'a' | Should Not BeIn $testResults.name
            'b' | Should Not BeIn $testResults.name
            'c' | Should Not BeIn $testResults.name
            'd' | Should Not BeIn $testResults.name

            #Verifying SchemaVersions table
            $testResults = Invoke-DBOQuery -Type MySQL -SqlInstance $script:mysqlInstance -Silent -Credential $script:mysqlCredential -Database $newDbName -Query "SELECT * FROM $logTable ORDER BY schemaversionid"
            $testResults.scriptname | Should Be (@($v1Journal) + @($v2Journal))
        }
    }
    Context "testing registration of scripts" {
        BeforeAll {
            $p2 = New-DBOPackage -ScriptPath $v1scripts -Name "$workFolder\pv2" -Build 1.0 -Force
            $p2 = Add-DBOBuild -ScriptPath $v2scripts -Package $p2 -Build 2.0
            $outputFile = "$workFolder\log.txt"
            $null = Invoke-DBOQuery -Type MySQL -SqlInstance $script:mysqlInstance -Silent -Credential $script:mysqlCredential -Database mysql -Query $dropDatabaseScript, $createDatabaseScript
        }
        It "should register version 1.0 without creating any objects" {
            $before = Invoke-DBOQuery -Type MySQL -SqlInstance $script:mysqlInstance -Silent -Credential $script:mysqlCredential -Database $newDbName -InputFile $verificationScript
            $rowsBefore = ($before | Measure-Object).Count
            $testResults = Register-DBOPackage -Type MySQL -Package $p2 -Build 1.0 -SqlInstance $script:mysqlInstance -Credential $script:mysqlCredential -Database $newDbName -SchemaVersionTable $logTable -Silent
            $testResults.Successful | Should Be $true
            $testResults.Scripts.Name | Should Be $v1Journal
            $testResults.SqlInstance | Should Be $script:mysqlInstance
            $testResults.Database | Should Be $newDbName
            $testResults.SourcePath | Should Be (Join-PSFPath -Normalize "$workFolder\pv2.zip")
            $testResults.ConnectionType | Should Be 'MySQL'
            $testResults.Configuration.SchemaVersionTable | Should Be $logTable
            $testResults.Error | Should BeNullOrEmpty
            $testResults.Duration.TotalMilliseconds | Should -BeGreaterOrEqual 0
            $testResults.StartTime | Should Not BeNullOrEmpty
            $testResults.EndTime | Should Not BeNullOrEmpty
            $testResults.EndTime | Should -BeGreaterOrEqual $testResults.StartTime
            $v1Journal | ForEach-Object { "$_ was registered in table $logtable" } | Should BeIn $testResults.DeploymentLog

            #Verifying objects
            $testResults = Invoke-DBOQuery -Type MySQL -SqlInstance $script:mysqlInstance -Silent -Credential $script:mysqlCredential -Database $newDbName -InputFile $verificationScript
            $logTable | Should BeIn $testResults.name
            'a' | Should Not BeIn $testResults.name
            'b' | Should Not BeIn $testResults.name
            'c' | Should Not BeIn $testResults.name
            'd' | Should Not BeIn $testResults.name
            ($testResults | Measure-Object).Count | Should Be ($rowsBefore + 1)

            #Verifying SchemaVersions table
            $testResults = Invoke-DBOQuery -Type MySQL -SqlInstance $script:mysqlInstance -Silent -Credential $script:mysqlCredential -Database $newDbName -Query "SELECT * FROM $logTable ORDER BY schemaversionid"
            $testResults.scriptname | Should Be $v1Journal
        }
        It "should register version 1.0 + 2.0 without creating any objects" {
            $before = Invoke-DBOQuery -Type MySQL -SqlInstance $script:mysqlInstance -Silent -Credential $script:mysqlCredential -Database $newDbName -InputFile $verificationScript
            $rowsBefore = ($before | Measure-Object).Count
            $testResults = Register-DBOPackage -Type MySQL -Package $p2 -SqlInstance $script:mysqlInstance -Credential $script:mysqlCredential -Database $newDbName -SchemaVersionTable $logTable -Silent
            $testResults.Successful | Should Be $true
            $testResults.Scripts.Name | Should Be $v2Journal
            $testResults.SqlInstance | Should Be $script:mysqlInstance
            $testResults.Database | Should Be $newDbName
            $testResults.SourcePath | Should Be (Join-PSFPath -Normalize "$workFolder\pv2.zip")
            $testResults.ConnectionType | Should Be 'MySQL'
            $testResults.Configuration.SchemaVersionTable | Should Be $logTable
            $testResults.Error | Should BeNullOrEmpty
            $testResults.Duration.TotalMilliseconds | Should -BeGreaterOrEqual 0
            $testResults.StartTime | Should Not BeNullOrEmpty
            $testResults.EndTime | Should Not BeNullOrEmpty
            $testResults.EndTime | Should -BeGreaterOrEqual $testResults.StartTime
            $v2Journal | ForEach-Object { "$_ was registered in table $logtable" } | Should BeIn $testResults.DeploymentLog

            #Verifying objects
            $testResults = Invoke-DBOQuery -Type MySQL -SqlInstance $script:mysqlInstance -Silent -Credential $script:mysqlCredential -Database $newDbName -InputFile $verificationScript
            $logTable | Should BeIn $testResults.name
            'a' | Should Not BeIn $testResults.name
            'b' | Should Not BeIn $testResults.name
            'c' | Should Not BeIn $testResults.name
            'd' | Should Not BeIn $testResults.name
            ($testResults | Measure-Object).Count | Should Be $rowsBefore

            #Verifying SchemaVersions table
            $testResults = Invoke-DBOQuery -Type MySQL -SqlInstance $script:mysqlInstance -Silent -Credential $script:mysqlCredential -Database $newDbName -Query "SELECT * FROM $logTable ORDER BY schemaversionid"
            $testResults.scriptname | Should Be (@($v1Journal) + @($v2Journal))
        }
    }
    Context  "$commandName whatif tests" {
        BeforeAll {
            $p1 = New-DBOPackage -ScriptPath $v1scripts -Name "$workFolder\pv1" -Build 1.0 -Force
            $null = Invoke-DBOQuery -Type MySQL -SqlInstance $script:mysqlInstance -Silent -Credential $script:mysqlCredential -Database mysql -Query $dropDatabaseScript, $createDatabaseScript
        }
        It "should deploy nothing" {
            $testResults = Register-DBOPackage -Type MySQL $p1 -SqlInstance $script:mysqlInstance -Credential $script:mysqlCredential -Database $newDbName -SchemaVersionTable $logTable -Silent -WhatIf
            $testResults.SqlInstance | Should Be $script:mysqlInstance
            $testResults.Database | Should Be $newDbName
            $testResults.SourcePath | Should Be $p1.FullName
            $testResults.ConnectionType | Should Be 'MySQL'
            $testResults.Configuration.SchemaVersionTable | Should Be $logTable
            $testResults.Error | Should BeNullOrEmpty
            $testResults.Duration.TotalMilliseconds | Should -BeGreaterOrEqual 0
            $testResults.StartTime | Should Not BeNullOrEmpty
            $testResults.EndTime | Should Not BeNullOrEmpty
            $testResults.EndTime | Should -BeGreaterOrEqual $testResults.StartTime
            "Running in WhatIf mode - no registration performed." | Should BeIn $testResults.DeploymentLog

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
