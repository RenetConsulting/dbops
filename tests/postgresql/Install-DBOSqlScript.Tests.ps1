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
$cleanupScript = Join-PSFPath -Normalize "$testRoot\etc\postgresql-tests\Cleanup.sql"
$tranFailScripts = Join-PSFPath -Normalize "$testRoot\etc\postgresql-tests\transactional-failure"
$v1scripts = Join-PSFPath -Normalize "$testRoot\etc\postgresql-tests\success\1.sql"
$v2scripts = Join-PSFPath -Normalize "$testRoot\etc\postgresql-tests\success\2.sql"
$verificationScript = Join-PSFPath -Normalize "$testRoot\etc\postgresql-tests\verification\select.sql"
$packageFileName = Join-PSFPath -Normalize $workFolder "dbops.package.json"
$cleanupPackageName = Join-PSFPath -Normalize "$testRoot\etc\TempCleanup.zip"
$outFile = Join-PSFPath -Normalize "$testRoot\etc\outLog.txt"
$newDbName = "test_dbops_installdbosqlscript"
$dropDatabaseScript = @(
    'SELECT pid, pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = ''{0}'' AND pid <> pg_backend_pid()' -f $newDbName
    'DROP DATABASE IF EXISTS {0}' -f $newDbName
)
$createDatabaseScript = 'CREATE DATABASE {0}' -f $newDbName

