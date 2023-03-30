{ stdenv
, lib
, buildGoModule
, fetchFromGitHub
, makeWrapper
, coreutils
, runCommand
, runtimeShell
, writeText
, terraform-providers
, fetchpatch
, installShellFiles
}:

let
  generic = { version, hash, vendorHash ? null, ... }@attrs:
    let attrs' = builtins.removeAttrs attrs [ "version" "hash" "vendorHash" ];
    in
    buildGoModule ({
      pname = "terraform";
      inherit version vendorHash;

      src = fetchFromGitHub {
        owner = "hashicorp";
        repo = "terraform";
        rev = "v${version}";
        inherit hash;
      };

      ldflags = [ "-s" "-w" ];

      subPackages = [ "." ];

      postConfigure = ''
        # speakeasy hardcodes /bin/stty https://github.com/bgentry/speakeasy/issues/22
        substituteInPlace vendor/github.com/bgentry/speakeasy/speakeasy_unix.go \
          --replace "/bin/stty" "${coreutils}/bin/stty"
      '';

      nativeBuildInputs = [ installShellFiles ];

      preCheck = ''
        export HOME=$TMPDIR
        export TF_SKIP_REMOTE_TESTS=1
      '';

      # https://github.com/posener/complete/blob/9a4745ac49b29530e07dc2581745a218b646b7a3/cmd/install/bash.go#L8
      completionBash = "complete -C terraform terraform\n";
      # https://github.com/posener/complete/blob/9a4745ac49b29530e07dc2581745a218b646b7a3/cmd/install/zsh.go
      completionZsh =  "complete -C terraform terraform\n";
      # https://github.com/posener/complete/blob/9a4745ac49b29530e07dc2581745a218b646b7a3/cmd/install/fish.go#L56
      completionFish = ''
        function __complete_terraform
            set -lx COMP_LINE (commandline -cp)
            test -z (commandline -ct)
            and set COMP_LINE "$COMP_LINE "
            terraform
        end
        complete -f -c terraform -a "(__complete_terraform)"
      '';

      passAsFile = [ "completionBash" "completionZsh" "completionFish" ];

      postInstall = ''
        # remove all plugins, they are part of the main binary now
        for i in $out/bin/*; do
          if [[ $(basename $i) != terraform ]]; then
            rm "$i"
          fi
        done

        installShellCompletion --bash --name terraform $completionBashPath
        installShellCompletion --zsh --name terraform $completionZshPath
        installShellCompletion --fish --name terraform $completionFishPath
      '';

      meta = {
        description =
          "Tool for building, changing, and versioning infrastructure";
        homepage = "https://www.terraform.io/";
        changelog = "https://github.com/hashicorp/terraform/blob/v${version}/CHANGELOG.md";
        license = lib.licenses.mpl20;
        maintainers = with lib.maintainers; [ Chili-Man babariviere kalbasit marsam maxeaubrey techknowlogick timstott zimbatm zowoq ];
      };
    } // attrs');

  pluggable = terraform:
    let
      withPlugins = plugins:
        let
          actualPlugins = plugins terraform.plugins;

          # Wrap PATH of plugins propagatedBuildInputs, plugins may have runtime dependencies on external binaries
          wrapperInputs = lib.unique (lib.flatten
            (lib.catAttrs "propagatedBuildInputs"
              (builtins.filter (x: x != null) actualPlugins)));

          passthru = {
            withPlugins = newplugins:
              withPlugins (x: newplugins x ++ actualPlugins);
            full = withPlugins (p: lib.filter lib.isDerivation (lib.attrValues p.actualProviders));

            # Expose wrappers around the override* functions of the terraform
            # derivation.
            #
            # Note that this does not behave as anyone would expect if plugins
            # are specified. The overrides are not on the user-visible wrapper
            # derivation but instead on the function application that eventually
            # generates the wrapper. This means:
            #
            # 1. When using overrideAttrs, only `passthru` attributes will
            #    become visible on the wrapper derivation. Other overrides that
            #    modify the derivation *may* still have an effect, but it can be
            #    difficult to follow.
            #
            # 2. Other overrides may work if they modify the terraform
            #    derivation, or they may have no effect, depending on what
            #    exactly is being changed.
            #
            # 3. Specifying overrides on the wrapper is unsupported.
            #
            # See nixpkgs#158620 for details.
            overrideDerivation = f:
              (pluggable (terraform.overrideDerivation f)).withPlugins plugins;
            overrideAttrs = f:
              (pluggable (terraform.overrideAttrs f)).withPlugins plugins;
            override = x:
              (pluggable (terraform.override x)).withPlugins plugins;
          };
          # Don't bother wrapping unless we actually have plugins, since the wrapper will stop automatic downloading
          # of plugins, which might be counterintuitive if someone just wants a vanilla Terraform.
        in
        if actualPlugins == [ ] then
          terraform.overrideAttrs
            (orig: { passthru = orig.passthru // passthru; })
        else
          lib.appendToName "with-plugins" (stdenv.mkDerivation {
            inherit (terraform) name meta;
            nativeBuildInputs = [ makeWrapper ];

            # Expose the passthru set with the override functions
            # defined above, as well as any passthru values already
            # set on `terraform` at this point (relevant in case a
            # user overrides attributes).
            passthru = terraform.passthru // passthru;

            buildCommand = ''
              # Create wrappers for terraform plugins because Terraform only
              # walks inside of a tree of files.
              for providerDir in ${toString actualPlugins}
              do
                for file in $(find $providerDir/libexec/terraform-providers -type f)
                do
                  relFile=''${file#$providerDir/}
                  mkdir -p $out/$(dirname $relFile)
                  cat <<WRAPPER > $out/$relFile
              #!${runtimeShell}
              exec "$file" "$@"
              WRAPPER
                  chmod +x $out/$relFile
                done
              done

              # Create a wrapper for terraform to point it to the plugins dir.
              mkdir -p $out/bin/
              makeWrapper "${terraform}/bin/terraform" "$out/bin/terraform" \
                --set NIX_TERRAFORM_PLUGIN_DIR $out/libexec/terraform-providers \
                --prefix PATH : "${lib.makeBinPath wrapperInputs}"
            '';
          });
    in
    withPlugins (_: [ ]);

  plugins = removeAttrs terraform-providers [
    "override"
    "overrideDerivation"
    "recurseForDerivations"
  ];
in
rec {
  # Constructor for other terraform versions
  mkTerraform = attrs: pluggable (generic attrs);

  terraform_1 = mkTerraform {
    version = "1.4.2";
    hash = "sha256-0CxB9VOrRoudJVK96mpuQ6etsI+F2dMh4NQTKQXec9c=";
    vendorHash = "sha256-3ZQcWatJlQ6NVoPL/7cKQO6+YCSM3Ld77iLEQK3jBDE=";
    patches = [ ./provider-path-0_15.patch ];
    passthru = {
      inherit plugins;
      tests = { inherit terraform_plugins_test; };
    };
  };

  # Tests that the plugins are being used. Terraform looks at the specific
  # file pattern and if the plugin is not found it will try to download it
  # from the Internet. With sandboxing enable this test will fail if that is
  # the case.
  terraform_plugins_test =
    let
      mainTf = writeText "main.tf" ''
        resource "random_id" "test" {}
      '';
      terraform = terraform_1.withPlugins (p: [ p.random ]);
      test =
        runCommand "terraform-plugin-test" { buildInputs = [ terraform ]; } ''
          set -e
          # make it fail outside of sandbox
          export HTTP_PROXY=http://127.0.0.1:0 HTTPS_PROXY=https://127.0.0.1:0
          cp ${mainTf} main.tf
          terraform init
          touch $out
        '';
    in
    test;

}
