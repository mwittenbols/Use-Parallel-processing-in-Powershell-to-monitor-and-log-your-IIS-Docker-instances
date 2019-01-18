<#

    Adapted 2019/01/15 by manfred.wittenbols@symetra.com from https://github.com/MicrosoftDocs/Virtualization-Documentation/blob/live/windows-server-container-tools/Wait-Service/Wait-Service.ps1

    Description: Monitors the specified process for $ServiceName and restarts it when it fails, while in parallel pulls log file trails and outputs them to the console

    Usage: Wait-Service-WithLogging $ServiceName $StartupTimeout $AllowServiceRestart

    $ServiceName = The name of the process/service to wait for
    $StartupTimeout = The nuimber of seconds to wait before monitoring the process/service
    $AllowServiceRestart = Optional switch, when present, will restart hte process when it fails

    Example: Wait-Service-WithLogging.ps1 -ServiceName W3SVC -AllowServiceRestart

#>

    [CmdletBinding()]
    param(
        #The name of the service to wait for.
        [Parameter(Mandatory=$True)]
        [ValidateNotNullOrEmpty()]
        [string] 
        $ServiceName,

        #The amount of time in seconds to wait for the service to start after initating the script.  Default is 10sec.
        [ValidateNotNullOrEmpty()]
        [int] 
        $StartupTimeout = 10,

        #Automtically restart the wait process when the service exits looping for the StartupTimeout again.
        [switch] 
        $AllowServiceRestart
    )

# One of the routines that will be executed in parallel, that monitors a service and exits when it fails (after which we can execute a restart of that process, if desired)
function LoopWhileRunning() {

    [CmdletBinding()]
    param(
        # The name of the service to wait for.
        [Parameter(Mandatory=$True)]
        # Let's make it mandatory
        [ValidateNotNullOrEmpty()]
        # We use a 3 postfix as all variable names need to be unique, when nesting them in a Powershell script
        [string] $ServiceName3,
        # True = loop indefinitely
        [bool] $AllowServiceRestart3
        )

    do {

        # Provide some debug info in the output
        Write-Host ([System.String]::Format("Started: LoopWhileRunning {0}", $ServiceName3))

        #Importing the System.ServiceProcess Assembly
        Add-Type -AssemblyName System.ServiceProcess -ErrorAction SilentlyContinue

        #Adding a PInvoke call for QueryServiceStatus which is used to get the error return.
        # https://github.com/dotnet/corefx/blob/master/src/Common/src/Interop/Windows/mincore/Interop.ENUM_SERVICE_STATUS.cs
        # https://github.com/dotnet/corefx/blob/master/src/Common/src/Interop/Windows/mincore/Interop.QueryServiceStatus.cs
        Add-Type -Name Advapi32 -Namespace Interop -PassThru -MemberDefinition @'
            // https://msdn.microsoft.com/en-us/library/windows/desktop/ms685996(v=vs.85).aspx
            [StructLayout(LayoutKind.Sequential)]
            public struct SERVICE_STATUS
            {
                public int serviceType;
                public int currentState;
                public int controlsAccepted;
                public int win32ExitCode;
                public int serviceSpecificExitCode;
                public int checkPoint;
                public int waitHint;
            }

            [DllImport("api-ms-win-service-winsvc-l1-1-0.dll", CharSet = CharSet.Unicode, SetLastError=true)] 
                public static extern bool QueryServiceStatus(
                    System.Runtime.InteropServices.SafeHandle serviceHandle, 
                    out SERVICE_STATUS pStatus);
'@ | Out-Null 

        # Let's get our process we are monitoring
        $ServiceProcess3 = New-Object System.ServiceProcess.ServiceController($ServiceName3)

        # Keep a counter so we can limit the number of debug info lines we output to the console
        $i = 1

        # Keep looping, until the service is no longer running
        do {

            # Only output a line to the output every n loops
            if ($i % 100 -eq 0) {
                Write-Host ([System.String]::Format("The Service '{0}' is in the 'Running' state.", $ServiceName3))
            }

            # Wait for a little bit, before checking the status of the process again
            Start-Sleep -Milliseconds 100
            $ServiceProcess3.Refresh()

            $i = $i + 1

        } 
        while ($ServiceProcess3.Status -eq [System.ServiceProcess.ServiceControllerStatus]::Running)

        Write-Host ([System.String]::Format("The Service '{0}' stopped.", $ServiceName3))

        # Oh no, if we reached this point, IIS has stopped. Let's see if we can quickly restart it, before the HEALTHCHECK kicks in
        if ($AllowServiceRestart3) {

            Write-Host ([System.String]::Format("Restarting Service '{0}'.", $ServiceName3))

            # Wait for a few seconds to have things cool down
            Start-Sleep -Seconds 10

            # Restart IIS
            Restart-Service -Name W3SVC -Force

            # Use some variables for our polling mechanism below
            $i = 0
            $restartedSuccess = 0

            # Make sure we have the latest status of the IIS process
            $ServiceProcess3.Refresh()

            do {

                if ($i % 100 -eq 0) {
                    Write-Host ([System.String]::Format("Waiting for Service '{0}' to come back up. Current status = {1}", $ServiceName3, $ServiceProcess3.Status))
                }

                Start-Sleep -Milliseconds 100
                $i = $i + 1
                $ServiceProcess3.Refresh()

                # Is IIS Running already?
                if ($ServiceProcess3.Status -eq [System.ServiceProcess.ServiceControllerStatus]::Running) {
                    $restartedSuccess = 1
                     Write-Host ([System.String]::Format("Service '{0}' came back up. Current status = {1}", $ServiceName3, $ServiceProcess3.Status))
                }

            # Continue until we reach the 30 seconds
            } while (($restartedSuccess -eq 0) -and ($i -lt 300))

            # If IIS came back up successfully, do nothing
            if ($restartedSuccess) {
                Write-Host ([System.String]::Format("Service '{0}' restart successfully.", $ServiceName3))
            } else {
                # IF IIS still hasn't come back up, exit the Workflow and stop the script
                Write-Host ([System.String]::Format("Service '{0}' failed to restart. Exiting..", $ServiceName3))
                $AllowServiceRestart3 = $False
                Exit-PSSession 
            }

        }

    }
    while ($AllowServiceRestart3)    
}

