function Invoke-DbaDbScanPii {
    <#
    .SYNOPSIS
        Command to return any columns that could potentially contain PII (Personal Identifiable Information)

    .DESCRIPTION
        This command will go through the tables in your database and asses each column.
        It will first check the columns names if it was named in such a way that it would indicate PII.
        The next thing that it will do is pattern recognition by looking into the data from the table.

    .PARAMETER SqlInstance
        The target SQL Server instance or instances.

    .PARAMETER SqlCredential
        Login to the target instance using alternative credentials. Windows and SQL Authentication supported. Accepts credential objects (Get-Credential)

    .PARAMETER Database
        Databases to process through

    .PARAMETER Table
        Tables to process. By default all the tables will be processed

    .PARAMETER Column
        Columns to process. By default all the columns will be processed

    .PARAMETER Country
        Filter out the patterns and known types for one or more countries

    .PARAMETER CountryCode
        Filter out the patterns and known types for one or more country code

    .PARAMETER SampleCount
        Amount of rows to sample to make an assessment. The default is 100

    .PARAMETER Force
        Forcefully execute commands when needed

    .PARAMETER WhatIf
        If this switch is enabled, no actions are performed but informational messages will be displayed that explain what would happen if the command were to run.

    .PARAMETER Confirm
        If this switch is enabled, you will be prompted for confirmation before executing any operations that change state.

    .PARAMETER EnableException
        By default, when something goes wrong we try to catch it, interpret it and give you a friendly warning message.
        This avoids overwhelming you with "sea of red" exceptions, but is inconvenient because it basically disables advanced scripting.
        Using this switch turns this "nice by default" feature off and enables you to catch exceptions with your own try/catch.

    .NOTES
        Tags: DataMasking, Database
        Author: Sander Stad (@sqlstad, sqlstad.nl)

        Website: https://dbatools.io
        Copyright: (c) 2018 by dbatools, licensed under MIT
        License: MIT https://opensource.org/licenses/MIT

    .LINK
        https://dbatools.io/Invoke-DbaDbScanPii

    .EXAMPLE


    #>
    [CmdLetBinding()]
    param (
        [DbaInstanceParameter[]]$SqlInstance,
        [PSCredential]$SqlCredential,
        [string[]]$Database,
        [string[]]$Table,
        [string[]]$Column,
        [string[]]$Country,
        [string[]]$CountryCode,
        [int]$SampleCount = 100,
        [switch]$EnableException
    )

    begin {

        # Get the patterns
        try {
            $patternFile = Resolve-Path -Path "$script:PSModuleRoot\bin\datamasking\pii-patterns.json"
            $patterns = Get-Content -Path $patternFile -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        } catch {
            Stop-Function -Message "Couldn't parse pattern file" -ErrorRecord $_
            return
        }

        # Get the known types
        try {
            $knownTypesFile = Resolve-Path -Path "$script:PSModuleRoot\bin\datamasking\pii-knowntypes.json"
            $knownTypes = Get-Content -Path $knownTypesFile -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        } catch {
            Stop-Function -Message "Couldn't parse known types file" -ErrorRecord $_
            return
        }

        # Check parameters
        if (-not $SqlInstance) {
            Stop-Function -Message "Please enter a SQL Server instance" -Category InvalidArgument
        }

        if (-not $Database) {
            Stop-Function -Message "Please enter a database" -Category InvalidArgument
        }

        # Filter the patterns
        if ($Country.Count -ge 1) {
            $patterns = $patterns | Where-Object Country -in $Country
        }

        if ($CountryCode.Count -ge 1) {
            $patterns = $patterns | Where-Object CountryCode -in $CountryCode
        }
    }

    process {
        if (Test-FunctionInterrupt) {
            return
        }

        $results = @()

        # Loop through the instances
        foreach ($instance in $SqlInstance) {

            # Try to connect to the server
            try {
                $server = Connect-SqlInstance -SqlInstance $instance -SqlCredential $sqlcredential -MinimumVersion 9
            } catch {
                Stop-Function -Message "Error occurred while establishing connection to $instance" -Category ConnectionError -ErrorRecord $_ -Target $instance -Continue
            }

            # Loop through the databases
            foreach ($dbName in $Database) {

                # Get the database object
                $db = $server.Databases[$($dbName)]

                # Filter the tables if needed
                if ($Table) {
                    $tables = $db.Tables | Where-Object Name -in $Table
                } else {
                    $tables = $db.Tables
                }

                # Filter the tables based on the column
                if ($Column) {
                    $tables = $tables | Where-Object { $_.Columns.Name -in $Column }
                }

                # Loop through the tables
                foreach ($tableobject in $tables) {

                    # Get the columns
                    if ($Column) {
                        $columns = $tableobject.Columns | Where-Object Name -in $Column
                    } else {
                        $columns = $tableobject.Columns
                    }

                    # Loop through the columns
                    foreach ($columnobject in $columns) {

                        # Go through the first check to see if any column is found with a known type
                        foreach ($knownType in $knownTypes) {

                            foreach ($pattern in $knownType.Pattern) {

                                if ($columnobject.Name -match $pattern ) {
                                    # Check if the results not already contain a similar object
                                    if ($null -eq ($results | Where-Object { $_.Database -eq $dbName -and $_.Schema -eq $tableobject.Schema -and $_.Table -eq $tableobject.Name -and $_.Column -eq $columnobject.Name })) {

                                        # Add the results
                                        $results += [pscustomobject]@{
                                            ComputerName   = $db.Parent.ComputerName
                                            InstanceName   = $db.Parent.ServiceName
                                            SqlInstance    = $db.Parent.DomainInstanceName
                                            Database       = $dbName
                                            Schema         = $tableobject.Schema
                                            Table          = $tableobject.Name
                                            Column         = $columnobject.Name
                                            "PII Name"     = $knownType.Name
                                            "PII Category" = $knownType.Category
                                        }

                                    }

                                }

                            }

                        }

                        # Check if the results not already contain a similar object
                        if ($null -eq ($results | Where-Object { $_.Database -eq $dbName -and $_.Schema -eq $tableobject.Schema -and $_.Table -eq $tableobject.Name -and $_.Column -eq $columnobject.Name })) {
                            # Setup the query
                            $query = "SELECT TOP($SampleCount) " + "[" + ($columns.Name -join "],[") + "] FROM [$($tableobject.Schema)].[$($tableobject.Name)]"

                            # Get the data
                            try {
                                $dataset = @()
                                $dataset += Invoke-DbaQuery -SqlInstance $instance -SqlCredential $SqlCredential -Database $dbName -Query $query
                            } catch {

                                Stop-Function -Message "Something went wrong retrieving the data from [$($tableobject.Schema)].[$($tableobject.Name)]`n$query" -Target $tableobject -Continue
                            }

                            # Check if there is any data
                            if ($dataset.Count -ge 1) {

                                # Loop through the patterns
                                foreach ($patternobject in $patterns) {

                                    # If there is a result from the match
                                    if ($dataset.$($columnobject.Name) -match $patternobject.Pattern) {

                                        # Check if the results not already contain a similar object
                                        if ($null -eq ($results | Where-Object { $_.Database -eq $dbName -and $_.Schema -eq $tableobject.Schema -and $_.Table -eq $tableobject.Name -and $_.Column -eq $columnobject.Name })) {

                                            # Add the results
                                            $results += [pscustomobject]@{
                                                ComputerName   = $db.Parent.ComputerName
                                                InstanceName   = $db.Parent.ServiceName
                                                SqlInstance    = $db.Parent.DomainInstanceName
                                                Database       = $dbName
                                                Schema         = $tableobject.Schema
                                                Table          = $tableobject.Name
                                                Column         = $columnobject.Name
                                                "PII Name"     = $patternobject.Name
                                                "PII Category" = $patternobject.category
                                            }

                                        }

                                    }

                                }

                            } else {
                                Write-Message -Message "Table $($tableobject.Name) does not contain any rows" -Level Verbose
                            }

                        }

                    } # End for each column

                } # End for each table

            } # End for each database

        } # End for each instance

        $results

    } # End process
}