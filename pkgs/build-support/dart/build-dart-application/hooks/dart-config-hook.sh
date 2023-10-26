# shellcheck shell=bash

dartConfigHook() {
    echo "Executing dartConfigHook"

    echo "Setting up SDK"
    eval "$sdkSetupScript"

    echo "Installing dependencies"
    mkdir -p .dart_tool
    cp "$packageConfig" .dart_tool/package_config.json

    echo "Generating the dependency list"
    dart pub deps --json | @jq@ .packages > deps.json

    echo "Finished dartConfigHook"
}

postConfigureHooks+=(dartConfigHook)