Describe "Install-DBOSqlScript PostgreSQL integration tests" -Tag $commandName, IntegrationTests {
    BeforeAll {
        if ((Test-Path $workFolder) -and $workFolder -like '*.Tests.dbops') { Remove-Item $workFolder -Recurse }
        $null = New-Item $workFolder -ItemType Directory -Force
        $null = Invoke-DBOQuery -Type PostgreSQL -SqlInstance $script:postgresqlInstance -Silent -Credential $script:postgresqlCredential -Database postgres -Query ($dropDatabaseScript + $createDatabaseScript)
    }
    AfterAll {
        if ((Test-Path $workFolder) -and $workFolder -like '*.Tests.dbops') { Remove-Item $workFolder -Recurse }
        $null = Invoke-DBOQuery -Type PostgreSQL -SqlInstance $script:postgresqlInstance -Silent -Credential $script:postgresqlCredential -Database postgres -Query $dropDatabaseScript
    }
    Context "testing regular deployment with CreateDatabase specified" {
        It "should deploy version 1.0 to a new database using -CreateDatabase switch" {
            # drop the database before installing the package
            $null = Invoke-DBOQuery -Type PostgreSQL -SqlInstance $script:postgresqlInstance -Silent -Credential $script:postgresqlCredential -Database postgres -Query $dropDatabaseScript
            $testResults = Install-DBOSqlScript -Type PostgreSQL -ScriptPath $v1scripts -CreateDatabase -SqlInstance $script:postgresqlInstance -Credential $script:postgresqlCredential -Database $newDbName -SchemaVersionTable $logTable -OutputFile "$workFolder\log.txt" -Silent
            $testResults.Successful | Should Be $true
            $testResults.Scripts.Name | Should Be (Resolve-Path $v1scripts).Path
            $testResults.SqlInstance | Should Be $script:postgresqlInstance
            $testResults.Database | Should Be $newDbName
            $testResults.SourcePath | Should Be $v1scripts
            $testResults.ConnectionType | Should Be 'PostgreSQL'
            $testResults.Configuration.SchemaVersionTable | Should Be $logTable
            $testResults.Configuration.CreateDatabase | Should Be $true
            $testResults.Error | Should BeNullOrEmpty
            $testResults.Duration.TotalMilliseconds | Should -BeGreaterOrEqual 0
            $testResults.StartTime | Should Not BeNullOrEmpty
            $testResults.EndTime | Should Not BeNullOrEmpty
            $testResults.EndTime | Should -BeGreaterOrEqual $testResults.StartTime
            'Upgrade successful' | Should BeIn $testResults.DeploymentLog
            "Created database $newDbName" | Should BeIn $testResults.DeploymentLog

            #Verifying objects
            $testResults = Invoke-DBOQuery -Type PostgreSQL -SqlInstance $script:postgresqlInstance -Silent -Credential $script:postgresqlCredential -Database $newDbName -InputFile $verificationScript
            $logTable | Should BeIn $testResults.name
            'a' | Should BeIn $testResults.name
            'b' | Should BeIn $testResults.name
            'c' | Should Not BeIn $testResults.name
            'd' | Should Not BeIn $testResults.name
        }
    }
    Context "testing transactional deployment of scripts" {
        BeforeEach {
            $null = Invoke-DBOQuery -Type PostgreSQL -SqlInstance $script:postgresqlInstance -Silent -Credential $script:postgresqlCredential -Database postgres -Query ($dropDatabaseScript + $createDatabaseScript)
        }
        It "Should throw an error and not create any objects" {
            #Running package
            { $null = Install-DBOSqlScript -Type PostgreSQL -Path $tranFailScripts -SqlInstance $script:postgresqlInstance -Credential $script:postgresqlCredential -Database $newDbName -SchemaVersionTable $logTable -DeploymentMethod SingleTransaction -Silent } | Should throw 'relation "a" already exists'
            #Verifying objects
            $testResults = Invoke-DBOQuery -Type PostgreSQL -SqlInstance $script:postgresqlInstance -Silent -Credential $script:postgresqlCredential -Database $newDbName -InputFile $verificationScript
            $logTable | Should -Not -BeIn $testResults.name
            'a' | Should -Not -BeIn $testResults.name
            'b' | Should -Not -BeIn $testResults.name
            'c' | Should -Not -BeIn $testResults.name
            'd' | Should -Not -BeIn $testResults.name
        }
    }
    Context "testing non transactional deployment of scripts" {
        BeforeAll {
            $null = Invoke-DBOQuery -Type PostgreSQL -SqlInstance $script:postgresqlInstance -Silent -Credential $script:postgresqlCredential -Database postgres -Query ($dropDatabaseScript + $createDatabaseScript)
        }
        It "Should throw an error and create one object" {
            #Running package
            { $null = Install-DBOSqlScript -Type PostgreSQL -Path $tranFailScripts -SqlInstance $script:postgresqlInstance -Credential $script:postgresqlCredential -Database $newDbName -SchemaVersionTable $logTable -DeploymentMethod NoTransaction -Silent } | Should throw 'relation "a" already exists'
            #Verifying objects
            $testResults = Invoke-DBOQuery -Type PostgreSQL -SqlInstance $script:postgresqlInstance -Silent -Credential $script:postgresqlCredential -Database $newDbName -InputFile $verificationScript
            $logTable | Should BeIn $testResults.name
            'a' | Should BeIn $testResults.name
            'b' | Should Not BeIn $testResults.name
            'c' | Should Not BeIn $testResults.name
            'd' | Should Not BeIn $testResults.name
        }
    }
    Context "testing script deployment" {
        BeforeAll {
            $null = Invoke-DBOQuery -Type PostgreSQL -SqlInstance $script:postgresqlInstance -Silent -Credential $script:postgresqlCredential -Database postgres -Query ($dropDatabaseScript + $createDatabaseScript)
        }
        It "should deploy version 1.0" {
            $testResults = Install-DBOSqlScript -Type PostgreSQL -ScriptPath $v1scripts -SqlInstance $script:postgresqlInstance -Credential $script:postgresqlCredential -Database $newDbName -SchemaVersionTable $logTable -Silent
            $testResults.Successful | Should Be $true
            $testResults.Scripts.Name | Should Be (Resolve-Path $v1scripts).Path
            $testResults.SqlInstance | Should Be $script:postgresqlInstance
            $testResults.Database | Should Be $newDbName
            $testResults.SourcePath | Should Be $v1scripts
            $testResults.ConnectionType | Should Be 'PostgreSQL'
            $testResults.Configuration.SchemaVersionTable | Should Be $logTable
            $testResults.Error | Should BeNullOrEmpty
            $testResults.Duration.TotalMilliseconds | Should -BeGreaterOrEqual 0
            $testResults.StartTime | Should Not BeNullOrEmpty
            $testResults.EndTime | Should Not BeNullOrEmpty
            $testResults.EndTime | Should -BeGreaterOrEqual $testResults.StartTime
            'Upgrade successful' | Should BeIn $testResults.DeploymentLog

            #Verifying objects
            $testResults = Invoke-DBOQuery -Type PostgreSQL -SqlInstance $script:postgresqlInstance -Silent -Credential $script:postgresqlCredential -Database $newDbName -InputFile $verificationScript
            $logTable | Should BeIn $testResults.name
            'a' | Should BeIn $testResults.name
            'b' | Should BeIn $testResults.name
            'c' | Should Not BeIn $testResults.name
            'd' | Should Not BeIn $testResults.name
        }
        It "should deploy version 2.0" {
            $testResults = Install-DBOSqlScript -Type PostgreSQL -ScriptPath $v2scripts -SqlInstance $script:postgresqlInstance -Credential $script:postgresqlCredential -Database $newDbName -SchemaVersionTable $logTable -Silent
            $testResults.Successful | Should Be $true
            $testResults.Scripts.Name | Should Be (Resolve-Path $v2scripts).Path
            $testResults.SqlInstance | Should Be $script:postgresqlInstance
            $testResults.Database | Should Be $newDbName
            $testResults.SourcePath | Should Be $v2scripts
            $testResults.ConnectionType | Should Be 'PostgreSQL'
            $testResults.Configuration.SchemaVersionTable | Should Be $logTable
            $testResults.Error | Should BeNullOrEmpty
            $testResults.Duration.TotalMilliseconds | Should -BeGreaterOrEqual 0
            $testResults.StartTime | Should Not BeNullOrEmpty
            $testResults.EndTime | Should Not BeNullOrEmpty
            $testResults.EndTime | Should -BeGreaterOrEqual $testResults.StartTime
            'Upgrade successful' | Should BeIn $testResults.DeploymentLog

            #Verifying objects
            $testResults = Invoke-DBOQuery -Type PostgreSQL -SqlInstance $script:postgresqlInstance -Silent -Credential $script:postgresqlCredential -Database $newDbName -InputFile $verificationScript
            $logTable | Should BeIn $testResults.name
            'a' | Should BeIn $testResults.name
            'b' | Should BeIn $testResults.name
            'c' | Should BeIn $testResults.name
            'd' | Should BeIn $testResults.name
        }
    }
    Context "testing deployment order" {
        BeforeAll {
            $null = Invoke-DBOQuery -Type PostgreSQL -SqlInstance $script:postgresqlInstance -Silent -Credential $script:postgresqlCredential -Database postgres -Query ($dropDatabaseScript + $createDatabaseScript)
        }
        It "should deploy 2.sql before 1.sql" {
            $testResults = Install-DBOSqlScript -Type PostgreSQL -ScriptPath $v2scripts, $v1scripts -SqlInstance $script:postgresqlInstance -Credential $script:postgresqlCredential -Database $newDbName -SchemaVersionTable $logTable -Silent
            $testResults.Successful | Should Be $true
            $testResults.Scripts.Name | Should Be (Resolve-Path $v2scripts, $v1scripts).Path
            $testResults.SqlInstance | Should Be $script:postgresqlInstance
            $testResults.Database | Should Be $newDbName
            $testResults.SourcePath | Should Be @($v2scripts, $v1scripts)
            $testResults.ConnectionType | Should Be 'PostgreSQL'
            $testResults.Configuration.SchemaVersionTable | Should Be $logTable
            $testResults.Error | Should BeNullOrEmpty
            $testResults.Duration.TotalMilliseconds | Should -BeGreaterOrEqual 0
            $testResults.StartTime | Should Not BeNullOrEmpty
            $testResults.EndTime | Should Not BeNullOrEmpty
            $testResults.EndTime | Should -BeGreaterOrEqual $testResults.StartTime
            'Upgrade successful' | Should BeIn $testResults.DeploymentLog

            #Verifying objects
            $testResults = Invoke-DBOQuery -Type PostgreSQL -SqlInstance $script:postgresqlInstance -Silent -Credential $script:postgresqlCredential -Database $newDbName -InputFile $verificationScript
            $logTable | Should BeIn $testResults.name
            'a' | Should BeIn $testResults.name
            'b' | Should BeIn $testResults.name
            'c' | Should BeIn $testResults.name
            'd' | Should BeIn $testResults.name
            #Verifying order
            $r1 = Invoke-DBOQuery -Type PostgreSQL -SqlInstance $script:postgresqlInstance -Silent -Credential $script:postgresqlCredential -Database $newDbName -Query "SELECT scriptname FROM $logtable ORDER BY schemaversionsid"
            $r1.scriptname | Should Be (Get-Item $v2scripts, $v1scripts).FullName
        }
    }
    Context "testing timeouts" {
        BeforeAll {
            $file = "$workFolder\delay.sql"
            'SELECT pg_sleep(3); SELECT ''Successful!'';' | Set-Content $file
        }
        BeforeEach {
            $null = Invoke-DBOQuery -Type PostgreSQL -SqlInstance $script:postgresqlInstance -Silent -Credential $script:postgresqlCredential -Database postgres -Query ($dropDatabaseScript + $createDatabaseScript)
        }
        It "should throw timeout error" {
            { $null = Install-DBOSqlScript -Type PostgreSQL -ScriptPath "$workFolder\delay.sql" -SqlInstance $script:postgresqlInstance -Credential $script:postgresqlCredential -Database $newDbName -SchemaVersionTable $logTable -OutputFile "$workFolder\log.txt" -Silent -ExecutionTimeout 2 } | Should throw 'Exception while reading from stream'
            $output = Get-Content "$workFolder\log.txt" -Raw
            $output | Should BeLike "*Unable to read data from the transport connection*"
            $output | Should Not BeLike '*Successful!*'
        }
        It "should successfully run within specified timeout" {
            $testResults = Install-DBOSqlScript -Type PostgreSQL -ScriptPath "$workFolder\delay.sql" -SqlInstance $script:postgresqlInstance -Credential $script:postgresqlCredential -Database $newDbName -SchemaVersionTable $logTable -OutputFile "$workFolder\log.txt" -Silent -ExecutionTimeout 6
            $testResults.Successful | Should Be $true
            $testResults.Scripts.Name | Should Be (Join-PSFPath -Normalize "$workFolder\delay.sql")
            $testResults.SqlInstance | Should Be $script:postgresqlInstance
            $testResults.Database | Should Be $newDbName
            $testResults.SourcePath | Should Be (Join-PSFPath -Normalize "$workFolder\delay.sql")
            $testResults.ConnectionType | Should Be 'PostgreSQL'
            $testResults.Configuration.SchemaVersionTable | Should Be $logTable
            $testResults.Error | Should BeNullOrEmpty
            $testResults.Duration.TotalMilliseconds | Should -BeGreaterThan 3000
            $testResults.StartTime | Should Not BeNullOrEmpty
            $testResults.EndTime | Should Not BeNullOrEmpty
            $testResults.EndTime | Should -BeGreaterThan $testResults.StartTime

            $output = Get-Content "$workFolder\log.txt" -Raw
            $output | Should Not BeLike '*Unable to read data from the transport connection*'
            $output | Should BeLike '*Successful!*'
        }
        It "should successfully run with infinite timeout" {
            $testResults = Install-DBOSqlScript -Type PostgreSQL -ScriptPath "$workFolder\delay.sql" -SqlInstance $script:postgresqlInstance -Credential $script:postgresqlCredential -Database $newDbName -SchemaVersionTable $logTable -OutputFile "$workFolder\log.txt" -Silent -ExecutionTimeout 0
            $testResults.Successful | Should Be $true
            $testResults.Scripts.Name | Should Be (Join-PSFPath -Normalize "$workFolder\delay.sql")
            $testResults.SqlInstance | Should Be $script:postgresqlInstance
            $testResults.Database | Should Be $newDbName
            $testResults.SourcePath | Should Be (Join-PSFPath -Normalize "$workFolder\delay.sql")
            $testResults.ConnectionType | Should Be 'PostgreSQL'
            $testResults.Configuration.SchemaVersionTable | Should Be $logTable
            $testResults.Error | Should BeNullOrEmpty
            $testResults.Duration.TotalMilliseconds | Should -BeGreaterOrEqual 0
            $testResults.StartTime | Should Not BeNullOrEmpty
            $testResults.EndTime | Should Not BeNullOrEmpty
            $testResults.EndTime | Should -BeGreaterOrEqual $testResults.StartTime
            'Upgrade successful' | Should BeIn $testResults.DeploymentLog

            $output = Get-Content "$workFolder\log.txt" -Raw
            $output | Should Not BeLike "*Unable to read data from the transport connection*"
            $output | Should BeLike '*Successful!*'
        }
    }
    Context  "$commandName whatif tests" {
        BeforeAll {
            $null = Invoke-DBOQuery -Type PostgreSQL -SqlInstance $script:postgresqlInstance -Silent -Credential $script:postgresqlCredential -Database postgres -Query ($dropDatabaseScript + $createDatabaseScript)
        }
        AfterAll {
        }
        It "should deploy nothing" {
            $testResults = Install-DBOSqlScript -Type PostgreSQL -ScriptPath $v1scripts -SqlInstance $script:postgresqlInstance -Credential $script:postgresqlCredential -Database $newDbName -SchemaVersionTable $logTable -Silent -WhatIf
            $testResults.Successful | Should Be $true
            $testResults.Scripts.Name | Should Be $v1scripts
            $testResults.SqlInstance | Should Be $script:postgresqlInstance
            $testResults.Database | Should Be $newDbName
            $testResults.SourcePath | Should Be $v1scripts
            $testResults.ConnectionType | Should Be 'PostgreSQL'
            $testResults.Configuration.SchemaVersionTable | Should Be $logTable
            $testResults.Error | Should BeNullOrEmpty
            $testResults.Duration.TotalMilliseconds | Should -BeGreaterOrEqual 0
            $testResults.StartTime | Should Not BeNullOrEmpty
            $testResults.EndTime | Should Not BeNullOrEmpty
            $testResults.EndTime | Should -BeGreaterOrEqual $testResults.StartTime
            "No deployment performed - WhatIf mode." | Should BeIn $testResults.DeploymentLog
            "$v1scripts would have been executed - WhatIf mode." | Should BeIn $testResults.DeploymentLog

            #Verifying objects
            $testResults = Invoke-DBOQuery -Type PostgreSQL -SqlInstance $script:postgresqlInstance -Silent -Credential $script:postgresqlCredential -Database $newDbName -InputFile $verificationScript
            $logTable | Should Not BeIn $testResults.name
            'a' | Should Not BeIn $testResults.name
            'b' | Should Not BeIn $testResults.name
            'c' | Should Not BeIn $testResults.name
            'd' | Should Not BeIn $testResults.name
        }
    }
    Context "testing deployment without specifying SchemaVersion table" {
        BeforeAll {
            $null = Invoke-DBOQuery -Type PostgreSQL -SqlInstance $script:postgresqlInstance -Silent -Credential $script:postgresqlCredential -Database postgres -Query ($dropDatabaseScript + $createDatabaseScript)
        }
        AfterAll {
            $null = Invoke-DBOQuery -Type PostgreSQL -SqlInstance $script:postgresqlInstance -Silent -Credential $script:postgresqlCredential -Database $newDbName -Query "DROP TABLE IF EXISTS SchemaVersions"
        }
        It "should deploy version 1.0" {
            $before = Invoke-DBOQuery -Type PostgreSQL -SqlInstance $script:postgresqlInstance -Silent -Credential $script:postgresqlCredential -Database $newDbName -InputFile $verificationScript
            $rowsBefore = ($before | Measure-Object).Count
            $testResults = Install-DBOSqlScript -Type PostgreSQL -ScriptPath $v1scripts -SqlInstance $script:postgresqlInstance -Credential $script:postgresqlCredential -Database $newDbName -Silent
            $testResults.Successful | Should Be $true
            $testResults.Scripts.Name | Should Be (Resolve-Path $v1scripts).Path
            $testResults.SqlInstance | Should Be $script:postgresqlInstance
            $testResults.Database | Should Be $newDbName
            $testResults.SourcePath | Should Be $v1scripts
            $testResults.ConnectionType | Should Be 'PostgreSQL'
            $testResults.Configuration.SchemaVersionTable | Should Be 'SchemaVersions'
            $testResults.Error | Should BeNullOrEmpty
            $testResults.Duration.TotalMilliseconds | Should -BeGreaterOrEqual 0
            $testResults.StartTime | Should Not BeNullOrEmpty
            $testResults.EndTime | Should Not BeNullOrEmpty
            $testResults.EndTime | Should -BeGreaterOrEqual $testResults.StartTime
            'Upgrade successful' | Should BeIn $testResults.DeploymentLog

            #Verifying objects
            $testResults = Invoke-DBOQuery -Type PostgreSQL -SqlInstance $script:postgresqlInstance -Silent -Credential $script:postgresqlCredential -Database $newDbName -InputFile $verificationScript
            'SchemaVersions' | Should BeIn $testResults.name
            'a' | Should BeIn $testResults.name
            'b' | Should BeIn $testResults.name
            'c' | Should Not BeIn $testResults.name
            'd' | Should Not BeIn $testResults.name
            ($testResults | Measure-Object).Count | Should Be ($rowsBefore + 3)
        }
        It "should deploy version 2.0" {
            $before = Invoke-DBOQuery -Type PostgreSQL -SqlInstance $script:postgresqlInstance -Silent -Credential $script:postgresqlCredential -Database $newDbName -InputFile $verificationScript
            $rowsBefore = ($before | Measure-Object).Count
            $testResults = Install-DBOSqlScript -Type PostgreSQL -ScriptPath $v2scripts -SqlInstance $script:postgresqlInstance -Credential $script:postgresqlCredential -Database $newDbName -Silent
            $testResults.Successful | Should Be $true
            $testResults.Scripts.Name | Should Be (Resolve-Path $v2scripts).Path
            $testResults.SqlInstance | Should Be $script:postgresqlInstance
            $testResults.Database | Should Be $newDbName
            $testResults.SourcePath | Should Be $v2scripts
            $testResults.ConnectionType | Should Be 'PostgreSQL'
            $testResults.Configuration.SchemaVersionTable | Should Be 'SchemaVersions'
            $testResults.Error | Should BeNullOrEmpty
            $testResults.Duration.TotalMilliseconds | Should -BeGreaterOrEqual 0
            $testResults.StartTime | Should Not BeNullOrEmpty
            $testResults.EndTime | Should Not BeNullOrEmpty
            $testResults.EndTime | Should -BeGreaterOrEqual $testResults.StartTime
            'Upgrade successful' | Should BeIn $testResults.DeploymentLog

            #Verifying objects
            $testResults = Invoke-DBOQuery -Type PostgreSQL -SqlInstance $script:postgresqlInstance -Silent -Credential $script:postgresqlCredential -Database $newDbName -InputFile $verificationScript
            'SchemaVersions' | Should BeIn $testResults.name
            'a' | Should BeIn $testResults.name
            'b' | Should BeIn $testResults.name
            'c' | Should BeIn $testResults.name
            'd' | Should BeIn $testResults.name
            ($testResults | Measure-Object).Count | Should Be ($rowsBefore + 2)
        }
    }
    Context "testing deployment with no history`: SchemaVersion is null" {
        BeforeEach {
            $null = Invoke-DBOQuery -Type PostgreSQL -SqlInstance $script:postgresqlInstance -Silent -Credential $script:postgresqlCredential -Database postgres -Query ($dropDatabaseScript + $createDatabaseScript)
        }
        AfterEach {
            $null = Invoke-DBOQuery -Type PostgreSQL -SqlInstance $script:postgresqlInstance -Silent -Credential $script:postgresqlCredential -Database $newDbName -Query "DROP TABLE IF EXISTS SchemaVersions"
        }
        It "should deploy version 1.0 without creating SchemaVersions" {
            $before = Invoke-DBOQuery -Type PostgreSQL -SqlInstance $script:postgresqlInstance -Silent -Credential $script:postgresqlCredential -Database $newDbName -InputFile $verificationScript
            $rowsBefore = ($before | Measure-Object).Count
            $testResults = Install-DBOSqlScript -Type PostgreSQL -ScriptPath $v1scripts  -SqlInstance $script:postgresqlInstance -Credential $script:postgresqlCredential -Database $newDbName -Silent -SchemaVersionTable $null
            $testResults.Successful | Should Be $true
            $testResults.Scripts.Name | Should Be (Resolve-Path $v1scripts).Path
            $testResults.SqlInstance | Should Be $script:postgresqlInstance
            $testResults.Database | Should Be $newDbName
            $testResults.SourcePath | Should Be $v1scripts
            $testResults.ConnectionType | Should Be 'PostgreSQL'
            $testResults.Configuration.SchemaVersionTable | Should BeNullOrEmpty
            $testResults.Error | Should BeNullOrEmpty
            $testResults.Duration.TotalMilliseconds | Should -BeGreaterOrEqual 0
            $testResults.StartTime | Should Not BeNullOrEmpty
            $testResults.EndTime | Should Not BeNullOrEmpty
            $testResults.EndTime | Should -BeGreaterOrEqual $testResults.StartTime
            'Upgrade successful' | Should BeIn $testResults.DeploymentLog
            'Checking whether journal table exists..' | Should Not BeIn $testResults.DeploymentLog

            #Verifying objects
            $testResults = Invoke-DBOQuery -Type PostgreSQL -SqlInstance $script:postgresqlInstance -Silent -Credential $script:postgresqlCredential -Database $newDbName -InputFile $verificationScript
            'SchemaVersions' | Should Not BeIn $testResults.name
            'a' | Should BeIn $testResults.name
            'b' | Should BeIn $testResults.name
            'c' | Should Not BeIn $testResults.name
            'd' | Should Not BeIn $testResults.name
            ($testResults | Measure-Object).Count | Should Be ($rowsBefore + 2)
        }
    }
    Context "deployments with errors should throw terminating errors" {
        BeforeAll {
            $null = Invoke-DBOQuery -Type PostgreSQL -SqlInstance $script:postgresqlInstance -Silent -Credential $script:postgresqlCredential -Database postgres -Query ($dropDatabaseScript + $createDatabaseScript)
            $null = Install-DBOSqlScript -Type PostgreSQL -ScriptPath $v1scripts  -SqlInstance $script:postgresqlInstance -Credential $script:postgresqlCredential -Database $newDbName -Silent -SchemaVersionTable $null
        }
        It "Should return terminating error when object exists" {
            #Running package
            { $null = Install-DBOSqlScript -Type PostgreSQL -Path $tranFailScripts -SqlInstance $script:postgresqlInstance -Credential $script:postgresqlCredential -Database $newDbName -SchemaVersionTable $logTable -DeploymentMethod NoTransaction -Silent } | Should throw 'relation "a" already exists'
        }
        It "should not deploy anything after throwing an error" {
            #Running package
            try {
                $testResults = $null
                $null = Install-DBOSqlScript -Type PostgreSQL -Path $tranFailScripts -SqlInstance $script:postgresqlInstance -Credential $script:postgresqlCredential -Database $newDbName -SchemaVersionTable $logTable -DeploymentMethod NoTransaction -Silent
                $testResults = Install-DBOSqlScript -Type PostgreSQL -ScriptPath $v2scripts -SqlInstance $script:postgresqlInstance -Credential $script:postgresqlCredential -Database $newDbName -SchemaVersionTable $logTable -Silent
            }
            catch {
                $errorObject = $_
            }
            $testResults | Should Be $null
            $errorObject | Should Not BeNullOrEmpty
            $errorObject.Exception.Message | Should -BeLike '*relation "a" already exists'
            #Verifying objects
            $testResults = Invoke-DBOQuery -Type PostgreSQL -SqlInstance $script:postgresqlInstance -Silent -Credential $script:postgresqlCredential -Database $newDbName -InputFile $verificationScript
            'a' | Should BeIn $testResults.name
            'b' | Should BeIn $testResults.name
            'c' | Should Not BeIn $testResults.name
            'd' | Should Not BeIn $testResults.name
        }
    }
}
