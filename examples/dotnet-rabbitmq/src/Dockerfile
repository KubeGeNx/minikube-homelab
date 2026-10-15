# Multi-stage: restore/publish with the SDK, ship on the smaller runtime.
FROM mcr.microsoft.com/dotnet/sdk:9.0 AS build
WORKDIR /src
# Copy the csproj alone first so `restore` is cached independently of source
# edits -- changing Program.cs then doesn't re-download every NuGet package.
COPY OrderFlow.csproj .
RUN dotnet restore
COPY Program.cs .
RUN dotnet publish -c Release -o /app --no-restore

FROM mcr.microsoft.com/dotnet/runtime:9.0
WORKDIR /app
COPY --from=build /app .
# Run as non-root; the base image ships this UID.
USER $APP_UID
ENTRYPOINT ["dotnet", "OrderFlow.dll"]
