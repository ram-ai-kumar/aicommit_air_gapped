# Changelog

All notable changes to this project will be documented in this file.

## [0.4.0] - 2026-10-07

- feat(core): implement robust SemVer engine and comprehensive version comparison logic Add lib/semver.sh to support automatic detection of version strings across multiple ecosystems (Ruby, PHP, .NET, Java, Python) and integrate calculate_next_semver into the core workflow. This update enables automatic determination of Major, Minor, or Patch increments based on SemVer 2.0.0 rules by analyzing commit messages and diffs. Key additions include:
