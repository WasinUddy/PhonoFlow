# Release signing and notarization

PhonoFlow releases are produced only from stable SemVer tags of the form
`vMAJOR.MINOR.PATCH`. The release workflow requires the tagged commit to be
reachable from `main` and refuses to replace an existing GitHub Release.

## External GitHub controls

Repository administrators must configure and audit these controls separately;
the files in this repository cannot create them:

- an active `main` branch ruleset requiring every check listed in
  [CI/CD operations](../.github/CI-CD.md)
- an active tag ruleset for stable `vMAJOR.MINOR.PATCH` tags that restricts
  creation to release maintainers and restricts updates and deletion
- a protected GitHub environment named `release`, limited to matching stable
  tags, with required reviewers and self-review prevention
- [immutable releases](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases)
  enabled before the first publication

Signing and notarization credentials must exist only in the protected
`release` environment and must not be available to pull-request workflows.
Immutable releases protect the tag and assets after publication; the tag
ruleset protects the tag before that point.

## Required configuration

Configure this environment variable:

| Kind | Name | Description |
|---|---|---|
| Environment variable | `APPLE_TEAM_ID` | Apple Developer team identifier |

Configure these environment secrets:

| Secret | Description |
|---|---|
| `RELEASE_ADMIN_READ_TOKEN` | Fine-grained token limited to this repository with read-only Administration permission |
| `APPLE_DEVELOPER_ID_P12_BASE64` | Base64 PKCS#12 Developer ID Application certificate and private key |
| `APPLE_DEVELOPER_ID_P12_PASSWORD` | Password for that PKCS#12 file |
| `APPLE_NOTARY_KEY_P8_BASE64` | Base64-encoded App Store Connect API private key |
| `APPLE_NOTARY_KEY_ID` | App Store Connect API key ID |
| `APPLE_NOTARY_ISSUER_ID` | App Store Connect issuer ID |

`RELEASE_ADMIN_READ_TOKEN` lets the workflow fail closed by querying the
immutable-release setting before build work and immediately before publication;
the ordinary workflow token cannot request repository Administration
permission. Use a fine-grained, expiring token—not a classic broadly scoped
token—and grant no write permission.

Use the narrowest App Store Connect role that permits notarization. Rotate and
revoke all credentials according to the project's security policy. Never commit
the decoded `.p12`, `.p8`, tokens, passwords, temporary keychains, or exported
signing materials.

## Reproducibility prerequisites

Before tagging:

- all required branch checks pass on `main`
- `Package.resolved` and the frontend lockfile are committed and unchanged
- the shared Xcode scheme and CI/acceptance/focusrite test plans are committed
- the Release configuration enables the hardened runtime
- user-specific Xcode state is not tracked
- release notes identify any hardware validation actually completed

CI pins Xcode and GitHub Actions. Release preflight validates the exact shared
scheme and the CI, acceptance, and Focusrite test-plan contracts. It resolves
the Xcode project with automatic resolution disabled, package updates skipped,
and only versions from the committed lockfile allowed in a fresh private package
directory. The release job then builds one universal `arm64` + `x86_64`
application and removes the package directory when artifact creation finishes.

## Publish

Create and push a stable tag only from the reviewed mainline commit:

```bash
git switch main
git pull --ff-only
git tag -s v1.2.3 -m 'PhonoFlow 1.2.3'
git push origin v1.2.3
```

The protected workflow:

1. confirms immutable releases are enabled and the checked-out and remote tag
   both resolve to the triggering `GITHUB_SHA`
2. imports exactly one Developer ID Application identity for `APPLE_TEAM_ID`
   into an ephemeral keychain, temporarily isolates that keychain for signing,
   then restores the original search list and destroys the keychain
3. archives a universal app with manual signing and hardened runtime
4. verifies both architecture slices, their signatures and entitlements,
   timestamp, version, and dSYM UUIDs
5. creates and signs the universal DMG
6. submits the DMG with `notarytool` and requires an accepted result with no
   reported issues
7. staples and validates the notarization ticket
8. verifies the DMG and mounted app with `codesign`, `spctl`, and `hdiutil`
9. emits the DMG, zipped dSYM, and SHA-256 checksum file
10. creates GitHub artifact attestations and attaches all assets to a draft
    GitHub Release
11. requires the newest `github-actions` check run for every required check on
    the exact tag SHA to have completed successfully, revalidates the remote
    tag against `GITHUB_SHA`, confirms immutable releases are still enabled,
    and publishes the draft
12. verifies that the release is immutable and that its published assets match
    the local artifacts
13. removes temporary signing material

If a run stops after creating the draft, inspect the failed gate before
deleting that draft and rerunning. Never publish the retained draft manually
to bypass a failed tag or check-run validation.

## Verify a downloaded release

Download all three versioned assets into the same empty directory. The checksum
file covers the DMG and dSYM archive, so both files must be present with their
published names:

```bash
mkdir PhonoFlow-1.2.3-verify
cd PhonoFlow-1.2.3-verify
gh release download v1.2.3 \
  --repo WasinUddy/PhonoFlow \
  --pattern 'PhonoFlow-1.2.3-macOS-universal.dmg' \
  --pattern 'PhonoFlow-1.2.3-dSYMs.zip' \
  --pattern 'PhonoFlow-1.2.3-SHA256SUMS.txt'
gh release verify v1.2.3 --repo WasinUddy/PhonoFlow
for asset in \
  PhonoFlow-1.2.3-macOS-universal.dmg \
  PhonoFlow-1.2.3-dSYMs.zip \
  PhonoFlow-1.2.3-SHA256SUMS.txt
do
  gh release verify-asset \
    v1.2.3 \
    "$asset" \
    --repo WasinUddy/PhonoFlow
done
shasum -a 256 -c PhonoFlow-1.2.3-SHA256SUMS.txt
codesign --verify --strict --verbose=4 PhonoFlow-1.2.3-macOS-universal.dmg
spctl --assess \
  --type open \
  --context context:primary-signature \
  --verbose=4 \
  PhonoFlow-1.2.3-macOS-universal.dmg
xcrun stapler validate -v PhonoFlow-1.2.3-macOS-universal.dmg
release_sha="$(
  gh api repos/WasinUddy/PhonoFlow/commits/v1.2.3 --jq .sha
)"
gh attestation verify \
  PhonoFlow-1.2.3-macOS-universal.dmg \
  --repo WasinUddy/PhonoFlow \
  --signer-workflow github.com/WasinUddy/PhonoFlow/.github/workflows/release.yml \
  --source-ref refs/tags/v1.2.3 \
  --source-digest "$release_sha"
```

Do not instruct users to remove quarantine or bypass Gatekeeper when these
checks fail. Investigate the artifact and release workflow instead.

The workflow and scripts define the release contract. They do not themselves
configure repository rulesets, environment protections, or release
immutability, and they do not prove in advance that repository secrets are
valid. Rely on audited repository settings, the protected workflow result,
`gh release verify`, and the published attestation for that evidence.
