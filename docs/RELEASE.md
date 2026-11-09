# Prepare a release

The included workflow creates a **draft source release**. It never publishes a marketplace listing or promises a prebuilt installer.

1. Finish the feature and replace starter copy. Confirm licences and asset rights.
2. Run portable and native checks. On Omarchy record the exact installed version, commands, results, source commit and limitations in docs/ACCEPTANCE.json. Set status to passed only after actual acceptance. Record this in a subsequent documentation-only commit.
3. Update VERSION and any manifest/Cargo/package version before testing. Commit, tag the accepted candidate, and push the tag.
4. Submit a marketplace Verify ticket for that tag's full commit SHA and wait for `approved-and-verified`. A published release cannot be corrected, so a defect found in verification means fixing it on a new commit and verifying again, not editing a release. Do not create or publish the GitHub release before that approval.
5. Run **Release source** from Actions with that existing tag. The source archive preserves the complete tracked project, including development checks. Installed runtime packages must use an explicit file allowlist and exclude authoring instructions, blueprint files and workflow files.
6. Review the draft release, write outcome-focused notes and publish when ready. If an earlier tag was never published, the notes must cover every user-visible change since the last *published* release, not just the new tag.

The archive script refuses uninitialized projects, dirty checkouts, version/tag mismatches and runtime changes after recorded acceptance. For installable plugin archives, include only the declared QML/runtime dependencies, manifest and licence. For apps, build and test architecture-specific binaries separately; do not label a source tarball as an installer. For packages, record clean Arch build and install/upgrade/removal results before submission.
