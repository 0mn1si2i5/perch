#!/usr/bin/env bash
# Sourced by build_and_run.sh. No identities or certificates are persisted in the repository.

perch_select_signing_identity() {
  local identities="$1" installed="$2" candidates count
  if [[ "$installed" != "-" ]]; then
    if ! [[ "$installed" =~ ^[[:xdigit:]]{40}$ ]]; then
      echo "Cannot identify the installed Perch signer; set PERCH_SIGNING_IDENTITY explicitly." >&2
      return 1
    fi
    installed="$(printf '%s' "$installed" | tr '[:lower:]' '[:upper:]')"
    if printf '%s\n' "$identities" | awk -v wanted="$installed" '$2 == wanted { found=1 } END { exit !found }'; then
      printf '%s\n' "$installed"
      return 0
    fi
    echo "The installed Perch signing identity is unavailable. Restore that identity or set PERCH_SIGNING_IDENTITY explicitly; the installed signer will not be changed automatically." >&2
    return 1
  fi

  candidates="$(printf '%s\n' "$identities" | sed -nE 's/^[[:space:]]*[0-9]+\) ([[:xdigit:]]{40}) "Apple Development: [^"]+"$/\1/p' | sort -u)"
  count="$(printf '%s\n' "$candidates" | awk 'NF { n++ } END { print n+0 }')"
  case "$count" in
    0) printf '%s\n' '-' ;;
    1) printf '%s\n' "$candidates" ;;
    *) echo "Multiple Apple Development signing identities are available. Set PERCH_SIGNING_IDENTITY to the intended identity." >&2; return 1 ;;
  esac
}

perch_resolve_signing_identity() (
  local installed_app="$1" identities installed='-' details certificate_dir
  if [[ "${PERCH_SIGNING_IDENTITY+x}" == x ]]; then
    if [[ -z "$PERCH_SIGNING_IDENTITY" ]]; then
      echo "PERCH_SIGNING_IDENTITY must name a signing identity, or '-' for ad-hoc signing." >&2
      return 1
    fi
    printf '%s\n' "$PERCH_SIGNING_IDENTITY"
    return 0
  fi

  if [[ -d "$installed_app" ]]; then
    if ! details="$(/usr/bin/codesign --display --verbose=2 "$installed_app" 2>&1)"; then
      echo "Cannot read the installed Perch signature. Set PERCH_SIGNING_IDENTITY explicitly." >&2
      return 1
    fi
    if ! printf '%s\n' "$details" | /usr/bin/grep -q '^Signature=adhoc$'; then
      certificate_dir="$(mktemp -d "${TMPDIR:-/tmp}/perch-signing.XXXXXX")" || return 1
      trap 'rm -rf "$certificate_dir"' EXIT
      if ! /usr/bin/codesign --display --extract-certificates="$certificate_dir/cert" "$installed_app" >/dev/null 2>&1 || [[ ! -s "$certificate_dir/cert0" ]]; then
        echo "Cannot read the installed Perch signing certificate. Set PERCH_SIGNING_IDENTITY explicitly." >&2
        return 1
      fi
      installed="$(/usr/bin/shasum -a 1 "$certificate_dir/cert0" | awk '{ print $1 }')"
    fi
  fi
  identities="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null)" || identities=''
  perch_select_signing_identity "$identities" "$installed"
)
