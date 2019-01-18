# Dockerfile Created 2019-01-08 by Manfred Wittenbols
# escape=`

# In this example we are containerizging a legacy web application running on ASP.NET 4.6.2.
FROM microsoft/aspnet:4.6.2-windowsservercore-ltsc2016

MAINTAINER Manfred Wittenbols <mwittenbols@github>
LABEL maintainer="mwittenbols@github"

# Let's make Powershell our shell of choice
SHELL ["powershell", "-Command", "$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue';"]

# First, add the basic features needed to run ASP.NET web applications
RUN Add-WindowsFeature Web-Server; \
    Add-WindowsFeature Web-Asp-Net45

# If we are not implementing our own service monitoring mechanism, we need to download the ServiceMonitor.exe. This process is how Microsoft monitors IIS inside a Docker container instance
# RUN Invoke-WebRequest -Uri https://dotnetbinaries.blob.core.windows.net/servicemonitor/2.0.1.6/ServiceMonitor.exe -OutFile C:\ServiceMonitor.exe
# In this example, we will be implemented our own monitoring mechanism

# configure IIS to write a global log file. We want this log info to be exposed to the orchestrator
# Unlock custom config
# Note: combine as much RUN statements in one RUN statement as you can, to reduce Docker image size
RUN Set-WebConfigurationProperty -pspath 'MACHINE/WEBROOT/APPHOST' -filter 'system.applicationHost/log' -name 'centralLogFileMode' -value 'CentralW3C'; \
    Set-WebConfigurationProperty -pspath 'MACHINE/WEBROOT/APPHOST' -filter 'system.applicationHost/log/centralW3CLogFile' -name 'truncateSize' -value 4294967295; \
    Set-WebConfigurationProperty -pspath 'MACHINE/WEBROOT/APPHOST' -filter 'system.applicationHost/log/centralW3CLogFile' -name 'period' -value 'MaxSize'; \
    Set-WebConfigurationProperty -pspath 'MACHINE/WEBROOT/APPHOST' -filter 'system.applicationHost/log/centralW3CLogFile' -name 'directory' -value 'c:\\iislog'; \
    c:\windows\system32\inetsrv\appcmd.exe \
    unlock config \
    /section:system.webServer/handlers;

# Option 1: If not using an MSI Installer:
# Let's remove the content of the default website
RUN Remove-Item -Recurse C:\inetpub\wwwroot\*
# The final instruction copies the site you published earlier into the container.
COPY ./wwwroot /inetpub/wwwroot

# Option 2: If using an MSI for deployment:
# Copy the MSI into the image from the local folder, then execute the MSI
# COPY yourapplication.msi /

# For now, let's run HTTP only and expose the container on port 80
EXPOSE 80

# Normally you would run the ServiceMonitor with the w3svc (IIS) as a parameter, however now we are using Powershell
# Option 1: Using the ServiceMonitor to monitor W3SVC (IIS) - Disadvantage: Logging is harder, environment variables need to become Machine level as opposed to Process level
# We added a little Powershell bootstrap script that copies all Process level environment variables to Machine level environment variables so that the w3svc (IIS) process can access and read them
#ENTRYPOINT ["C:\\ServiceMonitor.exe", "w3svc"]

# Option 2: Using Powershell to run a custom script to output logging and monitor IIS at the same time
ENTRYPOINT ["powershell"]  

# Copy our custom Powershell script into the Docker image
COPY Wait-Service-WithLogging.ps1 /Wait-Service-WithLogging.ps1

# Start IIS, and fire an initial request to trigger the creation of the log files. Then, call our customer Powershell script to monitor IIS and wait for log output
# Note: combine as much RUN statements in one RUN statement as you can, to reduce Docker image size (as each statement creates a new layer)
CMD Start-Service W3SVC; \
    Invoke-WebRequest http://localhost -UseBasicParsing | Out-Null; \
    netsh http flush logbuffer | Out-Null; \
    c:\Wait-Service-WithLogging.ps1 -ServiceName W3SVC -AllowServiceRestart

# Add a HEALTH probe: Since the current ASP.NET web application does not expose an /health endpoint yet, we'll be using another small but static file that can perform the same function
HEALTHCHECK --interval=20s \  
 CMD powershell -command \
    try { \
      $response = iwr http://localhost/health -UseBasicParsing; \
     if ($response.StatusCode -eq 200) { return 0} \
     else {return 1}; \
    } catch { return 1 }

# Add a READINESS probe: TODO