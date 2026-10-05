/// Compile-time build identity (tool/build.dart): the repo URL is constant,
/// and the Prop version is injected from `pubspec.yaml` — the single source
/// of truth — via `dart compile -DSUDOER_VERSION=…`, so the binary cannot
/// drift from the package it was built from.
///
/// `dart run` and `dart test` do not inject defines: the URL keeps its
/// default, and the version is empty, which the surfaces report as a
/// development build.
library;

/// The repository this agent is built from (constant).
const String kRepoUrl = String.fromEnvironment(
  'SUDOER_REPO',
  defaultValue: 'https://github.com/invented-pro/sudoer',
);

/// The Prop package version, injected at compile time; empty in development.
const String kPropVersion = String.fromEnvironment('SUDOER_VERSION');

/// The version label surfaces print: the injected version, or `dev`.
String get kBuildLabel => kPropVersion.isEmpty ? 'dev' : kPropVersion;
