#!/usr/bin/env bash
# Pure helpers for .github/workflows/image.yml's build-args templating,
# version-file validation and registry tag checks.
#
# image.yml does not check out this repo, so each bash step that needs them
# carries an inline copy of these functions. The copies MUST stay identical:
# the "Diff the inline image-lib copies" step in .github/workflows/lint.yml
# diffs every one of them. Edit both, or the lint job fails.
#
# Tested by scripts/test-image-lib.sh.

# BEGIN image-lib
image_version_valid() {
  local version=$1
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]]
}

# image_safe_tag VALUE -> VALUE as a docker tag: every character outside
# [A-Za-z0-9_.-] becomes '-', and the result is capped at 128 characters
# (vpro's safe_tag, charts/ci/files/plan.py). {version} in build-args keeps
# the raw value; only the image tag is mapped.
image_safe_tag() {
  local tag=$1
  tag=$(printf '%s' "$tag" | sed 's/[^A-Za-z0-9_.-]/-/g')
  printf '%s' "${tag:0:128}"
}

# image_expand VALUE SHA REF VERSION -> VALUE with the placeholders
# replaced. Known placeholders only; unknown ones are left for
# image_unknown_placeholders to find.
image_expand() {
  local value=$1 sha=$2 ref=$3 version=$4
  value=${value//\{sha\}/$sha}
  value=${value//\{sha8\}/${sha:0:8}}
  value=${value//\{sha7\}/${sha:0:7}}
  value=${value//\{version\}/$version}
  value=${value//\{ref\}/$ref}
  printf '%s' "$value"
}

# image_unknown_placeholders VALUE -> the {placeholder} names left in
# VALUE, one per line, sorted and deduplicated (empty: none).
image_unknown_placeholders() {
  local value=$1 found
  found=$(printf '%s' "$value" | grep -o '{[A-Za-z0-9_.-]*}' | tr -d '{}' | sort -u) || true
  printf '%s' "$found"
}

# image_tag_state REF -> 'present' or 'absent' on stdout; 'unverifiable:
# <stderr>' and exit 2 when the registry answered with anything but a positive
# not-found (429, 5xx, auth, timeout, invalid reference). Only a not-found is
# an answer that a tag is missing, so callers can fail closed on the rest.
image_tag_state() {
  local ref=$1 out
  if out=$(docker buildx imagetools inspect "$ref" 2>&1); then
    printf 'present'
    return 0
  fi
  if grep -qiE 'not found|manifest unknown|manifest_unknown' <<<"$out"; then
    printf 'absent'
    return 0
  fi
  printf 'unverifiable: %s' "$out"
  return 2
}

# image_output_list NAME ITEM... -> append NAME to $GITHUB_OUTPUT as a heredoc,
# one item per line. The delimiter carries $RANDOM, so no value (an input can
# hold anything) can match it, and printf ends every line, so the last item
# cannot run into the delimiter.
image_output_list() {
  local name=$1 delim
  shift
  delim="EOF_${RANDOM}_${RANDOM}_${RANDOM}_$$"
  {
    printf '%s<<%s\n' "$name" "$delim"
    if (($# > 0)); then
      printf '%s\n' "$@"
    fi
    printf '%s\n' "$delim"
  } >> "${GITHUB_OUTPUT:?GITHUB_OUTPUT is not set}"
}
# END image-lib
