FROM mcr.microsoft.com/powershell:7.4-debian-12

WORKDIR /app
COPY . .

# Run the migration once when the container starts (Render Background Worker will run this on deploy/restart)
CMD ["pwsh","-NoProfile","-File","./migrate.ps1"]
