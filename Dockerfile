FROM mcr.microsoft.com/powershell:7.4-ubuntu-22.04

SHELL ["/bin/bash", "-lc"]

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        libgssapi-krb5-2 \
        libssl3 \
    && rm -rf /var/lib/apt/lists/*

RUN pwsh -NoLogo -NoProfile -Command "Set-PSRepository -Name PSGallery -InstallationPolicy Trusted; Install-Module dbatools -Force -Scope AllUsers"

RUN useradd -ms /bin/bash ddluser

WORKDIR /app

COPY scripts /app/scripts

RUN chown -R ddluser:ddluser /app

USER ddluser

ENTRYPOINT ["pwsh", "-NoLogo", "-NoProfile", "-File", "/app/scripts/main.ps1"]