Workflow WaitWhileLogging {

    param(
        #The name of the service to wait for.
        [Parameter(Mandatory=$True)]
        [string] $ServiceName2,
        [bool] $AllowServiceRestart2
    )

    InlineScript {

        Write-Host ([System.String]::Format("Inside WaitWhileLogging"))
        Write-Host ([System.String]::Format("ServiceName = {0}", $Using:ServiceName2))
    }

    #Run commands in parallel.
    Parallel
    {
        # Monitor any additions to logfile #1 and send them to the console. 
        # The -Tail parameter indicates we will be reading a new line that is added at the end of the file
        # The -Wait parameter indicates we will wait indefinitely for new lines being added
        Get-Content -path 'c:\iislog\W3SVC\u_extend1.log' -Tail 1 -Wait
        # Monitor any additions to logfile #3 and send them to the console
        Get-Content -path '\Windows\iis.log' -Tail 1 -Wait
        # Add additional custom log file sources below:
        
        # Also, in parallel, run this script block, which by itself will run sequentially
        Sequence {

            # Wait indefinitely, and if the -AllowServiceRestart switch was provided to this Powershell script, we will keep try restarting IIS after failure
            # until that fails too, then we will exit the script.
            # Note: the IIS restart logic we added to this script is not a requirement for implementing a well performing cluster of containers if
            # you implement a HEALTHCECK. If you implement a HEALTHCHECK in the Dockerfile, it is OK to remove the IIS restart logic from this script
            # as you can also rely on the HEALTHCHECK and the container orchestrator of restarting the container.
            # However, by attempting an IIS restart from within the container, we are providing a faster recovery from transient IIS failures.
            LoopWhileRunning -ServiceName3 $ServiceName2 -AllowServiceRestart3 $AllowServiceRestart2
            # If we ever reach this point, it is because we couldn't restart IIS
            InlineScript { 
                Write-Host ([System.String]::Format("Exiting WaitWhileLogging Workflow..")) 
            }
            
            Exit

            Suspend-Workflow
            
            InlineScript { 
                Exit-PSSession 
            }
            
        }
    }
        
}
        

