"""Tests for extractor-comparison environment validation."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":extraction_comparison_ext.bzl", "extractor_comparison_override_error")

_ARCHIVE_EXTRACTOR_ENV = "APTPREP_ARCHIVE_EXTRACTOR"

def _override_validation_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, None, extractor_comparison_override_error({}))
    asserts.equals(env, None, extractor_comparison_override_error({_ARCHIVE_EXTRACTOR_ENV: ""}))
    asserts.equals(
        env,
        "APTPREP_ARCHIVE_EXTRACTOR must be unset for extractor comparison; setting it to 'tar' would force both sysroots to use the same extractor",
        extractor_comparison_override_error({_ARCHIVE_EXTRACTOR_ENV: "tar"}),
    )
    asserts.equals(
        env,
        "APTPREP_ARCHIVE_EXTRACTOR must be unset for extractor comparison; setting it to 'bazel' would force both sysroots to use the same extractor",
        extractor_comparison_override_error({_ARCHIVE_EXTRACTOR_ENV: "bazel"}),
    )
    return unittest.end(env)

_override_validation_test = unittest.make(_override_validation_test_impl)

def extraction_comparison_test_suite(name):
    unittest.suite(name, _override_validation_test)
