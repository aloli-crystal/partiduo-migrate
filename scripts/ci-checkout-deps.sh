#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# shard.yml référence le cœur (`../partiduo-app`) et les shards maison
# (`../../<nom>`) en `path:` tant qu'ils ne sont pas publiés. En CI, on les
# clone à ces emplacements.
set -eu

cd "$(dirname "$0")/.."
base="${PARTIDUO_DEPS_BASE_URL:-https://github.com/aloli-crystal}"

for repo in partiduo-app; do
  if [ ! -d "../$repo" ]; then
    git clone --depth 1 --branch "${PARTIDUO_APP_BRANCH:-development}" "$base/$repo.git" "../$repo"
  fi
done

../partiduo-app/scripts/ci-checkout-deps.sh
