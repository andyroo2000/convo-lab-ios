# FSRS Golden Fixture

The API repository is the canonical owner of the cross-client FSRS contract:

- Repository: `andyroo2000/learning-os`
- Fixture: `tests/Fixtures/fsrs-golden-v1.json`
- Checksum: `tests/Fixtures/fsrs-golden-v1.sha256`

The iOS copies live only in `ConvoLabTests/Fixtures` and are test resources, not
application resources. `FSRSGoldenFixtureTests` pins the canonical API merge
commit and SHA-256 digest, verifies the vendored bytes, and consumes the profile,
scheduling, and timestamp-transport vectors.

## Updating the fixture

Start with a clean iOS worktree and a locally fetched API repository. Set the
two values below to the repository's absolute path and the exact merged commit:

```sh
set -eu
api_repo=/absolute/path/to/learning-os
api_commit=0123456789abcdef0123456789abcdef01234567
fixture=tests/Fixtures/fsrs-golden-v1.json
sidecar=tests/Fixtures/fsrs-golden-v1.sha256

git -C "$api_repo" cat-file -e "$api_commit^{commit}"
git -C "$api_repo" show "$api_commit:$fixture" > /tmp/fsrs-golden-v1.json
git -C "$api_repo" show "$api_commit:$sidecar" > /tmp/fsrs-golden-v1.sha256
shasum -a 256 /tmp/fsrs-golden-v1.json
expected=$(awk '{print $1}' /tmp/fsrs-golden-v1.sha256)
actual=$(shasum -a 256 /tmp/fsrs-golden-v1.json | awk '{print $1}')
test "$actual" = "$expected"
cmp /tmp/fsrs-golden-v1.json ConvoLabTests/Fixtures/fsrs-golden-v1.json
cmp /tmp/fsrs-golden-v1.sha256 ConvoLabTests/Fixtures/fsrs-golden-v1.sha256
```

To adopt a changed canonical artifact, copy both `/tmp` files into
`ConvoLabTests/Fixtures` byte-for-byte, then update `canonicalAPICommit` and
`canonicalSHA256` in `FSRSGoldenFixtureTests`. Do not recalculate or edit the
fixture's expected scheduling values in iOS. Run the focused fixture tests and
the complete iOS test suite before merging.
