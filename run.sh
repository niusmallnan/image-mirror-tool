#!/bin/bash

BASEDIR=$(dirname $0)

INFILE="${1}"
if [ ! -f "${INFILE}" ]; then
          echo "File ${INFILE} does not exist!"
            exit 1
fi

echo "Reading SOURCE from ${INFILE}"
cat ${INFILE} | xargs -P ${WORKERS:-1} -I % bash -c 'source ./image-mirror.sh && mirror_image %'
