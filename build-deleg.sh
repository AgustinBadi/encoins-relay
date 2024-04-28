#!/bin/bash

APPS_VERSION=$(./scripts/get_project_version.sh "encoins-relay-apps/encoins-relay-apps.cabal")
cabal new-build exe:encoins-relay-delegation

cp dist-newstyle/build/x86_64-linux/ghc-8.10.7/encoins-relay-apps-"$APPS_VERSION"/build/encoins-relay-delegation/encoins-relay-delegation ~/.local/bin/encoins-delegation
