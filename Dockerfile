# SqlProbe — .NET 10 ASP.NET Core app + MIT Kerberos client, on Debian 13 (trixie).
# One image serves both the app container and the kinit sidecar.
#
# Public build:   docker build -t sqlprobe:0.1.0 .
# Behind Nexus (scripts/build-push.sh passes these from .env):
#   --build-arg BASE_REGISTRY=nexus.corp.local:8443/mcr              # docker proxy of mcr.microsoft.com
#   --build-arg DEBIAN_IMAGE=nexus.corp.local:8443/dockerhub/debian:trixie-slim   # docker proxy of docker.io
#   --build-arg NUGET_SOURCE=https://nexus.corp.local/repository/nuget-group/index.json
#   --build-arg NUGET_USERNAME=svc-build  --secret id=nuget_password,env=NUGET_PASSWORD
#   --build-arg APT_MIRROR=https://nexus.corp.local/repository/debian-trixie/
#   --build-arg APT_SECURITY_MIRROR=https://nexus.corp.local/repository/debian-trixie-security/
ARG BASE_REGISTRY=mcr.microsoft.com
ARG DEBIAN_IMAGE=debian:trixie-slim

# ── build ────────────────────────────────────────────────────────────────────
FROM ${BASE_REGISTRY}/dotnet/sdk:10.0 AS build
ARG NUGET_SOURCE=https://api.nuget.org/v3/index.json
# Authenticated Nexus NuGet feed: username is a plain build arg, the password is a
# BuildKit secret (docker build --secret id=nuget_password,env=NUGET_PASSWORD).
# A throw-away nuget.config is written and removed inside ONE RUN step, so the
# credential never lands in a layer, in `docker history`, or in the final image.
ARG NUGET_USERNAME=
WORKDIR /src
COPY src/SqlProbe/SqlProbe.csproj SqlProbe/
RUN --mount=type=secret,id=nuget_password,required=false \
    set -eu; \
    printf '%s\n' '<?xml version="1.0" encoding="utf-8"?>' '<configuration>' '  <packageSources>' \
      '    <clear />' "    <add key=\"feed\" value=\"$NUGET_SOURCE\" />" '  </packageSources>' \
      '</configuration>' > /src/nuget.config; \
    if [ -n "$NUGET_USERNAME" ] && [ -s /run/secrets/nuget_password ]; then \
      dotnet nuget update source feed --configfile /src/nuget.config \
        --username "$NUGET_USERNAME" --password "$(cat /run/secrets/nuget_password)" \
        --store-password-in-clear-text >/dev/null; \
    fi; \
    dotnet restore SqlProbe/SqlProbe.csproj --configfile /src/nuget.config; \
    rm -f /src/nuget.config
COPY src/SqlProbe/ SqlProbe/
RUN dotnet publish SqlProbe/SqlProbe.csproj -c Release -o /app/publish --no-restore

# ── runtime source (only used for COPY --from) ───────────────────────────────
FROM ${BASE_REGISTRY}/dotnet/aspnet:10.0 AS aspnet

# ── runtime ──────────────────────────────────────────────────────────────────
FROM ${DEBIAN_IMAGE} AS runtime
ARG APT_MIRROR=
ARG APT_SECURITY_MIRROR=
# Debian trixie uses deb822 /etc/apt/sources.list.d/debian.sources:
#   URIs: http://deb.debian.org/debian           Suites: trixie trixie-updates
#   URIs: http://deb.debian.org/debian-security  Suites: trixie-security
RUN set -eu; \
    f=/etc/apt/sources.list.d/debian.sources; \
    if [ -n "$APT_SECURITY_MIRROR" ]; then sed -i "s|http://deb.debian.org/debian-security|$APT_SECURITY_MIRROR|g" "$f"; fi; \
    if [ -n "$APT_MIRROR" ];          then sed -i "s|http://deb.debian.org/debian\b|$APT_MIRROR|g" "$f"; fi; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ca-certificates curl tzdata \
      libc6 libgcc-s1 libstdc++6 libssl3t64 zlib1g libicu76 \
      krb5-user libgssapi-krb5-2; \
    rm -rf /var/lib/apt/lists/*; \
    rm -f /etc/krb5.conf; \
    groupadd -g 1654 app && useradd -u 1654 -g 1654 -m -s /usr/sbin/nologin app
COPY --from=aspnet /usr/share/dotnet /usr/share/dotnet
RUN ln -s /usr/share/dotnet/dotnet /usr/bin/dotnet
USER 1654
WORKDIR /app
COPY --from=build --chown=1654:1654 /app/publish .
COPY --chown=1654:1654 entrypoint.sh /app/entrypoint.sh
ENV ASPNETCORE_URLS=http://0.0.0.0:8080 \
    DOTNET_EnableDiagnostics=0 \
    DOTNET_RUNNING_IN_CONTAINER=true
EXPOSE 8080
ENTRYPOINT ["/app/entrypoint.sh"]
