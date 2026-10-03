#!/usr/bin/env bash
# Run before every commit (or install as a pre-commit hook: ln -s ../../scripts/check-secrets.sh .git/hooks/pre-commit)
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
fail=0

if ! grep -qx 'Secrets.xcconfig' .gitignore; then
  echo "✗ Secrets.xcconfig is not in .gitignore"; fail=1
fi

if git ls-files --error-unmatch Secrets.xcconfig >/dev/null 2>&1; then
  echo "✗ Secrets.xcconfig is tracked by git. Run: git rm --cached Secrets.xcconfig"; fail=1
fi

if git ls-files | grep -q '\.netrc$'; then
  echo "✗ A .netrc file is tracked by git"; fail=1
fi

# Mapbox secret tokens, Supabase service-role/secret keys, JWTs, private keys.
patterns='sk\.eyJ[A-Za-z0-9_-]{20,}|sb_secret_[A-Za-z0-9_-]{10,}|service_role"?[:=]|-----BEGIN [A-Z ]*PRIVATE KEY-----|eyJhbGciOiJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}'
if git grep -nIE "$patterns" -- . ':!scripts/check-secrets.sh' ; then
  echo "✗ Something that looks like a secret is in tracked files (above)"; fail=1
fi
if git diff --cached -U0 | grep -nE "$patterns" ; then
  echo "✗ Something that looks like a secret is staged (above)"; fail=1
fi

if [ "$fail" -eq 0 ]; then echo "✓ No secrets found"; fi
exit "$fail"
