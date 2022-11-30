#!/bin/bash

set -uo pipefail
BASEDIR=$(dirname $0)

if [ ! -z "${SRC_USERNAME:-}" ] && [ ! -z "${SRC_PASSWORD:-}" ]; then
  echo "Logging in to ${SRC_REGISTRY:-docker.io} as ${SRC_USERNAME}"
  docker login ${SRC_REGISTRY:-docker.io} --username=${SRC_USERNAME} --password-stdin <<< ${SRC_PASSWORD}
fi

if [ ! -z "${DEST_USERNAME:-}" ] && [ ! -z "${DEST_PASSWORD:-}" ]; then
  echo "Logging in to ${DEST_REGISTRY:-docker.io} as ${DEST_USERNAME}"
  docker login ${DEST_REGISTRY:-docker.io} --username=${DEST_USERNAME} --password-stdin <<< ${DEST_PASSWORD}
fi

exec ${BASEDIR}/run.sh $@
