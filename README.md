This is a fork of [yuzi-co/btproxy](https://github.com/yuzi-co/btproxy); see [upstream/README.md](https://github.com/yuzi-co/btproxy/blob/main/README.md).

## CHANGELIST

- Updated the CI push trigger to follow the `main` branch.
- Removed OpenWrt and Linux package builds and repository publishing; tagged releases now publish static binary archives and Docker images only.
- Dropped Windows from CI and binary releases.
- Added a scheduled and manually triggered workflow to open PRs for new stable upstream releases.
