"""Resources from dependencies that do not export them as Bazel targets."""

def _zstd_license_impl(repository_ctx):
    repository_ctx.symlink(repository_ctx.path(Label("@zstd//:LICENSE")), "LICENSE")
    repository_ctx.file("BUILD.bazel", 'exports_files(["LICENSE"])\n')

zstd_license = repository_rule(
    implementation = _zstd_license_impl,
    doc = "Expose the license from the zstd module without patching its BUILD file.",
)
