"""Tests for host-specific sysroot archive extraction selection."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//aptprep/private:sysroot_repo.bzl", "archive_extractor_for_os", "mode_from_tar_permissions")

def _extractor_selection_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "bazel", archive_extractor_for_os("mac os x"))
    asserts.equals(env, "bazel", archive_extractor_for_os("darwin"))
    asserts.equals(env, "tar", archive_extractor_for_os("linux"))
    asserts.equals(env, "bazel", archive_extractor_for_os("linux", "bazel"))
    asserts.equals(env, "tar", archive_extractor_for_os("darwin", "tar"))
    asserts.equals(env, "0755", mode_from_tar_permissions("drwxr-xr-x"))
    asserts.equals(env, "0700", mode_from_tar_permissions("drwx------"))
    asserts.equals(env, "1777", mode_from_tar_permissions("drwxrwxrwt"))
    asserts.equals(env, "2755", mode_from_tar_permissions("drwxr-sr-x"))
    return unittest.end(env)

_extractor_selection_test = unittest.make(_extractor_selection_test_impl)

def extraction_test_suite(name):
    unittest.suite(name, _extractor_selection_test)
