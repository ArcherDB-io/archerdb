const std = @import("std");
const options = @import("options");

pub const semver = std.SemanticVersion{
    .major = 0,
    .minor = 0,
    .patch = 1,
    .pre = null,
    .build = options.git_commit,
};
