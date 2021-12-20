{ lib, stdenvNoCC, linkFarmFromDrvs, nuget-to-nix, writeScript, makeWrapper, fetchurl, xml2, dotnetCorePackages, dotnetPackages, cacert }:

{ name ? "${args.pname}-${args.version}"
, enableParallelBuilding ? true
, doCheck ? false
# Flags to pass to `makeWrapper`. This is done to avoid double wrapping.
, makeWrapperArgs ? []

# Flags to pass to `dotnet restore`.
, dotnetRestoreFlags ? []
# Flags to pass to `dotnet build`.
, dotnetBuildFlags ? []
# Flags to pass to `dotnet test`, if running tests is enabled.
, dotnetTestFlags ? []
# Flags to pass to `dotnet install`.
, dotnetInstallFlags ? []
# Flags to pass to `dotnet pack`.
, dotnetPackFlags ? []
# Flags to pass to dotnet in all phases.
, dotnetFlags ? []

# The binaries that should get installed to `$out/bin`, relative to `$out/lib/$pname/`. These get wrapped accordingly.
# Unfortunately, dotnet has no method for doing this automatically.
# If unset, all executables in the projects root will get installed. This may cause bloat!
, executables ? null
# Packs a project as a `nupkg`, and installs it to `$out/share`. If set to `true`, the derivation can be used as a dependency for another dotnet project by adding it to `projectReferences`.
, packNupkg ? false
# The packages project file, which contains instructions on how to compile it. This can be an array of multiple project files as well.
, projectFile ? null
# The NuGet dependency file. This locks all NuGet dependency versions, as otherwise they cannot be deterministically fetched.
# This can be generated by running the `passthru.fetch-deps` script.
, nugetDeps ? null
# A list of derivations containing nupkg packages for local project references.
# Referenced derivations can be built with `buildDotnetModule` with `packNupkg=true` flag.
# Since we are sharing them as nugets they must be added to csproj/fsproj files as `PackageReference` as well.
# For example, your project has a local dependency:
#     <ProjectReference Include="../foo/bar.fsproj" />
# To enable discovery through `projectReferences` you would need to add a line:
#     <ProjectReference Include="../foo/bar.fsproj" />
#     <PackageReference Include="bar" Version="*" Condition=" '$(ContinuousIntegrationBuild)'=='true' "/>
, projectReferences ? []
# Libraries that need to be available at runtime should be passed through this.
# These get wrapped into `LD_LIBRARY_PATH`.
, runtimeDeps ? []

# Tests to disable. This gets passed to `dotnet test --filter "FullyQualifiedName!={}"`, to ensure compatibility with all frameworks.
# See https://docs.microsoft.com/en-us/dotnet/core/tools/dotnet-test#filter-option-details for more details.
, disabledTests ? []
# The project file to run unit tests against. This is usually the regular project file, but sometimes it needs to be manually set.
, testProjectFile ? projectFile

# The type of build to perform. This is passed to `dotnet` with the `--configuration` flag. Possible values are `Release`, `Debug`, etc.
, buildType ? "Release"
# The dotnet SDK to use.
, dotnet-sdk ? dotnetCorePackages.sdk_5_0
# The dotnet runtime to use.
, dotnet-runtime ? dotnetCorePackages.runtime_5_0
# The dotnet SDK to run tests against. This can differentiate from the SDK compiled against.
, dotnet-test-sdk ? dotnet-sdk
, ... } @ args:

assert projectFile == null -> throw "Defining the `projectFile` attribute is required. This is usually an `.csproj`, or `.sln` file.";

# TODO: Automatically generate a dependency file when a lockfile is present.
# This file is unfortunately almost never present, as Microsoft recommands not to push this in upstream repositories.
assert nugetDeps == null -> throw "Defining the `nugetDeps` attribute is required, as to lock the NuGet dependencies. This file can be generated by running the `passthru.fetch-deps` script.";

