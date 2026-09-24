FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY src/SqlProbe/SqlProbe.csproj SqlProbe/
RUN dotnet restore SqlProbe/SqlProbe.csproj
COPY src/SqlProbe/ SqlProbe/
RUN dotnet publish SqlProbe/SqlProbe.csproj -c Release -o /app/publish --no-restore

FROM mcr.microsoft.com/dotnet/aspnet:10.0-noble AS runtime
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      krb5-user libgssapi-krb5-2 ca-certificates curl \
 && rm -rf /var/lib/apt/lists/* \
 && rm -f /etc/krb5.conf

USER 1654
WORKDIR /app
COPY --from=build --chown=1654:1654 /app/publish .
ENV ASPNETCORE_URLS=http://0.0.0.0:8080 \
    DOTNET_EnableDiagnostics=0
EXPOSE 8080
ENTRYPOINT ["dotnet", "SqlProbe.dll"]