function Wait-Service()
{
    [CmdletBinding()]
    param(
        #The name of the service to wait for.
        [Parameter(Mandatory=$True)]
        [ValidateNotNullOrEmpty()]
        [string] 
        $ServiceName,

        #The amount of time in seconds to wait for the service to start after initating the script.  Default is 10sec.
        [ValidateNotNullOrEmpty()]
        [int] 
        $StartupTimeout = 5,

        #Automatically restart the wait process when the service exits looping for the StartupTimeout again.
        [bool] 
        $AllowServiceRestart
    )
    #Allow Service Restart
    do 
    {
        
        #Importing the System.ServiceProcess Assembly
        Add-Type -AssemblyName System.ServiceProcess -ErrorAction SilentlyContinue

        #Adding a PInvoke call for QueryServiceStatus which is used to get the error return.
        # https://github.com/dotnet/corefx/blob/master/src/Common/src/Interop/Windows/mincore/Interop.ENUM_SERVICE_STATUS.cs
        # https://github.com/dotnet/corefx/blob/master/src/Common/src/Interop/Windows/mincore/Interop.QueryServiceStatus.cs
        Add-Type -Name Advapi32 -Namespace Interop -PassThru -MemberDefinition @'
            // https://msdn.microsoft.com/en-us/library/windows/desktop/ms685996(v=vs.85).aspx
            [StructLayout(LayoutKind.Sequential)]
            public struct SERVICE_STATUS
            {
                public int serviceType;
                public int currentState;
                public int controlsAccepted;
                public int win32ExitCode;
                public int serviceSpecificExitCode;
                public int checkPoint;
                public int waitHint;
            }

            [DllImport("api-ms-win-service-winsvc-l1-1-0.dll", CharSet = CharSet.Unicode, SetLastError=true)] 
                public static extern bool QueryServiceStatus(
                    System.Runtime.InteropServices.SafeHandle serviceHandle, 
                    out SERVICE_STATUS pStatus);
'@ | Out-Null 

        $ServiceProcess = New-Object System.ServiceProcess.ServiceController($ServiceName)

        if ($ServiceProcess -eq $null)
        {
            throw "The specified service does not exist or can not be found."
        }
        
        #Startup timeout block
        try 
        {
            $ServiceProcess.WaitForStatus(
                [System.ServiceProcess.ServiceControllerStatus]::Running,
                [System.TimeSpan]::FromSeconds($StartupTimeout))
        }
        catch [System.ServiceProcess.TimeoutException] 
        {
            $exception = New-Object System.TimeoutException(
                [System.String]::Format(
                    "The Service '{0}' did not enter the 'Running' state within the {1} sec timeout.", 
                    $ServiceName, $StartupTimeout),
                $_.Exception
            )
            throw $exception 
        }

        #Service is in the Running State.  In a sleep loop waiting for service to stop.
        Write-Host ([System.String]::Format("The Service '{0}' is in the 'Running' state.", $ServiceName))
       
        WaitWhileLogging -ServiceName2 $ServiceName -AllowServiceRestart2 $AllowServiceRestart

        Write-Host ([System.String]::Format("Exiting Wait-Service.."))

        #Stop/Error State
        $serviceStatus = New-Object Interop.Advapi32+SERVICE_STATUS
        [Interop.Advapi32]::QueryServiceStatus($ServiceProcess.ServiceHandle, [ref] $serviceStatus) |Out-Null
        
        $logString = [System.String]::Format(
                "The Service '{0}' has stopped.  The service control manager reported it's Exit Status as {1}", 
                $ServiceName, $serviceStatus.win32ExitCode)

        if ($serviceStatus.win32ExitCode -ne 0)
        {
            Write-Error $logString
        }
        else 
        {
            Write-Host $logString
        }
    }
    while ($AllowServiceRestart)    

    Write-Host ([System.String]::Format("The Wait-Service exited."))
    
    return $serviceStatus.win32ExitCode
}

if ($AllowServiceRestart)
{
    Wait-Service -ServiceName $ServiceName -StartupTimeout $StartupTimeout -AllowServiceRestart $True
}
else 
{
    Wait-Service -ServiceName $ServiceName -StartupTimeout $StartupTimeout -AllowServiceRestart $False
}