let
  _nugetDeps = linkFarmFromDrvs "${name}-nuget-deps" (import nugetDeps {
    fetchNuGet = { name, version, sha256 }: fetchurl {
      name = "nuget-${name}-${version}.nupkg";
      url = "https://www.nuget.org/api/v2/package/${name}/${version}";
      inherit sha256;
    };
  });
  _localDeps = linkFarmFromDrvs "${name}-local-nuget-deps" projectReferences;

  nuget-source = stdenvNoCC.mkDerivation rec {
    name = "${args.pname}-nuget-source";
    meta.description = "A Nuget source with the dependencies for ${args.pname}";

    nativeBuildInputs = [ dotnetPackages.Nuget xml2 ];
    buildCommand = ''
      export HOME=$(mktemp -d)
      mkdir -p $out/{lib,share}

      nuget sources Add -Name nixos -Source "$out/lib"
      nuget init "${_nugetDeps}" "$out/lib"
      ${lib.optionalString (projectReferences != [])
        "nuget init \"${_localDeps}\" \"$out/lib\""}

      # Generates a list of all unique licenses' spdx ids.
      find "$out/lib" -name "*.nuspec" -exec sh -c \
        "xml2 < {} | grep "license=" | cut -d'=' -f2" \; | sort -u > $out/share/licenses
    '';
  } // { # This is done because we need data from `$out` for `meta`. We have to use overrides as to not hit infinite recursion.
    meta.licence = let
      depLicenses = lib.splitString "\n" (builtins.readFile "${nuget-source}/share/licenses");
      getLicence = spdx: lib.filter (license: license.spdxId or null == spdx) (builtins.attrValues lib.licenses);
    in (lib.flatten (lib.forEach depLicenses (spdx:
      if (getLicence spdx) != [] then (getLicence spdx) else [] ++ lib.optional (spdx != "") spdx
    )));
  };

  package = stdenvNoCC.mkDerivation (args // {
    inherit buildType;

    nativeBuildInputs = args.nativeBuildInputs or [] ++ [ dotnet-sdk cacert makeWrapper ];

    # Stripping breaks the executable
    dontStrip = true;

    # gappsWrapperArgs gets included when wrapping for dotnet, as to avoid double wrapping
    dontWrapGApps = true;

    DOTNET_NOLOGO = true; # This disables the welcome message.
    DOTNET_CLI_TELEMETRY_OPTOUT = true;

    passthru.fetch-deps = args.passthru.fetch-deps or writeScript "fetch-${args.pname}-deps" ''
      set -euo pipefail
      cd "$(dirname "''${BASH_SOURCE[0]}")"

      export HOME=$(mktemp -d)
      deps_file="/tmp/${args.pname}-deps.nix"

      store_src="${package.src}"
      src="$(mktemp -d /tmp/${args.pname}.XXX)"
      cp -rT "$store_src" "$src"
      chmod -R +w "$src"

      trap "rm -rf $src $HOME" EXIT
      pushd "$src"

      export DOTNET_NOLOGO=1
      export DOTNET_CLI_TELEMETRY_OPTOUT=1

      mkdir -p "$HOME/nuget_pkgs"

      for project in "${lib.concatStringsSep "\" \"" (lib.toList projectFile)}"; do
        ${dotnet-sdk}/bin/dotnet restore "$project" \
          ${lib.optionalString (!enableParallelBuilding) "--disable-parallel"} \
          -p:ContinuousIntegrationBuild=true \
          -p:Deterministic=true \
          --packages "$HOME/nuget_pkgs" \
          "''${dotnetRestoreFlags[@]}" \
          "''${dotnetFlags[@]}"
      done

      echo "Writing lockfile..."
      ${nuget-to-nix}/bin/nuget-to-nix "$HOME/nuget_pkgs" > "$deps_file"
      echo "Succesfully wrote lockfile to: $deps_file"
    '';

    configurePhase = args.configurePhase or ''
      runHook preConfigure

      export HOME=$(mktemp -d)

      for project in ''${projectFile[@]}; do
        dotnet restore "$project" \
          ${lib.optionalString (!enableParallelBuilding) "--disable-parallel"} \
          -p:ContinuousIntegrationBuild=true \
          -p:Deterministic=true \
          --source "${nuget-source}/lib" \
          "''${dotnetRestoreFlags[@]}" \
          "''${dotnetFlags[@]}"
      done

      runHook postConfigure
    '';

    buildPhase = args.buildPhase or ''
      runHook preBuild

      for project in ''${projectFile[@]}; do
        dotnet build "$project" \
          -maxcpucount:${if enableParallelBuilding then "$NIX_BUILD_CORES" else "1"} \
          -p:BuildInParallel=${if enableParallelBuilding then "true" else "false"} \
          -p:ContinuousIntegrationBuild=true \
          -p:Deterministic=true \
          -p:Version=${args.version} \
          --configuration "$buildType" \
          --no-restore \
          "''${dotnetBuildFlags[@]}"  \
          "''${dotnetFlags[@]}"
      done

      runHook postBuild
    '';

    checkPhase = args.checkPhase or ''
      runHook preCheck

      for project in ''${testProjectFile[@]}; do
        ${lib.getBin dotnet-test-sdk}/bin/dotnet test "$project" \
          -maxcpucount:${if enableParallelBuilding then "$NIX_BUILD_CORES" else "1"} \
          -p:ContinuousIntegrationBuild=true \
          -p:Deterministic=true \
          --configuration "$buildType" \
          --no-build \
          --logger "console;verbosity=normal" \
          ${lib.optionalString (disabledTests != []) "--filter \"FullyQualifiedName!=${lib.concatStringsSep "&FullyQualifiedName!=" disabledTests}\""} \
          "''${dotnetTestFlags[@]}"  \
          "''${dotnetFlags[@]}"
      done

      runHook postCheck
    '';

    installPhase = args.installPhase or ''
      runHook preInstall

      for project in ''${projectFile[@]}; do
        dotnet publish "$project" \
          -p:ContinuousIntegrationBuild=true \
          -p:Deterministic=true \
          --output $out/lib/${args.pname} \
          --configuration "$buildType" \
          --no-build \
          --no-self-contained \
          "''${dotnetInstallFlags[@]}"  \
          "''${dotnetFlags[@]}"
      done
    '' + (lib.optionalString packNupkg ''
      for project in ''${projectFile[@]}; do
        dotnet pack "$project" \
          -p:ContinuousIntegrationBuild=true \
          -p:Deterministic=true \
          --output $out/share \
          --configuration "$buildType" \
          --no-build \
          "''${dotnetPackFlags[@]}"  \
          "''${dotnetFlags[@]}"
      done
    '') + (if executables != null then ''
      for executable in $executables; do
        execPath="$out/lib/${args.pname}/$executable"

        if [[ -f "$execPath" && -x "$execPath" ]]; then
          makeWrapper "$execPath" "$out/bin/$(basename "$executable")" \
            --set DOTNET_ROOT "${dotnet-runtime}" \
            --suffix LD_LIBRARY_PATH : "${lib.makeLibraryPath runtimeDeps}" \
            "''${gappsWrapperArgs[@]}" \
            "''${makeWrapperArgs[@]}"
        else
          echo "Specified binary \"$executable\" is either not an executable, or does not exist!"
          exit 1
        fi
      done
    '' else ''
      for executable in $out/lib/${args.pname}/*; do
        if [[ -f "$executable" && -x "$executable" && "$executable" != *"dll"* ]]; then
          makeWrapper "$executable" "$out/bin/$(basename "$executable")" \
            --set DOTNET_ROOT "${dotnet-runtime}" \
            --suffix LD_LIBRARY_PATH : "${lib.makeLibraryPath runtimeDeps}" \
            "''${gappsWrapperArgs[@]}" \
            "''${makeWrapperArgs[@]}"
        fi
      done
    '') + ''
      runHook postInstall
    '';
  });
in
  package
