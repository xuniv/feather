# Fork versions and upstream updates

The upstream is https://github.com/claration/feather. Keep its history and developer/license credits. Fork features live in separate `OriginalIPA` files and a small shared installer entry point to reduce future conflicts.

`Feather.xcconfig` is the version source of truth:

- `FEATHER_UPSTREAM_VERSION`: the upstream release currently integrated (2.9.0).
- `FEATHER_FIX_VERSION` is the increasing fork release revision, currently 9. Previously published versions 2.9.1–2.9.4 correspond to fork revisions 1–4 on upstream 2.9.0.
- `FEATHER_RELEASE_VERSION` is the public `upstream-revision` label, currently 2.9.0-9. About and GitHub release tags and titles use this value. Info.plist retains it as `FeatherForkVersion`.
- `FEATHER_PROJECT_VERSION` is the increasing numeric package version for iOS and AltStore, currently 2.9.9. Increment it across upstream updates as well. `CFBundleShortVersionString` and `CFBundleVersion` stay numeric so clients can order updates after the old 2.9.4 build.

For a future upstream update, fetch the public upstream into a separate branch, review the changes and merge its actual history:

```sh
git remote add upstream https://github.com/claration/feather.git # once
git config remote.upstream.tagOpt --no-tags
git fetch upstream '+refs/heads/*:refs/remotes/upstream/*' \
  '+refs/tags/*:refs/tags/upstream/*'
git switch -c update/upstream main
git merge <reviewed-upstream-commit>
```

Upstream tags stay under `upstream/` to avoid collisions with the fork’s historical numeric release tags. Merge a reviewed upstream branch/commit or `refs/tags/upstream/<tag>`; do not overwrite published fork tags.

Resolve conflicts without replacing the tested installation transport, original-file import path, entitlement policy or user-owned tweak directory. Update the upstream version to the release actually merged, increment the fork revision and numeric package version, then run the validation workflow. Review and merge before dispatching the unsigned release workflow with `v<FEATHER_RELEASE_VERSION>` (currently `v2.9.0-9`). Do not mark a numeric fork suffix as a GitHub prerelease. The release notes record the numeric package version for automatic AltStore mirroring through its existing validation gate.

Commits must use an anonymous author and committer and contain no account, session, local path or signing material. Preserve license notices. Publication verifies the canonical unsigned archive and SHA256SUMS; do not bypass the downstream repository's leak/signature checks.
