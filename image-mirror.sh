#!/bin/bash

set -uo pipefail
export DOCKER_CLI_EXPERIMENTAL="enabled"

ARCH_LIST="amd64 arm64"

function copy_if_changed {
  SOURCE_REF="${1}"
  DEST_REF="${2}"
  ARCH="${3}"
  EXTRA_ARGS="${4:-}"

  SOURCE_MANIFEST=$(skopeo inspect docker://${SOURCE_REF} --raw 2>/dev/null)
  if [ "${#SOURCE_MANIFEST}" -gt 0 ]; then
    SOURCE_DIGEST="sha256:"$(echo -n "${SOURCE_MANIFEST}" | sha256sum | awk '{print $1}')
  else
    SOURCE_DIGEST="MISSING"
  fi

  DEST_MANIFEST=$(skopeo inspect docker://${DEST_REF} --raw 2>/dev/null)
  if [ "${#DEST_MANIFEST}" -gt 0 ]; then
    DEST_DIGEST="sha256:"$(echo -n "${DEST_MANIFEST}" | sha256sum | awk '{print $1}')
  else
    DEST_DIGEST="MISSING"
  fi

  if [ "${SOURCE_DIGEST}" == "${DEST_DIGEST}" ]; then
    echo -e "\tUnchanged: ${SOURCE_REF} == ${DEST_REF}"
    echo -e "\t           ${SOURCE_DIGEST}"
  else
    echo -e "\tCopying ${SOURCE_REF} => ${DEST_REF}"
    echo -e "\t        ${SOURCE_DIGEST} => ${DEST_DIGEST}"
    skopeo copy --override-arch=${ARCH} docker://${SOURCE_REF} docker://${DEST_REF} ${EXTRA_ARGS}
  fi
}

function mirror_image {
  SOURCE="${1}"
  DEST="${DEST_REGISTRY}/${SOURCE#$SRC_REGISTRY/}"

  trap 'echo -e "===\nFailed copying image for ${SOURCE}\n===" && echo ${SOURCE} >> failed_images.txt' ERR

  # Grab raw manifest or manifest list and extract schema info
  MANIFEST=$(skopeo inspect docker://${SOURCE} --raw)
  SCHEMAVERSION=$(jq -r '.schemaVersion' <<< ${MANIFEST})
  MEDIATYPE=$(jq -r '.mediaType' <<< ${MANIFEST})
  SOURCES=()
  DIGESTS=()
 
  # Most everything should use a v2 schema, but some old images (on quay.io mostly) are still on v1
  if [ "${SCHEMAVERSION}" == "2" ]; then

    # Handle manifest lists by copying all the architectures (and their variants) out to individual suffixed tags in the destination,
    # then recombining them into a single manifest list on the bare tags.
    if [ "${MEDIATYPE}" == "application/vnd.docker.distribution.manifest.list.v2+json" ]; then
      echo "${SOURCE} is manifest.list.v2"
      for ARCH in ${ARCH_LIST}; do
        VARIANT_INDEX="0"
        DIGEST_VARIANT_LIST=$(jq -r --arg ARCH "${ARCH}" \
          '.manifests | map(select(.platform.architecture == $ARCH))
                      | sort_by(.platform.variant)
                      | reverse
                      | map(.digest + " " + .platform.variant)
                      | join("\n")' <<< ${MANIFEST});
        while read DIGEST VARIANT; do 
          # Add skopeo flags for multi-variant architectures (arm, mostly)
          if [ -z "${VARIANT}" ] || [ "${VARIANT}" == "null" ]; then
            VARIANT=""
          fi

          # Make the first variant the default for this arch by omitting it from the tag
          if [ "${VARIANT_INDEX}" -eq 0 ]; then
            VARIANT=""
          fi

          if [ -z "${DIGEST}" ] || [ "${DIGEST}" == "null" ]; then
            echo -e "\t${ARCH} NOT FOUND"
          else
            # We have to copy the full descriptor here; if we just point buildx at another tag or hash it will lose the variant
            # info since that's not stored anywhere outside the manifest list itself.
            copy_if_changed "${SOURCE}@${DIGEST}" "${DEST}-${ARCH}${VARIANT}" "${ARCH}"
            DESCRIPTOR=$(jq -c -r --arg DIGEST "${DIGEST}" '.manifests | map(select(.digest == $DIGEST)) | first' <<< ${MANIFEST})
            SOURCES+=("${DESCRIPTOR}")
            DIGESTS+=("${DIGEST}")
            ((++VARIANT_INDEX))
          fi
        done <<< ${DIGEST_VARIANT_LIST}
      done

    # Standalone manifests don't include architecture info, we have to get that from the image config
    elif [ "${MEDIATYPE}" == "application/vnd.docker.distribution.manifest.v2+json" ]; then
      echo "${SOURCE} is manifest.v2"
      CONFIG=$(skopeo inspect docker://${SOURCE} --config --raw)
      ARCH=$(jq -r '.architecture' <<< ${CONFIG})
      DIGEST=$(jq -r '.config.digest' <<< ${MANIFEST})
      if grep -wqF ${ARCH} <<< ${ARCH_LIST}; then
        copy_if_changed "${SOURCE}" "${DEST}-${ARCH}" "${ARCH}"
        SOURCES+=("${DEST}-${ARCH}")
        DIGESTS+=("${DIGEST}")
      fi
    else 
      echo "${SOURCE} has unknown mediaType ${MEDIATYPE}"
      return 1
    fi

  # v1 manifests contain arch but no variant, but can be treated similar to manifest.v2
  # We upconvert to v2 schema on copy, since v1 manifests cannot be added to manifest lists
  elif [ "${SCHEMAVERSION}" == "1" ]; then
    echo "${SOURCE} is manifest.v1"
    ARCH=$(jq -r '.architecture' <<< ${MANIFEST})
    if grep -wqF ${ARCH} <<< ${ARCH_LIST}; then
      if copy_if_changed "${SOURCE}" "${DEST}-${ARCH}" "${ARCH}" "--format=v2s2"; then
        SOURCES+=("${DEST}-${ARCH}")
        DIGESTS+=("${DIGEST}")
      fi
    fi
  else
    echo "${SOURCE} has unknown schemaVersion ${SCHEMAVERSION}"
    return 1
  fi

  NEW_DIGESTS=$(printf '%s\n' "${DIGESTS[@]}" | sort)
  CUR_MANIFEST=$(skopeo inspect docker://${DEST} --raw 2>/dev/null || true)
  CUR_SCHEMAVERSION=$(jq -r '.schemaVersion' <<< ${CUR_MANIFEST})
  CUR_MEDIATYPE=$(jq -r '.mediaType' <<< ${CUR_MANIFEST})
 
  if [ "${CUR_SCHEMAVERSION}" == "2" ] && [ "${CUR_MEDIATYPE}" == "application/vnd.docker.distribution.manifest.list.v2+json" ]; then
    CUR_DIGESTS=$(jq -r '.manifests[].digest' <<< ${CUR_MANIFEST} | sort)
  else
    CUR_DIGESTS=""
  fi

  if [ "${NEW_DIGESTS}" == "${CUR_DIGESTS}" ]; then
    echo -e "\tNo changes to manifest list for ${DEST}"
  else
    echo -e "\tWriting manifest list to ${DEST}\n${NEW_DIGESTS}"
    docker buildx imagetools create --tag ${DEST} "${SOURCES[@]}"
  fi
}

